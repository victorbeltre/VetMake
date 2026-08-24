import { createClient } from "npm:@supabase/supabase-js@2"

type Role = "admin" | "veterinario" | "groomer" | "caja"

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? ""
const PUBLIC_KEY =
  Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ??
  Deno.env.get("SUPABASE_ANON_KEY") ??
  ""
const SERVER_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
  Deno.env.get("SUPABASE_SECRET_KEY") ??
  ""
const SITE_URL = Deno.env.get("VETMAKE_SITE_URL") ?? ""
const VALID_ROLES = new Set<Role>(["admin", "veterinario", "groomer", "caja"])

const adminClient = createClient(SUPABASE_URL, SERVER_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
})

class HttpError extends Error {
  status: number
  code: string

  constructor(status: number, code: string, message: string) {
    super(message)
    this.status = status
    this.code = code
  }
}

function headers() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Content-Type": "application/json; charset=utf-8",
  }
}

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: headers() })
}

function normalizeEmail(value: unknown) {
  return String(value ?? "").trim().toLowerCase()
}

function normalizeRole(value: unknown): Role | null {
  const role = String(value ?? "").trim() as Role
  return VALID_ROLES.has(role) ? role : null
}

function requireBearer(req: Request) {
  const value = req.headers.get("Authorization") ?? ""
  if (!/^Bearer\s+\S+$/i.test(value)) {
    throw new HttpError(401, "missing_authorization", "Se requiere una sesión autenticada.")
  }
  return value
}

async function getCaller(req: Request) {
  if (!SUPABASE_URL || !PUBLIC_KEY || !SERVER_KEY) {
    throw new HttpError(500, "function_configuration", "La función no está configurada correctamente.")
  }

  const authorization = requireBearer(req)
  const callerClient = createClient(SUPABASE_URL, PUBLIC_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: authorization } },
  })
  const { data, error } = await callerClient.auth.getUser()
  if (error || !data.user) {
    throw new HttpError(401, "invalid_session", "La sesión ya no es válida.")
  }
  return data.user
}

async function findAuthUserByEmail(email: string) {
  // El MVP permite un usuario por negocio. El recorrido paginado evita
  // depender de una consulta directa a auth.users desde el Data API.
  for (let page = 1; page <= 20; page += 1) {
    const { data, error } = await adminClient.auth.admin.listUsers({ page, perPage: 1000 })
    if (error) throw new HttpError(502, "auth_lookup_failed", "No se pudo comprobar el correo en Auth.")
    const users = data?.users ?? []
    const found = users.find((user) => normalizeEmail(user.email) === email)
    if (found) return found
    if (users.length < 1000) return null
  }
  throw new HttpError(503, "auth_lookup_limit", "Hay demasiados usuarios para completar la vinculación automáticamente.")
}

