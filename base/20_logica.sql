/* ------------------------------------------------------------------
   AssistentD | Logica de la agenda y de la memoria
   La IA nunca escribe SQL: pide una "herramienta" por nombre con sus
   datos en JSON y la funcion nucleo.herramienta() hace el trabajo.
------------------------------------------------------------------- */
SET client_min_messages = warning;

/* ============ Utilidades de fecha ============ */

CREATE OR REPLACE FUNCTION nucleo.dia_nombre(t timestamptz) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT (ARRAY['lunes','martes','miércoles','jueves','viernes','sábado','domingo'])[extract(isodow FROM t)::int]
$$;

-- Acepta "2026-11-09 14:30", "2026-11-09T14:30" o solo "2026-11-09"
CREATE OR REPLACE FUNCTION nucleo.a_fecha(t text) RETURNS timestamptz
LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN NULLIF(trim(t), '') IS NULL THEN NULL
              ELSE replace(trim(t), 'T', ' ')::timestamp::timestamptz END
$$;

-- Igual que a_fecha, pero si llega solo el dia devuelve el final de ese dia
CREATE OR REPLACE FUNCTION nucleo.a_fecha_fin(t text) RETURNS timestamptz
LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN NULLIF(trim(t), '') IS NULL THEN NULL
              WHEN char_length(trim(t)) = 10 THEN (trim(t)::date + 1)::timestamptz
              ELSE nucleo.a_fecha(t) END
$$;

CREATE OR REPLACE FUNCTION nucleo.entero(t text, defecto int) RETURNS int
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(round(NULLIF(trim(t), '')::numeric)::int, defecto)
$$;

/* ============ Ocurrencias: expande las actividades repetitivas ============ */

CREATE OR REPLACE FUNCTION nucleo.ocurrencias(desde timestamptz, hasta timestamptz)
RETURNS TABLE (evento_id int, titulo text, detalle text, categoria text, prioridad smallint,
               inicio timestamptz, fin timestamptz, repeticion text, aviso_min int)
LANGUAGE sql STABLE AS $$
  SELECT e.id, e.titulo, e.detalle, e.categoria, e.prioridad,
         g.ini, g.ini + (e.fin - e.inicio), e.repeticion, e.aviso_min
  FROM nucleo.eventos e
  CROSS JOIN LATERAL generate_series(
        e.inicio,
        LEAST(COALESCE((e.repetir_hasta + 1)::timestamptz, hasta), hasta),
        CASE e.repeticion
          WHEN 'diaria'     THEN interval '1 day'
          WHEN 'laborables' THEN interval '1 day'
          WHEN 'semanal'    THEN interval '1 week'
          WHEN 'mensual'    THEN interval '1 month'
          ELSE interval '100 years' END) AS g(ini)
  WHERE e.estado = 'activo'
    AND g.ini < hasta
    AND g.ini + (e.fin - e.inicio) > desde
    AND (e.repeticion <> 'laborables' OR extract(isodow FROM g.ini) < 6)
$$;

CREATE OR REPLACE FUNCTION nucleo.agenda(desde timestamptz, hasta timestamptz, tope int DEFAULT 200)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT COALESCE(jsonb_agg(x.j ORDER BY x.inicio), '[]'::jsonb)
  FROM (
    SELECT o.inicio, jsonb_build_object(
      'id', o.evento_id, 'titulo', o.titulo, 'detalle', COALESCE(o.detalle, ''),
      'categoria', o.categoria, 'prioridad', o.prioridad,
      'dia', nucleo.dia_nombre(o.inicio), 'fecha', to_char(o.inicio, 'YYYY-MM-DD'),
      'hora', to_char(o.inicio, 'HH24:MI'), 'hora_fin', to_char(o.fin, 'HH24:MI'),
      'inicio_iso', to_char(o.inicio, 'YYYY-MM-DD"T"HH24:MI:SS'),
      'fin_iso', to_char(o.fin, 'YYYY-MM-DD"T"HH24:MI:SS'),
      'repeticion', o.repeticion, 'aviso_min', o.aviso_min) AS j
    FROM nucleo.ocurrencias(desde, hasta) o
    ORDER BY o.inicio
    LIMIT tope
  ) x
$$;

/* ============ Inteligencia de agenda ============ */

