-- VetMake · Fase 1: patrón multi-tenant para las tablas operativas restantes
--
-- Requiere que 0001_negocios_y_membresia.sql ya se haya aplicado y que las
-- seis tablas existan con la estructura de PetColinas. Este archivo no crea
-- tablas desde cero: agrega únicamente la frontera de negocio_id y reemplaza
-- las políticas de un solo negocio.
--
-- En el código actual, la tabla que representa nómina es pc_empleados. El
-- prompt inicial la llamaba pc_nomina; no se inventa una tabla nueva para
-- resolver esa diferencia.
--
-- Igual que 0002, la migración está pensada para el proyecto VetMake vacío.
-- Si se aplica sobre tablas con datos, hay que hacer el backfill de negocio_id
-- antes de ejecutar el ALTER COLUMN ... SET NOT NULL.

-- ─── 0. Completar la estructura operativa de VetMake ─────────────────────
-- El baseline inicial de vetmake-dev solo creó pc_clientes. Estas tablas se
-- crean vacías con la estructura observada en PetColinas; no se copian datos
-- reales ni se toca el proyecto de producción.
create table if not exists public.pc_ventas (
  id                text primary key,
  fecha             text,
  cliente           text,
  area              text,
  servicio          text,
  total             numeric,
  comision          numeric,
  formapago         text,
  recibidopor       text,
  notas             text,
  created_at        timestamptz default now(),
  descripcion       text,
  items             jsonb default '[]'::jsonb,
  cobradopor        text,
  descuento         numeric default 0,
  banco             text,
  abonos            jsonb default '[]'::jsonb,
  abonado           numeric default 0,
  fecharecordatorio text
);

create table if not exists public.pc_facturas (
  id          text primary key,
  numero      text,
  fecha       text,
  mascota     text,
  propietario  text,
  telefono    text,
  items       text,
  metodopago  text,
  estado      text,
  itbis       boolean,
  subtotal    numeric,
  itbisamt    numeric,
  total       numeric,
  notas       text,
  clienteid   text,
  autogenerada boolean
);

create table if not exists public.pc_inventario (
  id           text primary key,
  nombre       text,
  categoria    text,
  stock        numeric default 0,
  stockmin     numeric default 0,
  preciocompra numeric default 0,
  precioventa  numeric default 0,
  proveedor    text,
  notas        text,
  created_at   timestamptz default now(),
  stockinicial numeric,
  fechaentrada text
);

create table if not exists public.pc_empleados (
  id          text primary key,
  nombre      text,
  cargo       text,
  mensualidad numeric default 0,
  created_at  timestamptz default now()
);

create table if not exists public.pc_gastos (
  id          text primary key,
  fecha       text,
  categoria   text,
  descripcion text,
  monto       numeric,
  formapago   text,
  proveedor   text,
  notas       text,
  created_at  timestamptz default now()
);

create table if not exists public.pc_citas (
  id                 bigint primary key,
  fecha              text,
  hora               text,
  duracion           integer,
  tipo               text,
  empleado           text,
  estado             text,
  clienteid          bigint,
  nombrecliente      text,
  nombremascota      text,
  telefono           text,
  servicio           text,
  precio             numeric,
  notas              text,
  motivocancelacion  text,
  enespera           boolean,
  mensajesenviados   text,
  gcaleventid        text,
  gcalsync           timestamptz,
  actualizado        timestamptz default now()
);

alter table public.pc_ventas enable row level security;
alter table public.pc_facturas enable row level security;
alter table public.pc_inventario enable row level security;
alter table public.pc_empleados enable row level security;
alter table public.pc_gastos enable row level security;
alter table public.pc_citas enable row level security;

-- Desde mayo de 2026 las tablas nuevas no deben depender de la exposición
-- implícita del Data API. El MVP solo permite el acceso de la app autenticada.
grant select, insert, update, delete on table
  public.pc_ventas, public.pc_facturas, public.pc_inventario,
  public.pc_empleados, public.pc_gastos, public.pc_citas
  to authenticated;

-- ─── 0.1. Endurecer la fundación aplicada por 0001/0002 ──────────────────
-- mi_negocio() no necesita privilegios elevados: usuarios_negocio ya permite
-- que cada usuario autenticado lea únicamente su propia membresía.
alter function public.mi_negocio() security invoker;
alter function public.mi_negocio() set search_path = public;
revoke execute on function public.mi_negocio() from public;
grant execute on function public.mi_negocio() to authenticated, service_role;

