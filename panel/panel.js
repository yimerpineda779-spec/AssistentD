/* AssistentD | logica del panel
   Todo pasa por /api/... (Caddy lo entrega a los webhooks de n8n). */
'use strict';

const MESES = ['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'];
const DIAS_CORTOS = ['lun','mar','mié','jue','vie','sáb','dom'];
const DIAS = ['domingo','lunes','martes','miércoles','jueves','viernes','sábado'];
const CATEGORIAS = { estudio: 'Estudio', trabajo: 'Trabajo', personal: 'Personal', salud: 'Salud', social: 'Social', tramite: 'Trámite' };
const REPETICION = { diaria: 'cada día', laborables: 'lunes a viernes', semanal: 'cada semana', mensual: 'cada mes' };
const TEMAS = { general: 'General', gustos: 'Gustos', rutina: 'Rutina', estudios: 'Estudios', trabajo: 'Trabajo', personas: 'Personas', metas: 'Metas' };

const $ = (s) => document.querySelector(s);
const el = (etiqueta, clase, texto) => {
  const n = document.createElement(etiqueta);
  if (clase) n.className = clase;
  if (texto !== undefined) n.textContent = texto;
  return n;
};

const estado = {
  datos: null,
  dia: soloFecha(new Date()),
  semana: lunesDe(new Date()),
  ocupado: false,
  avisosActivos: leerPreferencia('avisos', true),
};

/* ---------- utilidades ---------- */
function soloFecha(d) { const x = new Date(d); x.setHours(0, 0, 0, 0); return x; }
function lunesDe(d) { const x = soloFecha(d); const w = (x.getDay() + 6) % 7; x.setDate(x.getDate() - w); return x; }
function sumarDias(d, n) { const x = new Date(d); x.setDate(x.getDate() + n); return x; }
function iso(d) { return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0'); }
function mismaFecha(a, b) { return iso(a) === iso(b); }
function leerPreferencia(k, def) { try { const v = localStorage.getItem('adx.' + k); return v === null ? def : JSON.parse(v); } catch { return def; } }
function guardarPreferencia(k, v) { try { localStorage.setItem('adx.' + k, JSON.stringify(v)); } catch { /* sin almacenamiento */ } }

async function api(ruta, cuerpo) {
  const opciones = cuerpo === undefined
    ? { cache: 'no-store' }
    : { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(cuerpo) };
  const r = await fetch('/api/' + ruta, opciones);
  const texto = await r.text();
  let datos = {};
  try { datos = texto ? JSON.parse(texto) : {}; } catch { datos = { error: texto }; }
  if (!r.ok) throw Object.assign(new Error(datos.error || ('Error ' + r.status)), { datos, status: r.status });
  return datos;
}

// Markdown muy sencillo: negritas, cursivas, listas y saltos de linea
function mdSeguro(t) {
  const esc = String(t || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  const enLinea = (s) => s.replace(/\*\*(.+?)\*\*/g, '<b>$1</b>').replace(/(^|[\s(])\*(?!\s)(.+?)\*(?=[\s).,!?:;]|$)/g, '$1<i>$2</i>');
  return esc.split(/\n{2,}/).map((bloque) => {
    const lineas = bloque.split('\n');
    if (lineas.every((l) => /^\s*([-*•]|\d+[.)])\s+/.test(l))) {
      const tag = /^\s*\d/.test(lineas[0]) ? 'ol' : 'ul';
      return '<' + tag + '>' + lineas.map((l) => '<li>' + enLinea(l.replace(/^\s*([-*•]|\d+[.)])\s+/, '')) + '</li>').join('') + '</' + tag + '>';
    }
    return '<p>' + lineas.map(enLinea).join('<br>') + '</p>';
  }).join('');
}

function mostrarVista(id) {
  document.querySelectorAll('.vista').forEach((v) => v.classList.toggle('activa', v.id === id));
}

