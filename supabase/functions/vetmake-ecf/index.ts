// VetMake · Facturación electrónica (e-CF) a través de un PSFE autorizado.
//
// La app nunca ve la contraseña ni la API key del proveedor: viven en Supabase
// Vault y solo esta función (service_role) las lee con ecf_servidor_contexto.
// El documento JSON lo arma la base de datos (private.ecf_documento) con la
// estructura oficial de la DGII; aquí solo se autentica, se envía y se guarda
// lo que respondió el proveedor.
//
// Proveedor soportado: eCF MSeller (https://docs.ecf.mseller.app).
//   POST {base}/{ambiente}/customer/authentication  → idToken (60 min), refreshToken (30 días)
//   POST {base}/{ambiente}/documentos-ecf           → securityCode, qr_url, signedDate (asíncrono)
//   GET  {base}/{ambiente}/documentos-ecf?ecf=...   → status
//   POST {base}/{ambiente}/documentos-ecf/status/batch {"ecfs": [...]} (máx. 100)
// Cada llamada protegida lleva Authorization: Bearer {idToken} y X-API-KEY.
//
// Acciones (POST JSON):
//   { action: "probar" }                          → valida credenciales (solo admin)
//   { action: "emitir", clase: "factura"|"nota", id } → envía el e-CF
//   { action: "consultar", clase?, id? }          → relee estado de uno o de todos los pendientes

import { createClient } from "npm:@supabase/supabase-js@2"

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? ""
const PUBLIC_KEY = Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ?? Deno.env.get("SUPABASE_ANON_KEY") ?? ""
const SERVER_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SECRET_KEY") ?? ""
const MSELLER_BASE = Deno.env.get("VETMAKE_MSELLER_BASE") ?? "https://ecf.api.mseller.app"

const db = createClient(SUPABASE_URL, SERVER_KEY, { auth: { autoRefreshToken: false, persistSession: false } })

type Clase = "factura" | "nota"
type Contexto = {
  ok: boolean
  mensaje?: string
  negocio_id: string
  rol: string
  puede_escribir: boolean
  activo: boolean
  proveedor: string
  ambiente: "TesteCF" | "CerteCF" | "eCF"
  email: string | null
  password: string | null
  api_key: string | null
  id_token: string | null
  refresh_token: string | null
  token_sub: string | null
  token_expira: string | null
}

class HttpError extends Error {
  constructor(public status: number, message: string) { super(message) }
}

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
}
const reply = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: cors })
const esperar = (ms: number) => new Promise((r) => setTimeout(r, ms))

async function usuarioDeLaPeticion(req: Request): Promise<string> {
  const auth = req.headers.get("Authorization") ?? ""
  if (!/^Bearer\s+\S+$/i.test(auth)) throw new HttpError(401, "Se requiere una sesión autenticada.")
  const cliente = createClient(SUPABASE_URL, PUBLIC_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: auth } },
  })
  const { data, error } = await cliente.auth.getUser()
  if (error || !data.user) throw new HttpError(401, "La sesión ya no es válida.")
  return data.user.id
}

async function rpc<T>(nombre: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await db.rpc(nombre, args)
  if (error) throw new HttpError(400, error.message || "Error en la base de datos.")
  return data as T
}

function subDelToken(idToken: string): string | null {
  try {
    const b64 = idToken.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")
    const relleno = b64 + "=".repeat((4 - (b64.length % 4)) % 4)
    return JSON.parse(atob(relleno)).sub ?? null
  } catch {
    return null
  }
}

function mensajeDe(cuerpo: unknown, status: number): string {
  if (cuerpo && typeof cuerpo === "object") {
    const c = cuerpo as Record<string, unknown>
    const m = c.message ?? c.mensaje ?? c.error ?? c.errors ?? c.detail
    if (typeof m === "string" && m.trim()) return m
    if (m) return JSON.stringify(m).slice(0, 500)
  }
  if (typeof cuerpo === "string" && cuerpo.trim()) return cuerpo.slice(0, 500)
  return `El proveedor respondió ${status}.`
}