-- Actividades que se cruzan con el rango indicado
CREATE OR REPLACE FUNCTION nucleo.choques(ini timestamptz, fin_ timestamptz, excluir int DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', o.evento_id, 'titulo', o.titulo,
           'fecha', to_char(o.inicio, 'YYYY-MM-DD'),
           'hora', to_char(o.inicio, 'HH24:MI'), 'hora_fin', to_char(o.fin, 'HH24:MI'))
         ORDER BY o.inicio), '[]'::jsonb)
  FROM nucleo.ocurrencias(ini, fin_) o
  WHERE excluir IS NULL OR o.evento_id <> excluir
$$;

-- Espacios libres de un dia con al menos "duracion" minutos
CREATE OR REPLACE FUNCTION nucleo.huecos(dia date, duracion int DEFAULT 60,
                                         desde_h time DEFAULT '07:00', hasta_h time DEFAULT '21:00')
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
  marca  timestamptz := (dia + desde_h)::timestamptz;
  tope   timestamptz := (dia + hasta_h)::timestamptz;
  r      record;
  libres jsonb := '[]'::jsonb;
BEGIN
  -- Si es hoy, solo desde la proxima media hora
  IF marca < now() THEN
    marca := GREATEST(marca, to_timestamp(ceil(extract(epoch FROM now()) / 1800) * 1800));
  END IF;
  FOR r IN SELECT o.inicio, o.fin FROM nucleo.ocurrencias(marca, tope) o ORDER BY o.inicio LOOP
    IF r.inicio - marca >= make_interval(mins => duracion) THEN
      libres := libres || jsonb_build_object('desde', to_char(marca, 'HH24:MI'), 'hasta', to_char(r.inicio, 'HH24:MI'),
                                             'minutos', (extract(epoch FROM r.inicio - marca) / 60)::int);
    END IF;
    marca := GREATEST(marca, r.fin);
  END LOOP;
  IF tope - marca >= make_interval(mins => duracion) THEN
    libres := libres || jsonb_build_object('desde', to_char(marca, 'HH24:MI'), 'hasta', to_char(tope, 'HH24:MI'),
                                           'minutos', (extract(epoch FROM tope - marca) / 60)::int);
  END IF;
  RETURN jsonb_build_object('dia', nucleo.dia_nombre(dia::timestamptz), 'fecha', to_char(dia, 'YYYY-MM-DD'),
                            'duracion_buscada', duracion, 'huecos', libres);
END $$;

CREATE OR REPLACE FUNCTION nucleo.ficha_evento(eid int) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('id', e.id, 'titulo', e.titulo, 'detalle', COALESCE(e.detalle, ''),
           'categoria', e.categoria, 'prioridad', e.prioridad,
           'dia', nucleo.dia_nombre(e.inicio), 'fecha', to_char(e.inicio, 'YYYY-MM-DD'),
           'hora', to_char(e.inicio, 'HH24:MI'), 'hora_fin', to_char(e.fin, 'HH24:MI'),
           'repeticion', e.repeticion, 'repetir_hasta', e.repetir_hasta,
           'aviso_min', e.aviso_min, 'estado', e.estado)
  FROM nucleo.eventos e WHERE e.id = eid
$$;

/* ============ Estilo: AssistentD observa como escribe la persona ============ */