/* ---------- arranque ---------- */
async function esperarMotor() {
  const inicio = Date.now();
  for (;;) {
    try { await api('salud'); return; } catch { /* aun no */ }
    const seg = Math.round((Date.now() - inicio) / 1000);
    $('#arranque-detalle').textContent = seg < 20 ? 'Encendiendo el motor…'
      : seg < 90 ? 'Preparando la agenda (' + seg + ' s)…'
      : 'Sigue cargando. Si tarda mucho, revisa que Docker esté abierto.';
    await new Promise((r) => setTimeout(r, 1500));
  }
}

async function iniciar() {
  await esperarMotor();
  try {
    await recargar(true);
  } catch (e) {
    $('#arranque-detalle').textContent = 'No pude leer la agenda: ' + e.message;
    return;
  }
  if (!estado.datos.configurado) { mostrarVista('v-bienvenida'); $('#f-nombre').focus(); return; }
  entrarAlPanel();
}

function entrarAlPanel() {
  mostrarVista('v-panel');
  pintarTodo(true);
  cargarBoletin(false);
  if (estado.relojes) return;
  estado.relojes = true;
  setInterval(revisarAvisos, 20000);
  setTimeout(revisarAvisos, 1500);
  setInterval(() => { pintarReloj(); pintarDia(); }, 30000);
  setInterval(() => recargar(false).catch(() => {}), 120000);
  $('#entrada').focus();
}

async function recargar(conMensajes) {
  const desde = estado.semana;
  const hasta = sumarDias(desde, 6);
  estado.datos = await api('panel?desde=' + iso(desde) + '&hasta=' + iso(hasta));
  if (document.getElementById('v-panel').classList.contains('activa')) pintarTodo(conMensajes);
}

/* ---------- bienvenida ---------- */
function irAPaso(n) {
  document.querySelectorAll('.paso').forEach((p) => p.classList.toggle('visible', p.dataset.paso === String(n)));
  document.querySelectorAll('#pasos-lista li').forEach((li, i) => li.classList.toggle('hecho-actual', i < n));
  const campo = document.querySelector('.paso.visible input, .paso.visible textarea');
  if (campo) campo.focus();
}

document.querySelectorAll('[data-volver]').forEach((b) => b.addEventListener('click', () => irAPaso(b.dataset.volver)));

document.querySelector('.paso[data-paso="1"]').addEventListener('submit', (ev) => {
  ev.preventDefault();
  if ($('#f-nombre').value.trim().length < 2) return;
  irAPaso(2);
});

document.querySelector('.paso[data-paso="2"]').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const clave = $('#f-clave').value.trim();
  const linea = $('#f-clave-estado');
  const boton = $('#b-verificar');
  if (!clave) return;
  boton.disabled = true; linea.className = 'estado-linea'; linea.textContent = 'Probando la clave con Google…';
  try {
    const r = await api('configurar', { clave, nombre: $('#f-nombre').value.trim() });
    if (!r.listo) throw new Error(r.error || 'La clave no funcionó');
    linea.className = 'estado-linea bien'; linea.textContent = 'Clave válida. Usaré ' + r.modelo + '.';
    setTimeout(() => irAPaso(3), 700);
  } catch (e) {
    linea.className = 'estado-linea mal';
    linea.textContent = (e.datos && e.datos.error) || e.message || 'No pude comprobar la clave.';
  } finally { boton.disabled = false; }
});

document.querySelector('.paso[data-paso="3"]').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const sobre = $('#f-sobre').value.trim();
  estado.avisosActivos = $('#f-avisos').checked;
  guardarPreferencia('avisos', estado.avisosActivos);
  if (estado.avisosActivos && 'Notification' in window && Notification.permission === 'default') {
    try { await Notification.requestPermission(); } catch { /* el navegador no lo permite */ }
  }
  if (sobre) { try { await api('configurar', { sobre_mi: sobre }); } catch { /* no es grave */ } }
  await recargar(true);
  entrarAlPanel();
});