async function llamar(url: string, init: RequestInit): Promise<{ status: number; cuerpo: unknown }> {
  const control = new AbortController()
  const reloj = setTimeout(() => control.abort(), 25000)
  try {
    const res = await fetch(url, { ...init, signal: control.signal })
    const texto = await res.text()
    let cuerpo: unknown = texto
    try { cuerpo = texto ? JSON.parse(texto) : {} } catch { /* texto plano */ }
    return { status: res.status, cuerpo }
  } catch (e) {
    const abortado = e instanceof DOMException && e.name === "AbortError"
    throw new HttpError(504, abortado ? "El proveedor de facturación electrónica no respondió a tiempo." : "No se pudo conectar con el proveedor de facturación electrónica.")
  } finally {
    clearTimeout(reloj)
  }
}

// ─── Token del proveedor (se reutiliza ~55 min; se renueva con refreshToken) ──
async function tokenDelProveedor(ctx: Contexto, forzarLogin = false, marcarPrueba = false): Promise<string> {
  const base = `${MSELLER_BASE}/${ctx.ambiente}`
  const vigente = ctx.id_token && ctx.token_expira && new Date(ctx.token_expira).getTime() > Date.now() + 120000
  if (!forzarLogin && vigente) return ctx.id_token as string

  if (!forzarLogin && ctx.refresh_token && ctx.token_sub) {
    const r = await llamar(`${base}/customer/authentication`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ refreshToken: ctx.refresh_token, username: ctx.token_sub }),
    })
    const c = r.cuerpo as Record<string, string>
    if (r.status < 300 && c?.idToken) {
      await guardarToken(ctx, c.idToken, null, marcarPrueba)
      return c.idToken
    }
  }

  if (!ctx.email || !ctx.password) throw new HttpError(400, "Faltan el correo o la contraseña del proveedor en Configuración → Facturación electrónica.")
  const r = await llamar(`${base}/customer/authentication`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: ctx.email, password: ctx.password }),
  })
  const c = r.cuerpo as Record<string, string>
  if (r.status >= 300 || !c?.idToken) {
    if (marcarPrueba) await rpc("ecf_servidor_guardar_token", { p_negocio: ctx.negocio_id, p_id_token: null, p_refresh_token: null, p_sub: null, p_expira: null, p_prueba_ok: false })
    throw new HttpError(400, `El proveedor no aceptó el correo o la contraseña: ${mensajeDe(r.cuerpo, r.status)}`)
  }
  await guardarToken(ctx, c.idToken, c.refreshToken ?? null, marcarPrueba)
  return c.idToken
}

async function guardarToken(ctx: Contexto, idToken: string, refresh: string | null, marcarPrueba: boolean) {
  const expira = new Date(Date.now() + 55 * 60 * 1000).toISOString()
  await rpc("ecf_servidor_guardar_token", {
    p_negocio: ctx.negocio_id,
    p_id_token: idToken,
    p_refresh_token: refresh,
    p_sub: subDelToken(idToken),
    p_expira: expira,
    p_prueba_ok: marcarPrueba ? true : null,
  })
  ctx.id_token = idToken
  ctx.token_expira = expira
}

async function llamarProtegido(ctx: Contexto, ruta: string, init: RequestInit) {
  if (!ctx.api_key) throw new HttpError(400, "Falta la API key del proveedor en Configuración → Facturación electrónica.")
  const hacer = (token: string) => llamar(`${MSELLER_BASE}/${ctx.ambiente}${ruta}`, {
    ...init,
    headers: { ...(init.headers ?? {}), Authorization: `Bearer ${token}`, "X-API-KEY": ctx.api_key as string },
  })
  let r = await hacer(await tokenDelProveedor(ctx))
  if (r.status === 401) r = await hacer(await tokenDelProveedor(ctx, true))
  if (r.status === 403) throw new HttpError(400, `El proveedor rechazó la API key: ${mensajeDe(r.cuerpo, r.status)}`)
  return r
}