create index if not exists usuarios_negocio_negocio_id_idx
  on public.usuarios_negocio (negocio_id);

drop policy if exists "membresia_propia_select" on public.usuarios_negocio;
create policy "membresia_propia_select"
  on public.usuarios_negocio
  for select
  to authenticated
  using (usuario_id = (select auth.uid()));

drop policy if exists "negocio_propio_select" on public.negocios;
create policy "negocio_propio_select"
  on public.negocios
  for select
  to authenticated
  using (id = (select mi_negocio()));

-- Reescribir también pc_clientes para usar el mismo initplan eficiente que
-- las tablas nuevas. Las políticas conservan exactamente el mismo modelo.
drop policy if exists "negocio_lee_su_clientes" on public.pc_clientes;
drop policy if exists "negocio_escribe_su_clientes" on public.pc_clientes;
drop policy if exists "negocio_actualiza_su_clientes" on public.pc_clientes;
drop policy if exists "negocio_borra_su_clientes" on public.pc_clientes;

create policy "negocio_lee_su_clientes"
  on public.pc_clientes
  for select
  to authenticated
  using (negocio_id = (select mi_negocio()));

create policy "negocio_escribe_su_clientes"
  on public.pc_clientes
  for insert
  to authenticated
  with check (negocio_id = (select mi_negocio()));

create policy "negocio_actualiza_su_clientes"
  on public.pc_clientes
  for update
  to authenticated
  using (negocio_id = (select mi_negocio()))
  with check (negocio_id = (select mi_negocio()));

create policy "negocio_borra_su_clientes"
  on public.pc_clientes
  for delete
  to authenticated
  using (negocio_id = (select mi_negocio()));

-- ─── pc_ventas ────────────────────────────────────────────────────────────
alter table pc_ventas
  add column negocio_id uuid references negocios(id);

alter table pc_ventas
  alter column negocio_id set not null;

create index if not exists pc_ventas_negocio_id_idx on pc_ventas (negocio_id);

drop policy if exists "pc_auth_all" on pc_ventas;
drop policy if exists "pc_ventas all" on pc_ventas;
drop policy if exists "pc_ventas delete" on pc_ventas;

create policy "negocio_lee_sus_ventas"
  on pc_ventas
  for select
  to authenticated
  using (negocio_id = (select mi_negocio()));

create policy "negocio_escribe_sus_ventas"
  on pc_ventas
  for insert
  to authenticated
  with check (negocio_id = (select mi_negocio()));

create policy "negocio_actualiza_sus_ventas"
  on pc_ventas
  for update
  to authenticated
  using (negocio_id = (select mi_negocio()))
  with check (negocio_id = (select mi_negocio()));

create policy "negocio_borra_sus_ventas"
  on pc_ventas
  for delete
  to authenticated
  using (negocio_id = (select mi_negocio()));

-- ─── pc_facturas ──────────────────────────────────────────────────────────
alter table pc_facturas
  add column negocio_id uuid references negocios(id);

alter table pc_facturas
  alter column negocio_id set not null;

create index if not exists pc_facturas_negocio_id_idx on pc_facturas (negocio_id);

drop policy if exists "pc_auth_all" on pc_facturas;
drop policy if exists "pc_facturas all" on pc_facturas;
drop policy if exists "pc_facturas delete" on pc_facturas;

create policy "negocio_lee_sus_facturas"
  on pc_facturas
  for select
  to authenticated
  using (negocio_id = (select mi_negocio()));

create policy "negocio_escribe_sus_facturas"
  on pc_facturas
  for insert
  to authenticated
  with check (negocio_id = (select mi_negocio()));

create policy "negocio_actualiza_sus_facturas"
  on pc_facturas
  for update
  to authenticated
  using (negocio_id = (select mi_negocio()))
  with check (negocio_id = (select mi_negocio()));

create policy "negocio_borra_sus_facturas"
  on pc_facturas
  for delete
  to authenticated
  using (negocio_id = (select mi_negocio()));

-- ─── pc_inventario ────────────────────────────────────────────────────────
alter table pc_inventario
  add column negocio_id uuid references negocios(id);

alter table pc_inventario
  alter column negocio_id set not null;

