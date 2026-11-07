/* ------------------------------------------------------------------
   AssistentD | Estructura de datos
   Se aplica en cada encendido. Todo es repetible sin perder datos.
   Esquemas:
     nucleo -> datos del asistente (agenda, perfil, memoria)
     motor  -> tablas internas de n8n
------------------------------------------------------------------- */
SET client_min_messages = warning;

CREATE SCHEMA IF NOT EXISTS nucleo;
CREATE SCHEMA IF NOT EXISTS motor;

/* Ajustes generales (clave de Gemini, modelos disponibles, etc.) */
CREATE TABLE IF NOT EXISTS nucleo.ajustes (
    clave     text PRIMARY KEY,
    valor     text NOT NULL,
    cambiado  timestamptz NOT NULL DEFAULT now()
);

/* Perfil del dueño. Una sola fila: AssistentD vive en una sola computadora */
CREATE TABLE IF NOT EXISTS nucleo.perfil (
    id                smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    nombre            text,
    como_llamar       text,
    sobre_mi          text,
    -- Estilo observado en sus mensajes (promedios moviles entre 0 y 1)
    mensajes_vistos   integer NOT NULL DEFAULT 0,
    largo_promedio    numeric NOT NULL DEFAULT 0,
    formalidad        numeric NOT NULL DEFAULT 0.5,
    emojis            numeric NOT NULL DEFAULT 0,
    entusiasmo        numeric NOT NULL DEFAULT 0,
    -- Ajustes que la persona pidio de forma explicita ("se mas breve")
    preferencias      jsonb   NOT NULL DEFAULT '{}'::jsonb,
    creado            timestamptz NOT NULL DEFAULT now()
);
INSERT INTO nucleo.perfil (id) VALUES (1) ON CONFLICT DO NOTHING;

/* Cosas que AssistentD aprende de la persona */
CREATE TABLE IF NOT EXISTS nucleo.recuerdos (
    id       serial PRIMARY KEY,
    tema     text NOT NULL DEFAULT 'general'
             CHECK (tema IN ('general','gustos','rutina','estudios','trabajo','personas','metas')),
    dato     text NOT NULL CHECK (char_length(trim(dato)) BETWEEN 2 AND 300),
    origen   text NOT NULL DEFAULT 'conversacion' CHECK (origen IN ('conversacion','bienvenida','manual')),
    creado   timestamptz NOT NULL DEFAULT now()
);

/* Historial de la conversacion */
CREATE TABLE IF NOT EXISTS nucleo.mensajes (
    id      bigserial PRIMARY KEY,
    rol     text NOT NULL CHECK (rol IN ('persona','asistente')),
    texto   text NOT NULL,
    creado  timestamptz NOT NULL DEFAULT now()
);

/* Agenda */
CREATE TABLE IF NOT EXISTS nucleo.eventos (
    id             serial PRIMARY KEY,
    titulo         text NOT NULL CHECK (char_length(trim(titulo)) BETWEEN 1 AND 160),
    detalle        text,
    categoria      text NOT NULL DEFAULT 'personal'
                   CHECK (categoria IN ('estudio','trabajo','personal','salud','social','tramite')),
    prioridad      smallint NOT NULL DEFAULT 2 CHECK (prioridad BETWEEN 1 AND 3),  -- 1 alta, 3 baja
    inicio         timestamptz NOT NULL,
    fin            timestamptz NOT NULL,
    repeticion     text NOT NULL DEFAULT 'no'
                   CHECK (repeticion IN ('no','diaria','laborables','semanal','mensual')),
    repetir_hasta  date,
    aviso_min      integer NOT NULL DEFAULT 20 CHECK (aviso_min BETWEEN 0 AND 4320),
    estado         text NOT NULL DEFAULT 'activo' CHECK (estado IN ('activo','cancelado')),
    creado         timestamptz NOT NULL DEFAULT now(),
    CHECK (fin > inicio)
);
CREATE INDEX IF NOT EXISTS eventos_activos_inicio ON nucleo.eventos (inicio) WHERE estado = 'activo';

/* Avisos ya entregados (uno por ocurrencia y tipo, asi nunca se repiten) */
CREATE TABLE IF NOT EXISTS nucleo.avisos (
    evento_id   integer NOT NULL REFERENCES nucleo.eventos(id) ON DELETE CASCADE,
    ocurrencia  timestamptz NOT NULL,
    tipo        text NOT NULL CHECK (tipo IN ('antes','ahora')),
    entregado   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (evento_id, ocurrencia, tipo)
);

/* Pendientes sin hora fija */
CREATE TABLE IF NOT EXISTS nucleo.tareas (
    id         serial PRIMARY KEY,
    texto      text NOT NULL CHECK (char_length(trim(texto)) BETWEEN 1 AND 200),
    prioridad  smallint NOT NULL DEFAULT 2 CHECK (prioridad BETWEEN 1 AND 3),
    limite     date,
    hecha      boolean NOT NULL DEFAULT false,
    creada     timestamptz NOT NULL DEFAULT now(),
    hecha_en   timestamptz
);

/* Notas rapidas */
CREATE TABLE IF NOT EXISTS nucleo.notas (
    id      serial PRIMARY KEY,
    texto   text NOT NULL CHECK (char_length(trim(texto)) BETWEEN 1 AND 2000),
    creada  timestamptz NOT NULL DEFAULT now()
);

/* Resumen de cada dia, escrito por la IA */
CREATE TABLE IF NOT EXISTS nucleo.boletines (
    dia     date PRIMARY KEY,
    texto   text NOT NULL,
    creado  timestamptz NOT NULL DEFAULT now()
);
