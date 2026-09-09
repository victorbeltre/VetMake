-- VetMake · Fase 1: fundación multi-tenant
--
-- Introduce el concepto de "negocio" (una clínica cliente de VetMake) y la
-- membresía de cada usuario a su negocio. Toda tabla de datos existente
-- (pc_clientes, pc_ventas, pc_facturas, ...) se conecta a esto agregando
-- una columna negocio_id — ver 0002 para el patrón completo aplicado a
-- pc_clientes como ejemplo trabajado.
--
-- Esta migración es la fundación de VetMake. En vetmake-dev ya fue aplicada;
-- si se repite desde cero, debe conservar las mismas garantías de seguridad
-- que las migraciones posteriores.

-- ─── NEGOCIOS ────────────────────────────────────────────────────────────
create table negocios (
  id             uuid primary key default gen_random_uuid(),
  nombre         text not null,
  slug           text not null unique,
  plan           text not null default 'base',
  moneda         text not null default 'DOP',
  zona_horaria   text not null default 'America/Santo_Domingo',
  color_primario text,
  logo_url       text,
  activo         boolean not null default true,
  creado_en      timestamptz not null default now()
);

comment on table negocios is
  'Una fila por clínica cliente de VetMake. Alta manual por el equipo de '
  'VetMake al incorporar un cliente nuevo (ver checklist de onboarding en '
  'docs/saas/PLAN.md, sección 7) — no hay autoservicio en el MVP.';

alter table negocios enable row level security;

-- ─── MEMBRESÍA: qué usuario pertenece a qué negocio ─────────────────────
create table usuarios_negocio (
  usuario_id uuid not null references auth.users(id) on delete cascade,
  negocio_id uuid not null references negocios(id) on delete cascade,
  rol        text not null check (rol in ('admin', 'veterinario', 'groomer', 'caja')),
  primary key (usuario_id, negocio_id)
);

comment on table usuarios_negocio is
  'Mapea cada usuario de Supabase Auth a su negocio y rol. Un usuario '
  'pertenece a un solo negocio en el MVP — no se diseña para usuarios '
  'compartidos entre clínicas todavía (no hay caso de uso real para eso '
  'hoy; se agrega si aparece).';

alter table usuarios_negocio enable row level security;

-- ─── HELPER: negocio del usuario autenticado ─────────────────────────────
create function mi_negocio()
returns uuid
language sql
stable
security invoker
set search_path = public
as $$
  select negocio_id from usuarios_negocio where usuario_id = auth.uid() limit 1;
$$;

comment on function mi_negocio() is
  'Resuelve el negocio_id del usuario autenticado actual. Es el corazón '
  'de cada política RLS multi-tenant: reemplaza el "using (true)" de '
  'PetColinas por "using (negocio_id = (select mi_negocio()))". Es '
  'SECURITY INVOKER: la lectura de usuarios_negocio queda protegida por '
  'su propia política RLS y la función no se expone como un endpoint '
  'anónimo.';

-- La función solo la necesitan usuarios autenticados y el backend confiable.
-- Revocar PUBLIC evita que anon pueda invocarla como /rpc/mi_negocio.
revoke execute on function mi_negocio() from public;
grant execute on function mi_negocio() to authenticated, service_role;

-- Las políticas y la función consultan negocio_id por esta columna.
create index usuarios_negocio_negocio_id_idx on usuarios_negocio (negocio_id);

-- ─── POLÍTICAS: negocios ──────────────────────────────────────────────────
-- Un usuario ve su propio negocio y nada más. Sin política de INSERT/
-- UPDATE/DELETE para authenticated a propósito: el alta y edición de
-- negocios la hace el equipo de VetMake vía service_role (bypassa RLS),
-- nunca desde la app — igual que el resto del onboarding manual.
create policy "negocio_propio_select"
  on negocios
  for select
  to authenticated
  using (id = mi_negocio());

-- ─── POLÍTICAS: usuarios_negocio ──────────────────────────────────────────
-- Un usuario ve su propia fila de membresía (útil para que la app sepa su
-- rol). Igual que arriba: alta/edición solo por service_role.
create policy "membresia_propia_select"
  on usuarios_negocio
  for select
  to authenticated
  using (usuario_id = (select auth.uid()));