// Desde "Sobre ti" se puede cambiar la clave sin perder nada
$('#b-cambiar-clave').addEventListener('click', () => {
  const p = (estado.datos && estado.datos.perfil) || {};
  $('#f-nombre').value = p.nombre || '';
  $('#f-sobre').value = p.sobre_mi || '';
  $('#f-clave').value = '';
  $('#f-clave-estado').textContent = '';
  $('#f-avisos').checked = estado.avisosActivos;
  mostrarVista('v-bienvenida');
  irAPaso(2);
});

/* ---------- pintar panel ---------- */
function pintarTodo(conMensajes) {
  const d = estado.datos;
  $('#modelo').textContent = d.modelo || 'sin modelo';
  pintarReloj();
  pintarSemana();
  pintarDia();
  pintarTareas();
  pintarNotas();
  pintarPerfil();
  pintarAtajos();
  if (conMensajes) pintarMensajes();
}

function pintarReloj() {
  const a = new Date();
  $('#reloj').textContent = String(a.getHours()).padStart(2, '0') + ':' + String(a.getMinutes()).padStart(2, '0');
}

function eventosDe(fecha) {
  return (estado.datos.eventos || []).filter((e) => e.fecha === iso(fecha));
}

function pintarSemana() {
  const caja = $('#semana');
  caja.replaceChildren();
  for (let i = 0; i < 7; i++) {
    const dia = sumarDias(estado.semana, i);
    const b = el('button');
    b.append(el('small', '', DIAS_CORTOS[i]), el('b', '', String(dia.getDate())), el('i'));
    if (mismaFecha(dia, new Date())) b.classList.add('hoy');
    if (mismaFecha(dia, estado.dia)) b.classList.add('elegido');
    if (eventosDe(dia).length) b.classList.add('con-algo');
    b.title = DIAS[dia.getDay()] + ' ' + dia.getDate() + ' de ' + MESES[dia.getMonth()];
    b.addEventListener('click', () => { estado.dia = dia; pintarSemana(); pintarDia(); });
    caja.append(b);
  }
}

function pintarDia() {
  if (!estado.datos) return;
  const dia = estado.dia;
  $('#dia-nombre').textContent = mismaFecha(dia, new Date()) ? 'Hoy, ' + DIAS[dia.getDay()] : DIAS[dia.getDay()];
  $('#dia-numero').textContent = dia.getDate();
  $('#dia-mes').textContent = MESES[dia.getMonth()] + ' ' + dia.getFullYear();

  const caja = $('#linea-tiempo');
  caja.replaceChildren();
  const lista = eventosDe(dia);
  const ahora = new Date();
  const esHoy = mismaFecha(dia, ahora);
  if (!lista.length) {
    caja.append(el('p', 'vacio-dia', esHoy ? 'Nada agendado para hoy. Pídeme que te organice algo.' : 'Día libre.'));
    return;
  }
  let marcaPuesta = !esHoy;
  for (const e of lista) {
    const ini = new Date(e.inicio_iso);
    const fin = new Date(e.fin_iso);
    if (!marcaPuesta && ini > ahora) {
      const m = el('div', 'ahora-marca', 'ahora');
      caja.append(m); marcaPuesta = true;
    }
    const fila = el('div', 'bloque');
    const hora = el('time', 'mono', e.hora);
    const tarjeta = el('div', 'tarjeta-ev');
    tarjeta.style.setProperty('--cat', 'var(--c-' + e.categoria + ')');
    if (fin < ahora) tarjeta.classList.add('paso');
    const titulo = el('h4', '', e.titulo + ' ');
    if (e.prioridad === 1) titulo.append(el('span', 'prio', '●●●'));
    const partes = [e.hora + ' a ' + e.hora_fin, CATEGORIAS[e.categoria] || e.categoria];
    if (REPETICION[e.repeticion]) partes.push(REPETICION[e.repeticion]);
    if (e.aviso_min > 0) partes.push('aviso ' + e.aviso_min + ' min antes');
    tarjeta.append(titulo, el('p', '', partes.join(' · ')));
    if (e.detalle) tarjeta.append(el('p', '', e.detalle));
    const x = el('button', 'x borrar', '×');
    x.title = 'Quitar de la agenda';
    x.addEventListener('click', async () => {
      if (x.dataset.seguro !== '1') { x.dataset.seguro = '1'; x.textContent = '¿Quitar?'; x.style.fontSize = '.75rem'; return; }
      await api('accion', { tipo: 'cancelar_evento', datos: { id: e.id } });
      recargar(false);
    });
    tarjeta.append(x);
    fila.append(hora, tarjeta);
    caja.append(fila);
  }
  if (!marcaPuesta) caja.append(el('div', 'ahora-marca', 'ahora'));
}