// Mensajes de la DGII (vienen como cadenas JSON dentro de dgiiResponse) y
// estados del proveedor que no son de la DGII.
function normalizarResultado(c: Record<string, unknown>): Record<string, unknown> {
  const mensajes: string[] = []
  const respuestas = Array.isArray(c.dgiiResponse) ? c.dgiiResponse : []
  for (const r of respuestas) {
    try {
      const j = typeof r === "string" ? JSON.parse(r) : r
      for (const m of (Array.isArray(j?.mensajes) ? j.mensajes : [])) {
        const v = String(m?.valor ?? "").trim()
        if (v) mensajes.push(m?.codigo ? `${m.codigo}: ${v}` : v)
      }
    } catch { /* respuesta no JSON */ }
  }
  const estado = String(c.status ?? "").toLowerCase()
  // «Error»: el proveedor no pudo entregarlo a la DGII después de reintentar.
  // Queda «por enviar» para reintentar o pasar al Facturador Gratuito.
  if (estado === "error") {
    const { status: _s, ...resto } = c
    return { ...resto, error: mensajes.join(" · ") || "El proveedor no pudo entregarlo a la DGII. Reintenta el envío." }
  }
  return mensajes.length ? { ...c, mensaje: mensajes.join(" · ") } : c
}

// ─── Acciones ────────────────────────────────────────────────────────────────
async function consultarUno(ctx: Contexto, clase: Clase, id: string, encf: string) {
  const r = await llamarProtegido(ctx, `/documentos-ecf?ecf=${encodeURIComponent(encf)}`, { method: "GET" })
  if (r.status >= 300) return null
  const c = (Array.isArray(r.cuerpo) ? r.cuerpo[0] : r.cuerpo) as Record<string, unknown>
  if (!c || !c.status) return null
  return await rpc("ecf_servidor_resultado", { p_negocio: ctx.negocio_id, p_clase: clase, p_id: id, p_resultado: normalizarResultado(c) })
}

async function emitir(ctx: Contexto, clase: Clase, id: string) {
  if (!ctx.activo) throw new HttpError(400, "La facturación electrónica no está activa para esta clínica.")
  if (!ctx.puede_escribir) throw new HttpError(402, "La membresía de VetMake está vencida: no se pueden emitir comprobantes.")
  if (clase === "nota" && ctx.rol !== "admin") throw new HttpError(403, "Solo el administrador emite notas de crédito.")
  if (!["admin", "caja", "veterinario"].includes(ctx.rol)) throw new HttpError(403, "Tu rol no emite comprobantes.")

  const tabla = clase === "nota" ? "pc_notas_credito" : "pc_facturas"
  const { data: fila, error } = await db.from(tabla).select("id, ncf, ecf_estado").eq("negocio_id", ctx.negocio_id).eq("id", id).maybeSingle()
  if (error || !fila) throw new HttpError(404, "El comprobante no existe en esta clínica.")
  if (!String(fila.ncf ?? "").startsWith("E")) throw new HttpError(400, "Primero hay que asignarle un e-NCF.")

  // Ya enviado: no se reenvía (el proveedor reintenta solo). Se relee el estado.
  if (["en_proceso", "aceptado", "aceptado_condicional"].includes(fila.ecf_estado)) {
    return (await consultarUno(ctx, clase, id, fila.ncf)) ?? fila
  }

  const documento = await rpc<Record<string, unknown>>("ecf_servidor_documento", { p_negocio: ctx.negocio_id, p_clase: clase, p_id: id })
  const r = await llamarProtegido(ctx, "/documentos-ecf", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(documento),
  })
  if (r.status >= 300) {
    const mensaje = mensajeDe(r.cuerpo, r.status)
    // Si el proveedor ya lo tenía (reintento tras un corte), se consulta.
    if (/exist|duplicad/i.test(mensaje)) {
      const consultado = await consultarUno(ctx, clase, id, fila.ncf)
      if (consultado) return consultado
    }
    await rpc("ecf_servidor_resultado", { p_negocio: ctx.negocio_id, p_clase: clase, p_id: id, p_resultado: { error: mensaje, envio: true } })
    throw new HttpError(400, `El proveedor no recibió el comprobante: ${mensaje}`)
  }
  let resultado = await rpc("ecf_servidor_resultado", {
    p_negocio: ctx.negocio_id, p_clase: clase, p_id: id,
    p_resultado: { ...(r.cuerpo as Record<string, unknown>), envio: true },
  })
  // La DGII responde en segundos: una consulta rápida ahorra un clic.
  await esperar(4000)
  resultado = (await consultarUno(ctx, clase, id, fila.ncf)) ?? resultado
  return resultado
}

