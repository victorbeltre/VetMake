-- VetMake · Fase 1: onboarding operativo por negocio
--
-- Agrega los datos comerciales que necesita una clínica para emitir
-- documentos y comunicarse con sus clientes, además de la configuración
-- básica del equipo. No crea usuarios de Auth: el alta de accesos sigue
-- siendo una operación administrativa separada.

-- ─── 1. Perfil comercial de la clínica ───────────────────────────────────
alter table public.negocios
  add column if not exists tagline text,
  add column if not exists telefono text,
  add column if not exists direccion text,
  add column if not exists rnc text,
  add column if not exists email text,
  add column if not exists whatsapp text,
  add column if not exists instagram text,
  add column if not exists facebook text,
  add column if not exists sitio_web text;

comment on column public.negocios.tagline is
  'Texto corto que aparece en encabezados y documentos del negocio.';
comment on column public.negocios.rnc is
  'RNC comercial de la clínica; dato opcional para documentos y facturación.';

grant select, update on table public.negocios to authenticated;

-- Un miembro puede leer su negocio, pero solo un admin puede editarlo.
drop policy if exists "negocio_propio_update" on public.negocios;
create policy "negocio_propio_update"
  on public.negocios
  for update
  to authenticated
  using (
    id = (select mi_negocio())
    and exists (
      select 1
      from public.usuarios_negocio m
      where m.usuario_id = (select auth.uid())
        and m.negocio_id = public.negocios.id
        and m.rol = 'admin'
    )
  )
  with check (
    id = (select mi_negocio())
    and exists (
      select 1
      from public.usuarios_negocio m
      where m.usuario_id = (select auth.uid())
        and m.negocio_id = public.negocios.id
        and m.rol = 'admin'
    )
  );

-- ─── 2. Configuración del equipo ─────────────────────────────────────────
alter table public.pc_empleados
  add column if not exists usuario_id uuid references auth.users(id) on delete set null,
  add column if not exists email text,
  add column if not exists telefono text,
  add column if not exists rol text check (rol in ('admin', 'veterinario', 'groomer', 'caja')),
  add column if not exists activo boolean not null default true,
  add column if not exists comision_pct numeric(5,2) not null default 0,
  add column if not exists tipo_pago text check (tipo_pago in ('mensual', 'comision', 'mixto'));

alter table public.pc_empleados
  drop constraint if exists pc_empleados_comision_pct_check;
alter table public.pc_empleados
  add constraint pc_empleados_comision_pct_check
  check (comision_pct >= 0 and comision_pct <= 100);

create index if not exists pc_empleados_usuario_id_idx
  on public.pc_empleados (usuario_id);

create unique index if not exists pc_empleados_usuario_negocio_uidx
  on public.pc_empleados (negocio_id, usuario_id)
  where usuario_id is not null;

-- El equipo puede consultar su propio negocio; solo admin gestiona nómina.
drop policy if exists "negocio_escribe_sus_empleados" on public.pc_empleados;
drop policy if exists "negocio_actualiza_sus_empleados" on public.pc_empleados;
drop policy if exists "negocio_borra_sus_empleados" on public.pc_empleados;

create policy "negocio_escribe_sus_empleados"
  on public.pc_empleados
  for insert
  to authenticated
  with check (
    negocio_id = (select mi_negocio())
    and exists (
      select 1
      from public.usuarios_negocio m
      where m.usuario_id = (select auth.uid())
        and m.negocio_id = public.pc_empleados.negocio_id
        and m.rol = 'admin'
    )
  );

create policy "negocio_actualiza_sus_empleados"
  on public.pc_empleados
  for update
  to authenticated
  using (
    negocio_id = (select mi_negocio())
    and exists (
      select 1
      from public.usuarios_negocio m
      where m.usuario_id = (select auth.uid())
        and m.negocio_id = public.pc_empleados.negocio_id
        and m.rol = 'admin'
    )
  )
  with check (
    negocio_id = (select mi_negocio())
    and exists (
      select 1
      from public.usuarios_negocio m
      where m.usuario_id = (select auth.uid())
        and m.negocio_id = public.pc_empleados.negocio_id
        and m.rol = 'admin'
    )
  );

create policy "negocio_borra_sus_empleados"
  on public.pc_empleados
  for delete
  to authenticated
  using (
    negocio_id = (select mi_negocio())
    and exists (
      select 1
      from public.usuarios_negocio m
      where m.usuario_id = (select auth.uid())
        and m.negocio_id = public.pc_empleados.negocio_id
        and m.rol = 'admin'
    )
  );

-- ─── 3. Tarifas y comisiones: solo admin las modifica ────────────────────
drop policy if exists "negocio_escribe_sus_tarifas" on public.pc_tarifas;
drop policy if exists "negocio_actualiza_sus_tarifas" on public.pc_tarifas;
drop policy if exists "negocio_borra_sus_tarifas" on public.pc_tarifas;

create policy "negocio_escribe_sus_tarifas"
  on public.pc_tarifas
  for insert
  to authenticated
  with check (
    negocio_id = (select mi_negocio())
    and exists (
      select 1
      from public.usuarios_negocio m
      where m.usuario_id = (select auth.uid())
        and m.negocio_id = public.pc_tarifas.negocio_id
        and m.rol = 'admin'
    )
  );

create policy "negocio_actualiza_sus_tarifas"
  on public.pc_tarifas
  for update
  to authenticated
  using (
    negocio_id = (select mi_negocio())
    and exists (
      select 1
      from public.usuarios_negocio m
      where m.usuario_id = (select auth.uid())
        and m.negocio_id = public.pc_tarifas.negocio_id
        and m.rol = 'admin'
    )
  )
  with check (
    negocio_id = (select mi_negocio())
    and exists (
      select 1
      from public.usuarios_negocio m
      where m.usuario_id = (select auth.uid())
        and m.negocio_id = public.pc_tarifas.negocio_id
        and m.rol = 'admin'
    )
  );

create policy "negocio_borra_sus_tarifas"
  on public.pc_tarifas
  for delete
  to authenticated
  using (
    negocio_id = (select mi_negocio())
    and exists (
      select 1
      from public.usuarios_negocio m
      where m.usuario_id = (select auth.uid())
        and m.negocio_id = public.pc_tarifas.negocio_id
        and m.rol = 'admin'
    )
  );