function pintarTareas() {
  const ul = $('#lista-tareas');
  ul.replaceChildren();
  const tareas = estado.datos.tareas || [];
  if (!tareas.length) { ul.append(el('li', 'lista-vacia', 'Sin pendientes. Buen trabajo.')); return; }
  for (const t of tareas) {
    const li = el('li', t.hecha ? 'hecha' : '');
    const c = el('input'); c.type = 'checkbox'; c.checked = t.hecha;
    c.addEventListener('change', async () => { await api('accion', { tipo: 'completar_tarea', datos: { id: t.id, deshacer: t.hecha } }); recargar(false); });
    const txt = el('div', 'txt', t.texto);
    if (t.limite) txt.append(el('small', '', 'para el ' + t.limite.split('-').reverse().join('/')));
    const x = el('button', 'x', '×'); x.title = 'Borrar';
    x.addEventListener('click', async () => { await api('accion', { tipo: 'borrar_tarea', datos: { id: t.id } }); recargar(false); });
    li.append(c, el('span', 'marca-prio p' + t.prioridad), txt, x);
    ul.append(li);
  }
}

function pintarNotas() {
  const ul = $('#lista-notas');
  ul.replaceChildren();
  const notas = estado.datos.notas || [];
  if (!notas.length) { ul.append(el('li', 'lista-vacia', 'Aún no hay notas. Dile "anota que…" o escribe arriba.')); return; }
  for (const n of notas) {
    const li = el('li');
    const txt = el('div', 'txt', n.texto);
    txt.append(el('small', '', n.fecha.split('-').reverse().join('/')));
    const x = el('button', 'x', '×'); x.title = 'Borrar';
    x.addEventListener('click', async () => { await api('accion', { tipo: 'borrar_nota', datos: { id: n.id } }); recargar(false); });
    li.append(txt, x);
    ul.append(li);
  }
}