CREATE OR REPLACE FUNCTION nucleo.observar_estilo(t text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  f numeric; e numeric; x numeric; peso numeric;
BEGIN
  IF t IS NULL OR char_length(trim(t)) < 2 THEN RETURN; END IF;
  f := CASE
         WHEN t ~* '\m(usted|ustedes|le agradezco|disculpe|cordialmente|estimad[oa]|buenos d[ií]as|buenas tardes|buenas noches|ser[ií]a tan amable)\M' THEN 1
         WHEN t ~* '\m(pana|chamo|chama|vale|mano|bro|marico|xd|jaja\w*|jeje\w*|pq|xq|tqm|epa|na guara|porfa|oye|dale|ok)\M' THEN 0
         ELSE 0.5 END;
  e := CASE WHEN t ~ '[\U0001F300-\U0001FAFF☀-➿]' THEN 1 ELSE 0 END;
  x := CASE WHEN t ~ '!' THEN 1 ELSE 0 END;
  UPDATE nucleo.perfil SET
    mensajes_vistos = mensajes_vistos + 1,
    largo_promedio  = largo_promedio + (char_length(t) - largo_promedio) / LEAST(mensajes_vistos + 1, 12),
    formalidad      = formalidad + (f - formalidad) / LEAST(mensajes_vistos + 2, 12),
    emojis          = emojis + (e - emojis) / LEAST(mensajes_vistos + 1, 12),
    entusiasmo      = entusiasmo + (x - entusiasmo) / LEAST(mensajes_vistos + 1, 12)
  WHERE id = 1;
END $$;

/* ============ Herramientas que la IA puede usar ============ */

CREATE OR REPLACE FUNCTION nucleo.herramienta(nombre text, a jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_ini timestamptz; v_fin timestamptz; v_dur int; v_id int; v_ch jsonb; v_txt text;
  ev nucleo.eventos%ROWTYPE;
  cats text[] := ARRAY['estudio','trabajo','personal','salud','social','tramite'];
  reps text[] := ARRAY['no','diaria','laborables','semanal','mensual'];
  temas text[] := ARRAY['general','gustos','rutina','estudios','trabajo','personas','metas'];
BEGIN
  a := COALESCE(a, '{}'::jsonb);

  CASE nombre

  WHEN 'crear_evento' THEN
    v_ini := nucleo.a_fecha(a->>'inicio');
    IF v_ini IS NULL THEN RETURN jsonb_build_object('guardado', false, 'motivo', 'falta la fecha y hora de inicio'); END IF;
    v_dur := GREATEST(nucleo.entero(a->>'duracion_min', 60), 5);
    v_fin := v_ini + make_interval(mins => v_dur);
    IF v_ini < now() - interval '5 minutes' AND COALESCE(NULLIF(a->>'repeticion', ''), 'no') = 'no' THEN
      RETURN jsonb_build_object('guardado', false, 'motivo', 'la fecha ya paso', 'ahora', to_char(now(), 'YYYY-MM-DD HH24:MI'));
    END IF;
    v_ch := nucleo.choques(v_ini, v_fin);
    IF jsonb_array_length(v_ch) > 0 AND NOT COALESCE((a->>'forzar')::boolean, false) THEN
      RETURN jsonb_build_object('guardado', false, 'motivo', 'choque de horario', 'choques', v_ch,
               'huecos_sugeridos', nucleo.huecos(v_ini::date, v_dur)->'huecos',
               'nota', 'Pregunta a la persona si lo mueve a un hueco libre o si lo guardas igual con forzar=true');
    END IF;
    INSERT INTO nucleo.eventos (titulo, detalle, categoria, prioridad, inicio, fin, repeticion, repetir_hasta, aviso_min)
    VALUES (trim(a->>'titulo'),
            NULLIF(trim(COALESCE(a->>'detalle', '')), ''),
            CASE WHEN a->>'categoria' = ANY (cats) THEN a->>'categoria' ELSE 'personal' END,
            LEAST(GREATEST(nucleo.entero(a->>'prioridad', 2), 1), 3),
            v_ini, v_fin,
            CASE WHEN a->>'repeticion' = ANY (reps) THEN a->>'repeticion' ELSE 'no' END,
            NULLIF(trim(COALESCE(a->>'repetir_hasta', '')), '')::date,
            LEAST(GREATEST(nucleo.entero(a->>'aviso_min', 20), 0), 4320))
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('guardado', true, 'evento', nucleo.ficha_evento(v_id),
                              'cruces_aceptados', CASE WHEN jsonb_array_length(v_ch) > 0 THEN v_ch END);

  WHEN 'listar_eventos' THEN
    v_ini := COALESCE(nucleo.a_fecha(a->>'desde'), now());
    v_fin := COALESCE(nucleo.a_fecha_fin(a->>'hasta'), v_ini + interval '14 days');
    v_ch := nucleo.agenda(v_ini, v_fin, 80);
    IF NULLIF(trim(COALESCE(a->>'buscar', '')), '') IS NOT NULL THEN
      SELECT COALESCE(jsonb_agg(j), '[]'::jsonb) INTO v_ch FROM jsonb_array_elements(v_ch) j
      WHERE (j->>'titulo') ILIKE '%' || trim(a->>'buscar') || '%' OR (j->>'detalle') ILIKE '%' || trim(a->>'buscar') || '%';
    END IF;
    RETURN jsonb_build_object('desde', to_char(v_ini, 'YYYY-MM-DD HH24:MI'), 'hasta', to_char(v_fin, 'YYYY-MM-DD HH24:MI'),
                              'total', jsonb_array_length(v_ch), 'eventos', v_ch);

  WHEN 'editar_evento' THEN
    SELECT * INTO ev FROM nucleo.eventos WHERE id = nucleo.entero(a->>'id', 0) AND estado = 'activo';
    IF NOT FOUND THEN RETURN jsonb_build_object('editado', false, 'motivo', 'no existe una actividad activa con ese id'); END IF;
    v_dur := nucleo.entero(a->>'duracion_min', (extract(epoch FROM ev.fin - ev.inicio) / 60)::int);
    v_ini := COALESCE(nucleo.a_fecha(a->>'inicio'), ev.inicio);
    v_fin := v_ini + make_interval(mins => GREATEST(v_dur, 5));
    IF v_ini <> ev.inicio OR v_fin <> ev.fin THEN
      v_ch := nucleo.choques(v_ini, v_fin, ev.id);
      IF jsonb_array_length(v_ch) > 0 AND NOT COALESCE((a->>'forzar')::boolean, false) THEN
        RETURN jsonb_build_object('editado', false, 'motivo', 'choque de horario', 'choques', v_ch,
                 'huecos_sugeridos', nucleo.huecos(v_ini::date, v_dur)->'huecos');
      END IF;
      DELETE FROM nucleo.avisos WHERE evento_id = ev.id;
    END IF;
    UPDATE nucleo.eventos SET
      titulo        = COALESCE(NULLIF(trim(COALESCE(a->>'titulo', '')), ''), titulo),
      detalle       = CASE WHEN a ? 'detalle' THEN NULLIF(trim(COALESCE(a->>'detalle', '')), '') ELSE detalle END,
      categoria     = CASE WHEN a->>'categoria' = ANY (cats) THEN a->>'categoria' ELSE categoria END,
      prioridad     = CASE WHEN NULLIF(a->>'prioridad', '') IS NOT NULL THEN LEAST(GREATEST(nucleo.entero(a->>'prioridad', 2), 1), 3) ELSE prioridad END,
      inicio        = v_ini,
      fin           = v_fin,
      repeticion    = CASE WHEN a->>'repeticion' = ANY (reps) THEN a->>'repeticion' ELSE repeticion END,
      repetir_hasta = CASE WHEN a ? 'repetir_hasta' THEN NULLIF(trim(COALESCE(a->>'repetir_hasta', '')), '')::date ELSE repetir_hasta END,
      aviso_min     = CASE WHEN NULLIF(a->>'aviso_min', '') IS NOT NULL THEN LEAST(GREATEST(nucleo.entero(a->>'aviso_min', 20), 0), 4320) ELSE aviso_min END
    WHERE id = ev.id;
    IF NULLIF(a->>'aviso_min', '') IS NOT NULL THEN DELETE FROM nucleo.avisos WHERE evento_id = ev.id AND tipo = 'antes'; END IF;
    RETURN jsonb_build_object('editado', true, 'evento', nucleo.ficha_evento(ev.id));

  WHEN 'cancelar_evento' THEN
    UPDATE nucleo.eventos SET estado = 'cancelado'
    WHERE id = nucleo.entero(a->>'id', 0) AND estado = 'activo' RETURNING titulo INTO v_txt;
    RETURN jsonb_build_object('cancelado', v_txt IS NOT NULL, 'titulo', v_txt);

  WHEN 'buscar_huecos' THEN
    RETURN nucleo.huecos(COALESCE(NULLIF(trim(COALESCE(a->>'dia', '')), '')::date, current_date),
                         GREATEST(nucleo.entero(a->>'duracion_min', 60), 10),
                         COALESCE(NULLIF(trim(COALESCE(a->>'desde_hora', '')), '')::time, '07:00'),
                         COALESCE(NULLIF(trim(COALESCE(a->>'hasta_hora', '')), '')::time, '21:00'));

  WHEN 'resumen_dia' THEN
    v_ini := COALESCE(NULLIF(trim(COALESCE(a->>'dia', '')), '')::date, current_date)::timestamptz;
    RETURN jsonb_build_object(
      'dia', nucleo.dia_nombre(v_ini), 'fecha', to_char(v_ini, 'YYYY-MM-DD'),
      'eventos', nucleo.agenda(v_ini, v_ini + interval '1 day'),
      'tareas_que_vencen', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'texto', texto, 'prioridad', prioridad)), '[]'::jsonb)
                            FROM nucleo.tareas WHERE NOT hecha AND limite <= v_ini::date),
      'espacios_libres', nucleo.huecos(v_ini::date, 30)->'huecos');

  WHEN 'agregar_tarea' THEN
    INSERT INTO nucleo.tareas (texto, prioridad, limite)
    VALUES (trim(a->>'texto'), LEAST(GREATEST(nucleo.entero(a->>'prioridad', 2), 1), 3),
            NULLIF(trim(COALESCE(a->>'limite', '')), '')::date)
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('guardada', true, 'id', v_id);

  WHEN 'listar_tareas' THEN
    RETURN jsonb_build_object('tareas', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'texto', texto, 'prioridad', prioridad,
                       'limite', limite, 'hecha', hecha) ORDER BY hecha, prioridad, limite NULLS LAST, id), '[]'::jsonb)
      FROM nucleo.tareas
      WHERE NOT hecha OR (COALESCE((a->>'incluir_hechas')::boolean, false) AND hecha_en > now() - interval '7 days')));

  WHEN 'completar_tarea' THEN
    UPDATE nucleo.tareas SET hecha = NOT COALESCE((a->>'deshacer')::boolean, false),
                             hecha_en = CASE WHEN COALESCE((a->>'deshacer')::boolean, false) THEN NULL ELSE now() END
    WHERE id = nucleo.entero(a->>'id', 0) RETURNING texto INTO v_txt;
    RETURN jsonb_build_object('actualizada', v_txt IS NOT NULL, 'texto', v_txt);

  WHEN 'borrar_tarea' THEN
    DELETE FROM nucleo.tareas WHERE id = nucleo.entero(a->>'id', 0) RETURNING texto INTO v_txt;
    RETURN jsonb_build_object('borrada', v_txt IS NOT NULL, 'texto', v_txt);

  WHEN 'guardar_nota' THEN
    INSERT INTO nucleo.notas (texto) VALUES (trim(a->>'texto')) RETURNING id INTO v_id;
    RETURN jsonb_build_object('guardada', true, 'id', v_id);

  WHEN 'buscar_notas' THEN
    RETURN jsonb_build_object('notas', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'texto', texto, 'fecha', to_char(creada, 'YYYY-MM-DD')) ORDER BY id DESC), '[]'::jsonb)
      FROM (SELECT * FROM nucleo.notas
            WHERE NULLIF(trim(COALESCE(a->>'buscar', '')), '') IS NULL OR texto ILIKE '%' || trim(a->>'buscar') || '%'
            ORDER BY id DESC LIMIT 25) n));

  WHEN 'borrar_nota' THEN
    DELETE FROM nucleo.notas WHERE id = nucleo.entero(a->>'id', 0) RETURNING left(texto, 60) INTO v_txt;
    RETURN jsonb_build_object('borrada', v_txt IS NOT NULL);

  WHEN 'recordar_dato' THEN
    v_txt := trim(COALESCE(a->>'dato', ''));
    IF EXISTS (SELECT 1 FROM nucleo.recuerdos WHERE lower(dato) = lower(v_txt)) THEN
      RETURN jsonb_build_object('guardado', false, 'motivo', 'ya lo sabia');
    END IF;
    INSERT INTO nucleo.recuerdos (tema, dato, origen)
    VALUES (CASE WHEN a->>'tema' = ANY (temas) THEN a->>'tema' ELSE 'general' END, v_txt,
            CASE WHEN a->>'origen' = 'manual' THEN 'manual' ELSE 'conversacion' END)
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('guardado', true, 'id', v_id);

  WHEN 'olvidar_dato' THEN
    DELETE FROM nucleo.recuerdos WHERE id = nucleo.entero(a->>'id', 0) RETURNING dato INTO v_txt;
    RETURN jsonb_build_object('olvidado', v_txt IS NOT NULL, 'dato', v_txt);

  WHEN 'ajustar_personalidad' THEN
    v_txt := lower(trim(COALESCE(a->>'aspecto', '')));
    IF v_txt = '' THEN RETURN jsonb_build_object('ajustado', false, 'motivo', 'falta el aspecto'); END IF;
    UPDATE nucleo.perfil SET preferencias = CASE
        WHEN NULLIF(trim(COALESCE(a->>'preferencia', '')), '') IS NULL THEN preferencias - v_txt
        ELSE preferencias || jsonb_build_object(v_txt, trim(a->>'preferencia')) END
    WHERE id = 1;
    RETURN jsonb_build_object('ajustado', true, 'preferencias', (SELECT preferencias FROM nucleo.perfil WHERE id = 1));

  WHEN 'cambiar_nombre' THEN
    UPDATE nucleo.perfil SET como_llamar = NULLIF(trim(COALESCE(a->>'como_llamar', '')), '') WHERE id = 1;
    RETURN jsonb_build_object('actualizado', true);

  ELSE
    RETURN jsonb_build_object('error', 'herramienta desconocida: ' || COALESCE(nombre, '(vacia)'));
  END CASE;

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('error', SQLERRM, 'pista', 'Revisa el formato: fechas AAAA-MM-DD HH:MM, ids numericos.');
END $$;

