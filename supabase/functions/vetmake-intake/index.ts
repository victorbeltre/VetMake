import { createClient } from "npm:@supabase/supabase-js@2"

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? ""
const SERVER_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SECRET_KEY") ?? ""
const db = createClient(SUPABASE_URL, SERVER_KEY, { auth: { autoRefreshToken: false, persistSession: false } })

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
}
const reply = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: cors })
const clean = (value: unknown, max = 250) => String(value ?? "").trim().replace(/[<>]/g, "").slice(0, max)

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors })
  if (req.method !== "POST") return reply({ error: "Método no permitido." }, 405)

  try {
    const body = await req.json().catch(() => ({}))
    const token = clean(body.token, 50)
    if (!/^[0-9a-f-]{36}$/i.test(token)) return reply({ error: "El enlace de inscripción no es válido." }, 404)

    const { data: negocio, error: negocioError } = await db
      .from("negocios")
      .select("id,nombre,tagline,logo_url,color_primario,formulario_activo,activo")
      .eq("formulario_token", token)
      .maybeSingle()
    if (negocioError) throw negocioError
    if (!negocio || negocio.activo === false || negocio.formulario_activo === false) {
      return reply({ error: "Este formulario no está disponible." }, 404)
    }

    if (body.action === "config") {
      return reply({ negocio: {
        nombre: negocio.nombre,
        tagline: negocio.tagline || "Gestión veterinaria con VetMake",
        logoUrl: negocio.logo_url || "",
        color: negocio.color_primario || "#1a6b3a",
      } })
    }
    if (body.action !== "submit") return reply({ error: "Acción no válida." }, 400)
    if (clean(body.website, 100)) return reply({ ok: true }) // honeypot

    const propietario = clean(body.propietario, 120)
    const telefono = clean(body.telefono, 35)
    const mascota = clean(body.mascota, 100)
    const especie = clean(body.especie, 30)
    if (!propietario || !telefono || !mascota || !especie) {
      return reply({ error: "Completa nombre, teléfono, mascota y especie." }, 422)
    }

    // Evita reenvíos accidentales del mismo formulario durante cinco minutos.
    const desde = new Date(Date.now() - 5 * 60_000).toISOString()
    const { data: repetidos } = await db.from("pc_clientes").select("id")
      .eq("negocio_id", negocio.id).eq("telefono", telefono).eq("nombremascota", mascota)
      .gte("created_at", desde).limit(1)
    if (repetidos?.length) return reply({ ok: true, duplicate: true })

    const canal = clean(body.canal, 80) || "Formulario web"
    const servicio = clean(body.servicio, 120) || "Por definir"
    const notasExtra = clean(body.notas, 700)
    const id = `${Date.now()}${Math.floor(Math.random() * 900 + 100)}`
    const fila = {
      id,
      negocio_id: negocio.id,
      nombremascota: mascota,
      especie,
      raza: clean(body.raza, 80),
      sexo: clean(body.sexo, 20),
      fechanacimiento: clean(body.fechaNacimiento, 10) || null,
      color: clean(body.color, 60),
      tamano: clean(body.tamano, 50),
      esterilizado: body.esterilizado === true,
      nombrepropietario: propietario,
      telefono,
      email: clean(body.email, 160).toLowerCase(),
      direccion: clean(body.direccion, 250),
      alergias: clean(body.alergias, 350),
      medicamentos: clean(body.medicamentos, 350),
      condiciones: clean(body.condiciones, 500),
      alertamedica: clean(body.alertaMedica, 350),
      notas: `Nos conocio por: ${canal} | Servicio: ${servicio} | Formulario web VetMake${notasExtra ? ` | ${notasExtra}` : ""}`,
      fecharegistro: new Date().toISOString().slice(0, 10),
    }
    const { error: insertError } = await db.from("pc_clientes").insert(fila)
    if (insertError) throw insertError
    return reply({ ok: true, id })
  } catch (error) {
    console.error("vetmake-intake", error)
    return reply({ error: "No pudimos enviar la inscripción. Inténtalo nuevamente." }, 500)
  }
})