async function linkEmployee(req: Request, body: Record<string, unknown>) {
  const caller = await getCaller(req)
  const employeeId = String(body.employee_id ?? "").trim()
  const email = normalizeEmail(body.email)
  if (!employeeId) throw new HttpError(400, "employee_required", "Falta el empleado que se va a vincular.")
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    throw new HttpError(400, "email_invalid", "Escribe un correo válido para el acceso.")
  }

  const { data: membership, error: membershipError } = await adminClient
    .from("usuarios_negocio")
    .select("negocio_id, rol")
    .eq("usuario_id", caller.id)
    .limit(1)
    .maybeSingle()
  if (membershipError) throw new HttpError(502, "membership_lookup_failed", "No se pudo comprobar la membresía.")
  if (!membership || membership.rol !== "admin") {
    throw new HttpError(403, "admin_required", "Solo un administrador puede invitar personal.")
  }

  const { data: employee, error: employeeError } = await adminClient
    .from("pc_empleados")
    .select("id, negocio_id, nombre, email, usuario_id, rol, activo")
    .eq("id", employeeId)
    .eq("negocio_id", membership.negocio_id)
    .maybeSingle()
  if (employeeError) throw new HttpError(502, "employee_lookup_failed", "No se pudo leer el empleado.")
  if (!employee) throw new HttpError(404, "employee_not_found", "El empleado no pertenece a este negocio.")
  if (employee.activo === false) throw new HttpError(400, "employee_inactive", "Activa el empleado antes de darle acceso.")

  const role = normalizeRole(body.rol ?? employee.rol)
  if (!role) throw new HttpError(400, "role_required", "Selecciona un rol antes de enviar la invitación.")

  const authUser = await findAuthUserByEmail(email)
  let user = authUser
  let invited = false

  if (!user) {
    const inviteOptions: { data: Record<string, string>; redirectTo?: string } = {
      // Solo sirve para mostrar el nombre en la aplicación; nunca se usa
      // para autorizar. El rol queda en tablas protegidas del negocio.
      data: { full_name: String(employee.nombre || email).trim() },
    }
    if (SITE_URL) inviteOptions.redirectTo = SITE_URL
    const { data, error } = await adminClient.auth.admin.inviteUserByEmail(email, inviteOptions)
    if (error || !data.user) {
      throw new HttpError(502, "invite_failed", "Supabase no pudo enviar la invitación.")
    }
    user = data.user
    invited = true
  }

  if (employee.usuario_id && employee.usuario_id !== user.id) {
    throw new HttpError(409, "employee_already_linked", "Este empleado ya está vinculado a otro usuario.")
  }

  const { data: linkedRows, error: linkedRowsError } = await adminClient
    .from("pc_empleados")
    .select("id, nombre")
    .eq("negocio_id", membership.negocio_id)
    .eq("usuario_id", user.id)
    .neq("id", employee.id)
    .limit(1)
  if (linkedRowsError) throw new HttpError(502, "employee_link_lookup_failed", "No se pudo comprobar el equipo vinculado.")
  if (linkedRows?.length) {
    throw new HttpError(409, "user_already_linked", "Ese usuario ya está vinculado a otro empleado de esta clínica.")
  }

  const { data: userMemberships, error: userMembershipsError } = await adminClient
    .from("usuarios_negocio")
    .select("negocio_id, rol")
    .eq("usuario_id", user.id)
  if (userMembershipsError) throw new HttpError(502, "user_membership_lookup_failed", "No se pudo comprobar el acceso existente.")
  const otherBusiness = (userMemberships ?? []).find((row) => row.negocio_id !== membership.negocio_id)
  if (otherBusiness) {
    throw new HttpError(409, "user_belongs_to_other_business", "Ese usuario ya pertenece a otra clínica de VetMake.")
  }

  let membershipCreated = false
  if ((userMemberships ?? []).some((row) => row.negocio_id === membership.negocio_id)) {
    const { error } = await adminClient
      .from("usuarios_negocio")
      .update({ rol: role })
      .eq("usuario_id", user.id)
      .eq("negocio_id", membership.negocio_id)
    if (error) throw new HttpError(502, "membership_update_failed", "No se pudo actualizar el rol del usuario.")
  } else {
    const { error } = await adminClient.from("usuarios_negocio").insert({
      usuario_id: user.id,
      negocio_id: membership.negocio_id,
      rol: role,
    })
    if (error) throw new HttpError(502, "membership_insert_failed", "No se pudo crear la membresía del usuario.")
    membershipCreated = true
  }

  const { data: updatedEmployee, error: employeeUpdateError } = await adminClient
    .from("pc_empleados")
    .update({ usuario_id: user.id, email, rol: role })
    .eq("id", employee.id)
    .eq("negocio_id", membership.negocio_id)
    .select("id, nombre, email, usuario_id, rol, activo")
    .single()
  if (employeeUpdateError || !updatedEmployee) {
    if (membershipCreated) {
      await adminClient.from("usuarios_negocio").delete().eq("usuario_id", user.id).eq("negocio_id", membership.negocio_id)
    }
    if (invited) await adminClient.auth.admin.deleteUser(user.id)
    throw new HttpError(502, "employee_update_failed", "No se pudo terminar la vinculación del empleado.")
  }

  return {
    ok: true,
    invited,
    user_id: user.id,
    employee: updatedEmployee,
    message: invited ? "Invitación enviada y empleado vinculado." : "Empleado vinculado al usuario existente.",
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: headers() })
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405)

  try {
    const body = await req.json() as Record<string, unknown>
    if (body.action !== "link_employee") {
      throw new HttpError(400, "action_invalid", "Acción de onboarding no reconocida.")
    }
    return json(await linkEmployee(req, body))
  } catch (error) {
    if (error instanceof HttpError) {
      return json({ error: error.code, message: error.message }, error.status)
    }
    console.error("[vetmake-admin]", error)
    return json({ error: "internal_error", message: "No se pudo completar el onboarding." }, 500)
  }
})