/* Ejecuta todas las herramientas que pidio la IA en una vuelta */
CREATE OR REPLACE FUNCTION nucleo.ejecutar_lote(estado jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  c jsonb; r jsonb; salida jsonb := '[]'::jsonb;
  cambia boolean := COALESCE((estado->>'hubo_cambios')::boolean, false);
  lectura text[] := ARRAY['listar_eventos','buscar_huecos','resumen_dia','listar_tareas','buscar_notas'];
BEGIN
  FOR c IN SELECT * FROM jsonb_array_elements(COALESCE(estado->'llamadas', '[]'::jsonb)) LOOP
    r := nucleo.herramienta(c->>'name', c->'args');
    salida := salida || jsonb_build_object('name', c->>'name', 'id', c->'id', 'resultado', r);
    IF NOT (c->>'name' = ANY (lectura)) THEN cambia := true; END IF;
  END LOOP;
  RETURN (estado - 'llamadas') || jsonb_build_object('resultados', salida, 'hubo_cambios', cambia);
END $$;

/* ============ Contexto para cada mensaje ============ */

CREATE OR REPLACE FUNCTION nucleo.contexto(entrada text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_id bigint := 0;
  corte bigint := COALESCE((SELECT valor::bigint FROM nucleo.ajustes WHERE clave = 'corte_historial'), 0);
BEGIN
  IF NULLIF(trim(COALESCE(entrada, '')), '') IS NOT NULL THEN
    INSERT INTO nucleo.mensajes (rol, texto) VALUES ('persona', left(trim(entrada), 4000)) RETURNING id INTO v_id;
    PERFORM nucleo.observar_estilo(entrada);
  ELSE
    v_id := COALESCE((SELECT max(id) + 1 FROM nucleo.mensajes), 1);
  END IF;

  RETURN jsonb_build_object(
    'clave',   (SELECT valor FROM nucleo.ajustes WHERE clave = 'gemini_clave'),
    'modelos', COALESCE((SELECT valor::jsonb FROM nucleo.ajustes WHERE clave = 'gemini_modelos'), '[]'::jsonb),
    'perfil',  (SELECT to_jsonb(p) - 'id' - 'creado' FROM nucleo.perfil p WHERE id = 1),
    'recuerdos', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'tema', tema, 'dato', dato) ORDER BY id), '[]'::jsonb)
                  FROM nucleo.recuerdos),
    'historial', (SELECT COALESCE(jsonb_agg(jsonb_build_object('rol', rol, 'texto', texto) ORDER BY id), '[]'::jsonb)
                  FROM (SELECT * FROM nucleo.mensajes WHERE id < v_id AND id > corte ORDER BY id DESC LIMIT 16) h),
    'entrada', entrada,
    'ahora',   to_char(now(), 'YYYY-MM-DD HH24:MI'),
    'hoy',     nucleo.dia_nombre(now()),
    'zona',    current_setting('TimeZone'),
    'calendario', (SELECT jsonb_agg(nucleo.dia_nombre(d) || ' ' || to_char(d, 'YYYY-MM-DD') ORDER BY d)
                   FROM generate_series(current_date::timestamptz, current_date + 13, interval '1 day') d),
    'proximos', nucleo.agenda(now(), now() + interval '7 days', 25),
    'tareas',  (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'texto', texto, 'prioridad', prioridad, 'limite', limite)
                                ORDER BY prioridad, limite NULLS LAST), '[]'::jsonb)
                FROM (SELECT * FROM nucleo.tareas WHERE NOT hecha ORDER BY prioridad, limite NULLS LAST LIMIT 15) t)
  );