create index if not exists pc_inventario_negocio_id_idx on pc_inventario (negocio_id);

drop policy if exists "pc_auth_all" on pc_inventario;
drop policy if exists "pc_inventario all" on pc_inventario;
drop policy if exists "pc_inventario delete" on pc_inventario;

create policy "negocio_lee_su_inventario"
  on pc_inventario
  for select
  to authenticated
  using (negocio_id = (select mi_negocio()));

create policy "negocio_escribe_su_inventario"
  on pc_inventario
  for insert
  to authenticated
  with check (negocio_id = (select mi_negocio()));

create policy "negocio_actualiza_su_inventario"
  on pc_inventario
  for update
  to authenticated
  using (negocio_id = (select mi_negocio()))
  with check (negocio_id = (select mi_negocio()));

create policy "negocio_borra_su_inventario"
  on pc_inventario
  for delete
  to authenticated
  using (negocio_id = (select mi_negocio()));

-- ─── pc_empleados (nómina) ────────────────────────────────────────────────
alter table pc_empleados
  add column negocio_id uuid references negocios(id);

alter table pc_empleados
  alter column negocio_id set not null;

create index if not exists pc_empleados_negocio_id_idx on pc_empleados (negocio_id);

drop policy if exists "pc_auth_all" on pc_empleados;
drop policy if exists "pc_empleados all" on pc_empleados;
drop policy if exists "pc_empleados delete" on pc_empleados;

create policy "negocio_lee_sus_empleados"
  on pc_empleados
  for select
  to authenticated
  using (negocio_id = (select mi_negocio()));

create policy "negocio_escribe_sus_empleados"
  on pc_empleados
  for insert
  to authenticated
  with check (negocio_id = (select mi_negocio()));

create policy "negocio_actualiza_sus_empleados"
  on pc_empleados
  for update
  to authenticated
  using (negocio_id = (select mi_negocio()))
  with check (negocio_id = (select mi_negocio()));

create policy "negocio_borra_sus_empleados"
  on pc_empleados
  for delete
  to authenticated
  using (negocio_id = (select mi_negocio()));

-- ─── pc_gastos ────────────────────────────────────────────────────────────
alter table pc_gastos
  add column negocio_id uuid references negocios(id);

alter table pc_gastos
  alter column negocio_id set not null;

create index if not exists pc_gastos_negocio_id_idx on pc_gastos (negocio_id);

drop policy if exists "pc_auth_all" on pc_gastos;
drop policy if exists "pc_gastos all" on pc_gastos;
drop policy if exists "pc_gastos delete" on pc_gastos;

create policy "negocio_lee_sus_gastos"
  on pc_gastos
  for select
  to authenticated
  using (negocio_id = (select mi_negocio()));

create policy "negocio_escribe_sus_gastos"
  on pc_gastos
  for insert
  to authenticated
  with check (negocio_id = (select mi_negocio()));

create policy "negocio_actualiza_sus_gastos"
  on pc_gastos
  for update
  to authenticated
  using (negocio_id = (select mi_negocio()))
  with check (negocio_id = (select mi_negocio()));

create policy "negocio_borra_sus_gastos"
  on pc_gastos
  for delete
  to authenticated
  using (negocio_id = (select mi_negocio()));

-- ─── pc_citas ─────────────────────────────────────────────────────────────
alter table pc_citas
  add column negocio_id uuid references negocios(id);

alter table pc_citas
  alter column negocio_id set not null;

create index if not exists pc_citas_negocio_id_idx on pc_citas (negocio_id);

drop policy if exists "pc_auth_all" on pc_citas;
drop policy if exists "pc_citas all" on pc_citas;
drop policy if exists "pc_citas delete" on pc_citas;

create policy "negocio_lee_sus_citas"
  on pc_citas
  for select
  to authenticated
  using (negocio_id = (select mi_negocio()));

create policy "negocio_escribe_sus_citas"
  on pc_citas
  for insert
  to authenticated
  with check (negocio_id = (select mi_negocio()));

create policy "negocio_actualiza_sus_citas"
  on pc_citas
  for update
  to authenticated
  using (negocio_id = (select mi_negocio()))
  with check (negocio_id = (select mi_negocio()));

create policy "negocio_borra_sus_citas"
  on pc_citas
  for delete
  to authenticated
  using (negocio_id = (select mi_negocio()));