async function consultarPendientes(ctx: Contexto) {
  const pendientes = await rpc<Array<{ clase: Clase; id: string; ncf: string }>>("ecf_servidor_pendientes", { p_negocio: ctx.negocio_id })
  if (!pendientes.length) return { actualizados: 0 }
  const r = await llamarProtegido(ctx, "/documentos-ecf/status/batch", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ecfs: pendientes.map((p) => p.ncf) }),
  })
  if (r.status >= 300) throw new HttpError(400, `No se pudo consultar el estado: ${mensajeDe(r.cuerpo, r.status)}`)
  const resultados = ((r.cuerpo as Record<string, unknown>)?.results ?? []) as Array<Record<string, unknown>>
  let actualizados = 0
  for (const res of resultados) {
    if (!res.found) continue
    const p = pendientes.find((x) => x.ncf === res.ecf)
    if (!p) continue
    await rpc("ecf_servidor_resultado", {
      p_negocio: ctx.negocio_id, p_clase: p.clase, p_id: p.id,
      p_resultado: normalizarResultado({ ...((res.data as Record<string, unknown>) ?? {}), status: res.status }),
    })
    actualizados++
  }
  return { actualizados }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors })
  if (req.method !== "POST") return reply({ error: "Método no permitido." }, 405)
  try {
    if (!SUPABASE_URL || !SERVER_KEY || !PUBLIC_KEY) throw new HttpError(500, "La función no está configurada.")
    const usuario = await usuarioDeLaPeticion(req)
    const body = await req.json().catch(() => ({})) as Record<string, unknown>
    const ctx = await rpc<Contexto>("ecf_servidor_contexto", { p_usuario: usuario })
    if (!ctx?.ok) throw new HttpError(403, ctx?.mensaje ?? "No autorizado.")
    if (ctx.proveedor !== "mseller") throw new HttpError(400, "Proveedor de facturación electrónica no soportado.")

    const clase: Clase = body.clase === "nota" ? "nota" : "factura"
    const id = String(body.id ?? "").trim()

    switch (body.action) {
      case "probar": {
        if (ctx.rol !== "admin") throw new HttpError(403, "Solo el administrador prueba la conexión.")
        await tokenDelProveedor(ctx, true, true)
        return reply({ ok: true, mensaje: `Conexión correcta con el proveedor (${ctx.ambiente}).` })
      }
      case "emitir": {
        if (!id) throw new HttpError(400, "Falta el comprobante.")
        return reply({ ok: true, fila: await emitir(ctx, clase, id) })
      }
      case "consultar": {
        if (id) {
          const { data: fila } = await db.from(clase === "nota" ? "pc_notas_credito" : "pc_facturas")
            .select("id, ncf").eq("negocio_id", ctx.negocio_id).eq("id", id).maybeSingle()
          if (!fila?.ncf) throw new HttpError(404, "El comprobante no existe en esta clínica.")
          return reply({ ok: true, fila: await consultarUno(ctx, clase, id, fila.ncf) })
        }
        return reply({ ok: true, ...(await consultarPendientes(ctx)) })
      }
      default:
        throw new HttpError(400, "Acción no reconocida.")
    }
  } catch (e) {
    if (e instanceof HttpError) return reply({ error: e.message }, e.status)
    console.error("[vetmake-ecf]", e)
    return reply({ error: "No se pudo completar la operación de facturación electrónica." }, 500)
  }
})