END $$;

CREATE OR REPLACE FUNCTION nucleo.guardar_respuesta(t text) RETURNS jsonb
LANGUAGE sql AS $$
  INSERT INTO nucleo.mensajes (rol, texto) VALUES ('asistente', t) RETURNING jsonb_build_object('id', id)
$$;

/* ============ Lo que necesita el panel ============ */

CREATE OR REPLACE FUNCTION nucleo.panel(desde text, hasta text) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  d timestamptz := COALESCE(nucleo.a_fecha(desde), date_trunc('week', now()));
  h timestamptz := COALESCE(nucleo.a_fecha_fin(hasta), d + interval '7 days');
  corte bigint := COALESCE((SELECT valor::bigint FROM nucleo.ajustes WHERE clave = 'corte_historial'), 0);
BEGIN
  RETURN jsonb_build_object(
    'configurado', EXISTS (SELECT 1 FROM nucleo.ajustes WHERE clave = 'gemini_clave'),
    'modelo', (SELECT valor::jsonb->>0 FROM nucleo.ajustes WHERE clave = 'gemini_modelos'),
    'perfil', (SELECT to_jsonb(p) - 'id' FROM nucleo.perfil p WHERE id = 1),
    'ahora', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SS'),
    'eventos', nucleo.agenda(d, h),
    'tareas', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'texto', texto, 'prioridad', prioridad,
                         'limite', limite, 'hecha', hecha) ORDER BY hecha, prioridad, limite NULLS LAST, id), '[]'::jsonb)
               FROM nucleo.tareas WHERE NOT hecha OR hecha_en > now() - interval '1 day'),
    'notas', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'texto', texto, 'fecha', to_char(creada, 'YYYY-MM-DD')) ORDER BY id DESC), '[]'::jsonb)
              FROM (SELECT * FROM nucleo.notas ORDER BY id DESC LIMIT 30) n),
    'recuerdos', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'tema', tema, 'dato', dato) ORDER BY id DESC), '[]'::jsonb)
                  FROM nucleo.recuerdos),
    'mensajes', (SELECT COALESCE(jsonb_agg(jsonb_build_object('rol', rol, 'texto', texto, 'hora', to_char(creado, 'HH24:MI')) ORDER BY id), '[]'::jsonb)
                 FROM (SELECT * FROM nucleo.mensajes WHERE id > corte ORDER BY id DESC LIMIT 40) m),
    'boletin', (SELECT texto FROM nucleo.boletines WHERE dia = current_date)
  );