function pintarPerfil() {
  const p = estado.datos.perfil || {};
  $('#perfil-nombre').textContent = p.nombre || 'Tú';
  $('#perfil-visto').textContent = p.mensajes_vistos
    ? 'Aprendido de ' + p.mensajes_vistos + ' mensaje' + (p.mensajes_vistos === 1 ? '' : 's')
    : 'Todavía está conociéndote';

  const medidas = [
    ['Tono', 'Informal', 'Formal', Number(p.formalidad ?? 0.5)],
    ['Largo de tus mensajes', 'Breve', 'Detallado', Math.min(Number(p.largo_promedio || 0) / 160, 1)],
    ['Emojis', 'Pocos', 'Muchos', Number(p.emojis || 0)],
    ['Energía', 'Calmada', 'Efusiva', Number(p.entusiasmo || 0)],
  ];
  const caja = $('#medidores');
  caja.replaceChildren();
  for (const [nombre, izq, der, v] of medidas) {
    const m = el('div', 'medidor');
    const ex = el('div', 'extremos'); ex.append(el('span', '', izq), el('span', '', der));
    const riel = el('div', 'riel'); const punto = el('span'); punto.style.left = Math.round(v * 100) + '%'; riel.append(punto);
    m.append(el('span', '', nombre), riel, ex);
    caja.append(m);
  }

  const pref = $('#preferencias');
  pref.replaceChildren();
  const entradas = Object.entries(p.preferencias || {});
  if (!entradas.length) pref.append(el('span', 'tenue', 'Dile cosas como "sé más breve" o "háblame de usted".'));
  for (const [aspecto, valor] of entradas) {
    const c = el('span', 'chip', valor);
    c.title = aspecto;
    const x = el('button', 'x', '×');
    x.addEventListener('click', async () => { await api('accion', { tipo: 'ajustar_personalidad', datos: { aspecto, preferencia: '' } }); recargar(false); });
    c.append(x); pref.append(c);
  }

  const ul = $('#lista-recuerdos');
  ul.replaceChildren();
  const recuerdos = estado.datos.recuerdos || [];
  if (!recuerdos.length) ul.append(el('li', 'lista-vacia', 'Conversa con AssistentD y aquí verás lo que va aprendiendo.'));
  for (const r of recuerdos) {
    const li = el('li');
    const txt = el('div', 'txt');
    txt.append(el('span', 'tema', TEMAS[r.tema] || r.tema), el('div', '', r.dato));
    const x = el('button', 'x', '×'); x.title = 'Que lo olvide';
    x.addEventListener('click', async () => { await api('accion', { tipo: 'olvidar_dato', datos: { id: r.id } }); recargar(false); });
    li.append(txt, x); ul.append(li);
  }
}

function pintarAtajos() {
  const caja = $('#atajos');
  if (caja.childElementCount) return;
  const ideas = [
    ['¿Qué tengo hoy?', true],
    ['Organízame la semana', true],
    ['Búscame 2 horas libres mañana para estudiar', true],
    ['Agéndame ', false],
    ['Anota una tarea: ', false],
  ];
  for (const [texto, directo] of ideas) {
    const b = el('button', '', texto.trim());
    b.type = 'button';
    b.addEventListener('click', () => {
      if (directo) { enviar(texto); return; }
      const e = $('#entrada'); e.value = texto; e.focus(); ajustarAltura();
    });
    caja.append(b);
  }
}

function pintarMensajes() {
  const hilo = $('#hilo');
  hilo.replaceChildren();
  const mensajes = estado.datos.mensajes || [];
  if (!mensajes.length) {
    const p = estado.datos.perfil || {};
    const s = el('div', 'saludo-inicial');
    s.append(el('h3', '', 'Hola, ' + (p.como_llamar || p.nombre || '') + '.'),
      el('p', '', 'Puedo agendar, mover y cancelar actividades, avisarte antes de que empiecen, buscarte huecos libres y recordar lo que me cuentes. Escríbeme como le escribirías a alguien de confianza.'));
    hilo.append(s);
    return;
  }
  for (const m of mensajes) agregarMensaje(m.rol, m.texto, m.hora, false);
  hilo.scrollTop = hilo.scrollHeight;
}

function agregarMensaje(rol, texto, hora, animar = true) {
  const hilo = $('#hilo');
  const saludo = hilo.querySelector('.saludo-inicial');
  if (saludo) saludo.remove();
  const m = el('div', 'msj ' + rol);
  const cuerpo = el('div', 'cuerpo');
  if (rol === 'persona') cuerpo.textContent = texto; else cuerpo.innerHTML = mdSeguro(texto);
  const ahora = new Date();
  m.append(cuerpo, el('small', '', (rol === 'persona' ? 'Tú' : 'AssistentD') + ' · ' + (hora || String(ahora.getHours()).padStart(2, '0') + ':' + String(ahora.getMinutes()).padStart(2, '0'))));
  if (!animar) m.style.animation = 'none';
  hilo.append(m);
  hilo.scrollTop = hilo.scrollHeight;
  return m;
}