END $$;

CREATE OR REPLACE FUNCTION nucleo.configurar(datos jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  IF NULLIF(datos->>'clave', '') IS NOT NULL THEN
    INSERT INTO nucleo.ajustes (clave, valor) VALUES ('gemini_clave', datos->>'clave')
    ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor, cambiado = now();
  END IF;
  IF jsonb_typeof(datos->'modelos') = 'array' AND jsonb_array_length(datos->'modelos') > 0 THEN
    INSERT INTO nucleo.ajustes (clave, valor) VALUES ('gemini_modelos', (datos->'modelos')::text)
    ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor, cambiado = now();
  END IF;
  IF NULLIF(trim(COALESCE(datos->>'nombre', '')), '') IS NOT NULL THEN
    UPDATE nucleo.perfil SET nombre = trim(datos->>'nombre'),
                             como_llamar = COALESCE(como_llamar, split_part(trim(datos->>'nombre'), ' ', 1))
    WHERE id = 1;
  END IF;
  IF NULLIF(trim(COALESCE(datos->>'sobre_mi', '')), '') IS NOT NULL THEN
    UPDATE nucleo.perfil SET sobre_mi = left(trim(datos->>'sobre_mi'), 600) WHERE id = 1;
  END IF;
  RETURN jsonb_build_object('listo', true);
END $$;

/* Acciones que el panel hace sin pasar por la IA */
CREATE OR REPLACE FUNCTION nucleo.accion(tipo text, datos jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  IF tipo = 'nueva_conversacion' THEN
    INSERT INTO nucleo.ajustes (clave, valor)
    VALUES ('corte_historial', COALESCE((SELECT max(id) FROM nucleo.mensajes), 0)::text)
    ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor, cambiado = now();
    RETURN jsonb_build_object('listo', true);
  ELSIF tipo = 'reiniciar_estilo' THEN
    UPDATE nucleo.perfil SET mensajes_vistos = 0, largo_promedio = 0, formalidad = 0.5, emojis = 0,
                             entusiasmo = 0, preferencias = '{}'::jsonb WHERE id = 1;
    RETURN jsonb_build_object('listo', true);
  ELSIF tipo IN ('completar_tarea','borrar_tarea','agregar_tarea','guardar_nota','borrar_nota',
                 'olvidar_dato','recordar_dato','cancelar_evento','ajustar_personalidad') THEN
    RETURN nucleo.herramienta(tipo, datos);
  END IF;
  RETURN jsonb_build_object('error', 'accion no permitida');
END $$;

/* Avisos que ya tocan. Cada uno se entrega una sola vez */
CREATE OR REPLACE FUNCTION nucleo.avisos_pendientes() RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE salida jsonb;
BEGIN
  WITH cand AS (
    SELECT o.evento_id, o.titulo, o.detalle, o.inicio, o.prioridad,
           CASE WHEN o.inicio <= now() THEN 'ahora' ELSE 'antes' END AS tipo
    FROM nucleo.ocurrencias(now() - interval '10 minutes', now() + interval '3 days') o
    WHERE (o.inicio <= now() AND o.inicio > now() - interval '10 minutes')
       OR (o.aviso_min > 0 AND o.inicio > now() AND o.inicio - make_interval(mins => o.aviso_min) <= now())
  ), nuevos AS (
    INSERT INTO nucleo.avisos (evento_id, ocurrencia, tipo)
    SELECT evento_id, inicio, tipo FROM cand
    ON CONFLICT DO NOTHING
    RETURNING evento_id, ocurrencia, tipo
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', c.evento_id, 'titulo', c.titulo, 'detalle', COALESCE(c.detalle, ''), 'tipo', c.tipo,
           'hora', to_char(c.inicio, 'HH24:MI'), 'prioridad', c.prioridad,
           'faltan_min', GREATEST(0, ceil(extract(epoch FROM c.inicio - now()) / 60))::int)), '[]'::jsonb)
  INTO salida
  FROM nuevos n JOIN cand c ON c.evento_id = n.evento_id AND c.inicio = n.ocurrencia AND c.tipo = n.tipo;
  RETURN salida;