/* ---------- conversar ---------- */
async function enviar(texto, oculto = false) {
  texto = (texto || '').trim();
  if (!texto || estado.ocupado) return;
  estado.ocupado = true;
  $('#b-enviar').disabled = true;
  if (!oculto) agregarMensaje('persona', texto);
  const espera = el('div', 'msj asistente escribiendo');
  const puntos = el('div', 'cuerpo'); puntos.append(el('span'), el('span'), el('span'));
  espera.append(puntos);
  $('#hilo').append(espera);
  $('#hilo').scrollTop = $('#hilo').scrollHeight;
  try {
    const r = await api('conversar', { texto });
    espera.remove();
    agregarMensaje(r.error ? 'asistente error' : 'asistente', r.respuesta || r.error || 'No obtuve respuesta.');
    if (r.hubo_cambios) await recargar(false);
    else if (estado.datos) { recargar(false).catch(() => {}); }
  } catch (e) {
    espera.remove();
    agregarMensaje('asistente error', (e.datos && (e.datos.respuesta || e.datos.error)) || 'No pude contactar al motor. Revisa tu internet e inténtalo de nuevo.');
  } finally {
    estado.ocupado = false;
    $('#b-enviar').disabled = false;
    $('#entrada').focus();
  }
}

function ajustarAltura() {
  const e = $('#entrada');
  e.style.height = 'auto';
  e.style.height = Math.min(e.scrollHeight, 160) + 'px';
}

$('#redactar').addEventListener('submit', (ev) => {
  ev.preventDefault();
  const e = $('#entrada');
  const t = e.value;
  e.value = ''; ajustarAltura();
  enviar(t);
});
$('#entrada').addEventListener('input', ajustarAltura);
$('#entrada').addEventListener('keydown', (ev) => {
  if (ev.key === 'Enter' && !ev.shiftKey) { ev.preventDefault(); $('#redactar').requestSubmit(); }
});

$('#b-nueva').addEventListener('click', async () => {
  await api('accion', { tipo: 'nueva_conversacion', datos: {} });
  await recargar(true);
});

/* ---------- resumen del dia ---------- */
async function cargarBoletin(forzar) {
  const p = $('#boletin-texto');
  if (!forzar && estado.datos.boletin) { p.textContent = estado.datos.boletin; p.classList.remove('tenue'); return; }
  p.textContent = 'Preparando tu resumen…'; p.classList.add('tenue');
  try {
    const r = await api('boletin' + (forzar ? '?forzar=1' : ''));
    p.textContent = r.texto || 'Sin resumen por ahora.';
    p.classList.toggle('tenue', !r.texto);
  } catch {
    p.textContent = 'No pude preparar el resumen ahora. Inténtalo con "Actualizar".';
  }
}
$('#b-boletin').addEventListener('click', () => cargarBoletin(true));

/* ---------- avisos ---------- */
function sonar() {
  try {
    const ctx = new (window.AudioContext || window.webkitAudioContext)();
    [0, 0.18].forEach((t, i) => {
      const o = ctx.createOscillator(); const g = ctx.createGain();
      o.frequency.value = i ? 880 : 660; o.type = 'sine';
      g.gain.setValueAtTime(0.0001, ctx.currentTime + t);
      g.gain.exponentialRampToValueAtTime(0.25, ctx.currentTime + t + 0.02);
      g.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + t + 0.3);
      o.connect(g).connect(ctx.destination); o.start(ctx.currentTime + t); o.stop(ctx.currentTime + t + 0.32);
    });
  } catch { /* sin sonido */ }
}

function mostrarAviso(a) {
  const titulo = a.tipo === 'ahora' ? 'Empieza ahora: ' + a.titulo : 'En ' + a.faltan_min + ' min: ' + a.titulo;
  const cuerpo = 'A las ' + a.hora + (a.detalle ? ' · ' + a.detalle : '');
  const caja = el('div', 'aviso' + (a.prioridad === 1 || a.tipo === 'ahora' ? ' urgente' : ''));
  const cerrar = el('button', '', 'Entendido');
  cerrar.addEventListener('click', () => caja.remove());
  caja.append(el('b', '', titulo), el('small', '', cuerpo), cerrar);
  $('#avisos').append(caja);
  setTimeout(() => caja.remove(), 60000);
  sonar();
  if ('Notification' in window && Notification.permission === 'granted' && document.hidden) {
    try { new Notification(titulo, { body: cuerpo, icon: 'marca.svg', tag: 'adx-' + a.id + a.tipo }); } catch { /* sin notificacion */ }
  }
}

async function revisarAvisos() {
  if (!estado.avisosActivos) return;
  try {
    const r = await api('avisos');
    (r.avisos || []).forEach(mostrarAviso);
    if ((r.avisos || []).length) recargar(false).catch(() => {});
  } catch { /* se reintenta luego */ }
}

/* ---------- formularios laterales ---------- */
$('#form-tarea').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const t = $('#nueva-tarea').value.trim(); if (!t) return;
  $('#nueva-tarea').value = '';
  await api('accion', { tipo: 'agregar_tarea', datos: { texto: t, prioridad: Number($('#prioridad-tarea').value) } });
  recargar(false);
});
$('#nueva-tarea').addEventListener('keydown', (ev) => { if (ev.key === 'Enter') { ev.preventDefault(); $('#form-tarea').requestSubmit(); } });

$('#form-nota').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const t = $('#nueva-nota').value.trim(); if (!t) return;
  $('#nueva-nota').value = '';
  await api('accion', { tipo: 'guardar_nota', datos: { texto: t } });
  recargar(false);
});

$('#form-recuerdo').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const t = $('#nuevo-recuerdo').value.trim(); if (t.length < 2) return;
  $('#nuevo-recuerdo').value = '';
  await api('accion', { tipo: 'recordar_dato', datos: { tema: 'general', dato: t, origen: 'manual' } });
  recargar(false);
});

$('#b-reiniciar-estilo').addEventListener('click', async (ev) => {
  const b = ev.currentTarget;
  if (b.dataset.seguro !== '1') { b.dataset.seguro = '1'; b.textContent = 'Pulsa otra vez para confirmar'; return; }
  await api('accion', { tipo: 'reiniciar_estilo', datos: {} });
  b.dataset.seguro = ''; b.textContent = 'Volver a aprender mi estilo desde cero';
  recargar(false);
});

/* ---------- navegacion ---------- */
document.querySelectorAll('.selector button').forEach((b) => b.addEventListener('click', () => {
  document.querySelectorAll('.selector button').forEach((x) => x.classList.toggle('activa', x === b));
  document.querySelectorAll('.hoja').forEach((h) => h.classList.toggle('activa', h.id === b.dataset.hoja));
}));

document.querySelectorAll('#pestanas-moviles button').forEach((b) => b.addEventListener('click', () => {
  const yaActiva = b.classList.contains('activa');
  document.querySelectorAll('#pestanas-moviles button').forEach((x) => x.classList.remove('activa'));
  document.querySelectorAll('.columna').forEach((c) => c.classList.remove('activa'));
  const ancho = window.innerWidth > 760;
  if (ancho && yaActiva) return; // en pantallas medianas el boton abre y cierra el lateral
  b.classList.add('activa');
  document.getElementById(b.dataset.col).classList.add('activa');
}));

$('#b-sem-ant').addEventListener('click', () => { estado.semana = sumarDias(estado.semana, -7); estado.dia = estado.semana; recargar(false); });
$('#b-sem-sig').addEventListener('click', () => { estado.semana = sumarDias(estado.semana, 7); estado.dia = estado.semana; recargar(false); });
$('#b-hoy').addEventListener('click', () => { estado.dia = soloFecha(new Date()); estado.semana = lunesDe(new Date()); recargar(false); });

iniciar();