END $$;

/* Datos para el resumen del dia */
CREATE OR REPLACE FUNCTION nucleo.datos_boletin(forzar boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  RETURN jsonb_build_object(
    'existe', NOT forzar AND EXISTS (SELECT 1 FROM nucleo.boletines WHERE dia = current_date),
    'texto', (SELECT texto FROM nucleo.boletines WHERE dia = current_date),
    'clave', (SELECT valor FROM nucleo.ajustes WHERE clave = 'gemini_clave'),
    'modelos', COALESCE((SELECT valor::jsonb FROM nucleo.ajustes WHERE clave = 'gemini_modelos'), '[]'::jsonb),
    'perfil', (SELECT to_jsonb(p) - 'id' - 'creado' FROM nucleo.perfil p WHERE id = 1),
    'recuerdos', (SELECT COALESCE(jsonb_agg(dato), '[]'::jsonb) FROM (SELECT dato FROM nucleo.recuerdos ORDER BY id DESC LIMIT 12) r),
    'dia', nucleo.herramienta('resumen_dia', '{}'::jsonb),
    'pendientes', nucleo.herramienta('listar_tareas', '{}'::jsonb)->'tareas'
  );
END $$;

CREATE OR REPLACE FUNCTION nucleo.guardar_boletin(t text) RETURNS jsonb
LANGUAGE sql AS $$
  INSERT INTO nucleo.boletines (dia, texto) VALUES (current_date, t)
  ON CONFLICT (dia) DO UPDATE SET texto = EXCLUDED.texto, creado = now()
  RETURNING jsonb_build_object('texto', texto)
$$;
