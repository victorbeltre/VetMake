-- VetMake · Seguridad de producción: membresías, roles y auditoría inmutable
--
-- Esta migración mantiene el aislamiento por negocio y agrega autorización
-- real por rol. También elimina privilegios SQL que Postgres concede por
-- defecto (TRUNCATE, TRIGGER y REFERENCES) y mueve la auditoría al servidor.

-- ─── 1. Una sola membresía activa por usuario en el MVP ──────────────────
alter table public.usuarios_negocio
  add column if not exists activo boolean not null default true;

create unique index if not exists usuarios_negocio_usuario_unico_uidx
  on public.usuarios_negocio (usuario_id);

create or replace function public.mi_negocio()
returns uuid
language sql
stable
security invoker
set search_path = ''
as $$
  select membresia.negocio_id
  from public.usuarios_negocio as membresia
  where membresia.usuario_id = (select auth.uid())
    and membresia.activo = true;
$$;

create or replace function public.mi_rol()
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select membresia.rol
  from public.usuarios_negocio as membresia
  where membresia.usuario_id = (select auth.uid())
    and membresia.activo = true;
$$;

create or replace function public.tiene_rol(roles text[])
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce((select public.mi_rol()) = any(roles), false);
$$;

revoke all on function public.mi_negocio() from public, anon;
revoke all on function public.mi_rol() from public, anon;
revoke all on function public.tiene_rol(text[]) from public, anon;
grant execute on function public.mi_negocio() to authenticated, service_role;
grant execute on function public.mi_rol() to authenticated, service_role;
grant execute on function public.tiene_rol(text[]) to authenticated, service_role;

-- Identificador estable del empleado que atendió una venta. `recibidopor` se
-- conserva para compatibilidad y para migrar gradualmente los datos antiguos.
alter table public.pc_ventas
  add column if not exists empleadoid text;

create unique index if not exists pc_empleados_negocio_id_id_uidx
  on public.pc_empleados (negocio_id, id);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'pc_ventas_empleado_negocio_fkey'
      and conrelid = 'public.pc_ventas'::regclass
  ) then
    alter table public.pc_ventas
      add constraint pc_ventas_empleado_negocio_fkey
      foreign key (negocio_id, empleadoid)
      references public.pc_empleados (negocio_id, id)
      on update cascade on delete restrict;
  end if;
end
$$;

-- Solo completa coincidencias inequívocas; las demás quedan para revisión.
update public.pc_ventas as venta
set empleadoid = empleado.id
from public.pc_empleados as empleado
where venta.negocio_id = empleado.negocio_id
  and venta.empleadoid is null
  and nullif(btrim(venta.recibidopor), '') is not null
  and lower(btrim(venta.recibidopor)) = lower(btrim(empleado.nombre));

create or replace function public.es_empleado_actual(
  negocio uuid,
  empleado_id text,
  empleado_nombre text default null
)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select exists (
    select 1
    from public.pc_empleados as empleado
    where empleado.negocio_id = negocio
      and empleado.usuario_id = (select auth.uid())
      and empleado.activo = true
      and (
        (nullif(empleado_id, '') is not null and empleado.id = empleado_id)
        or (
          nullif(empleado_nombre, '') is not null
          and lower(btrim(empleado.nombre)) = lower(btrim(empleado_nombre))
        )
      )
  );
$$;

revoke all on function public.es_empleado_actual(uuid, text, text) from public, anon;
grant execute on function public.es_empleado_actual(uuid, text, text) to authenticated, service_role;

-- ─── 2. Privilegios SQL mínimos; RLS decide cada operación ───────────────
revoke all privileges on table
  public.negocios,
  public.usuarios_negocio,
  public.pc_clientes,
  public.pc_ventas,
  public.pc_facturas,
  public.pc_inventario,
  public.pc_empleados,
  public.pc_gastos,
  public.pc_citas,
  public.pc_seguimientos,
  public.pc_pagos,
  public.pc_tarifas,
  public.pc_historias,
  public.pc_fichas_clinicas,
  public.pc_depositos,
  public.pc_auditoria,
  public.pc_paquetes,
  public.vet_learning_aliases,
  public.vet_knowledge_products
from anon, authenticated;

grant select on table public.negocios, public.usuarios_negocio to authenticated;
grant update on table public.negocios to authenticated;

grant select, insert, update, delete on table
  public.pc_clientes,
  public.pc_ventas,
  public.pc_facturas,
  public.pc_inventario,
  public.pc_empleados,
  public.pc_gastos,
  public.pc_citas,
  public.pc_seguimientos,
  public.pc_pagos,
  public.pc_tarifas,
  public.pc_historias,
  public.pc_fichas_clinicas,
  public.pc_depositos,
  public.pc_paquetes,
  public.vet_learning_aliases
to authenticated;

grant select on table public.pc_auditoria, public.vet_knowledge_products to authenticated;

revoke all privileges on all sequences in schema public from anon, authenticated;
grant usage, select on sequence public.vet_learning_aliases_id_seq to authenticated;

-- Quita las políticas operativas anteriores para reemplazarlas por la matriz
-- completa de roles. Las políticas de Storage se gestionan aparte.
do $$
declare
  politica record;
begin
  for politica in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename = any(array[
        'negocios', 'usuarios_negocio', 'pc_clientes', 'pc_ventas',
        'pc_facturas', 'pc_inventario', 'pc_empleados', 'pc_gastos',
        'pc_citas', 'pc_seguimientos', 'pc_pagos', 'pc_tarifas',
        'pc_historias', 'pc_fichas_clinicas', 'pc_depositos',
        'pc_auditoria', 'pc_paquetes', 'vet_learning_aliases'
      ])
  loop
    execute format(
      'drop policy if exists %I on %I.%I',
      politica.policyname,
      politica.schemaname,
      politica.tablename
    );
  end loop;
end
$$;

-- ─── 3. Negocio y membresía ──────────────────────────────────────────────
create policy negocio_miembro_lee
  on public.negocios for select to authenticated
  using (id = (select public.mi_negocio()));

create policy negocio_admin_actualiza
  on public.negocios for update to authenticated
  using (
    id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  )
  with check (
    id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

create policy membresia_propia_lee
  on public.usuarios_negocio for select to authenticated
  using (usuario_id = (select auth.uid()));

-- ─── 4. Clientes ─────────────────────────────────────────────────────────
create policy clientes_equipo_lee
  on public.pc_clientes for select to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja','veterinario','groomer']::text[]))
  );

create policy clientes_equipo_inserta
  on public.pc_clientes for insert to authenticated
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja','veterinario','groomer']::text[]))
  );

create policy clientes_equipo_actualiza
  on public.pc_clientes for update to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja','veterinario','groomer']::text[]))
  )
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja','veterinario','groomer']::text[]))
  );

create policy clientes_admin_borra
  on public.pc_clientes for delete to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

-- ─── 5. Ventas ───────────────────────────────────────────────────────────
create policy ventas_autorizadas_lee
  on public.pc_ventas for select to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (
      (select public.tiene_rol(array['admin','caja','veterinario']::text[]))
      or (
        (select public.tiene_rol(array['groomer']::text[]))
        and (select public.es_empleado_actual(negocio_id, empleadoid, recibidopor))
      )
    )
  );

create policy ventas_autorizadas_inserta
  on public.pc_ventas for insert to authenticated
  with check (
    negocio_id = (select public.mi_negocio())
    and (
      (select public.tiene_rol(array['admin','caja','veterinario']::text[]))
      or (
        (select public.tiene_rol(array['groomer']::text[]))
        and (select public.es_empleado_actual(negocio_id, empleadoid, recibidopor))
      )
    )
  );

create policy ventas_autorizadas_actualiza
  on public.pc_ventas for update to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (
      (select public.tiene_rol(array['admin','caja','veterinario']::text[]))
      or (
        (select public.tiene_rol(array['groomer']::text[]))
        and (select public.es_empleado_actual(negocio_id, empleadoid, recibidopor))
      )
    )
  )
  with check (
    negocio_id = (select public.mi_negocio())
    and (
      (select public.tiene_rol(array['admin','caja','veterinario']::text[]))
      or (
        (select public.tiene_rol(array['groomer']::text[]))
        and (select public.es_empleado_actual(negocio_id, empleadoid, recibidopor))
      )
    )
  );

create policy ventas_admin_borra
  on public.pc_ventas for delete to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

-- ─── 6. Facturas y depósitos ─────────────────────────────────────────────
create policy facturas_operacion_lee
  on public.pc_facturas for select to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja','veterinario']::text[]))
  );

create policy facturas_operacion_inserta
  on public.pc_facturas for insert to authenticated
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja','veterinario']::text[]))
  );

create policy facturas_caja_actualiza
  on public.pc_facturas for update to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja']::text[]))
  )
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja']::text[]))
  );

create policy facturas_admin_borra
  on public.pc_facturas for delete to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

create policy depositos_caja_lee
  on public.pc_depositos for select to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja']::text[]))
  );

create policy depositos_caja_inserta
  on public.pc_depositos for insert to authenticated
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja']::text[]))
  );

create policy depositos_caja_actualiza
  on public.pc_depositos for update to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja']::text[]))
  )
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja']::text[]))
  );

create policy depositos_admin_borra
  on public.pc_depositos for delete to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

-- ─── 7. Inventario, gastos y paquetes ────────────────────────────────────
create policy inventario_equipo_lee
  on public.pc_inventario for select to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja','veterinario','groomer']::text[]))
  );

create policy inventario_caja_inserta
  on public.pc_inventario for insert to authenticated
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja']::text[]))
  );

create policy inventario_caja_actualiza
  on public.pc_inventario for update to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja']::text[]))
  )
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja']::text[]))
  );

create policy inventario_admin_borra
  on public.pc_inventario for delete to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

create policy gastos_administracion_lee
  on public.pc_gastos for select to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja']::text[]))
  );

create policy gastos_administracion_inserta
  on public.pc_gastos for insert to authenticated
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja']::text[]))
  );

create policy gastos_administracion_actualiza
  on public.pc_gastos for update to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja']::text[]))
  )
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja']::text[]))
  );

create policy gastos_admin_borra
  on public.pc_gastos for delete to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

create policy paquetes_caja_lee
  on public.pc_paquetes for select to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja']::text[]))
  );

create policy paquetes_caja_inserta
  on public.pc_paquetes for insert to authenticated
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja']::text[]))
  );

create policy paquetes_caja_actualiza
  on public.pc_paquetes for update to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja']::text[]))
  )
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja']::text[]))
  );

create policy paquetes_admin_borra
  on public.pc_paquetes for delete to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

-- ─── 8. Agenda y seguimientos ────────────────────────────────────────────
create policy citas_equipo_lee
  on public.pc_citas for select to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja','veterinario','groomer']::text[]))
  );

create policy citas_equipo_inserta
  on public.pc_citas for insert to authenticated
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja','veterinario','groomer']::text[]))
  );

create policy citas_equipo_actualiza
  on public.pc_citas for update to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja','veterinario','groomer']::text[]))
  )
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja','veterinario','groomer']::text[]))
  );

create policy citas_equipo_borra
  on public.pc_citas for delete to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja','veterinario','groomer']::text[]))
  );

create policy seguimientos_clinica_lee
  on public.pc_seguimientos for select to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja','veterinario']::text[]))
  );

create policy seguimientos_clinica_inserta
  on public.pc_seguimientos for insert to authenticated
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja','veterinario']::text[]))
  );

create policy seguimientos_clinica_actualiza
  on public.pc_seguimientos for update to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja','veterinario']::text[]))
  )
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja','veterinario']::text[]))
  );

create policy seguimientos_admin_borra
  on public.pc_seguimientos for delete to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

-- ─── 9. Equipo, nómina y tarifas ─────────────────────────────────────────
create policy empleados_admin_o_propio_lee
  on public.pc_empleados for select to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (
      (select public.tiene_rol(array['admin']::text[]))
      or usuario_id = (select auth.uid())
    )
  );

create policy empleados_admin_inserta
  on public.pc_empleados for insert to authenticated
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

create policy empleados_admin_actualiza
  on public.pc_empleados for update to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  )
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

create policy empleados_admin_borra
  on public.pc_empleados for delete to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

create policy pagos_admin_o_propio_lee
  on public.pc_pagos for select to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (
      (select public.tiene_rol(array['admin']::text[]))
      or (select public.es_empleado_actual(negocio_id, empleadoid, empleadonombre))
    )
  );

create policy pagos_admin_inserta
  on public.pc_pagos for insert to authenticated
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

create policy pagos_admin_actualiza
  on public.pc_pagos for update to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  )
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

create policy pagos_admin_borra
  on public.pc_pagos for delete to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

create policy tarifas_equipo_lee
  on public.pc_tarifas for select to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja','veterinario','groomer']::text[]))
  );

create policy tarifas_admin_inserta
  on public.pc_tarifas for insert to authenticated
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

create policy tarifas_admin_actualiza
  on public.pc_tarifas for update to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  )
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

create policy tarifas_admin_borra
  on public.pc_tarifas for delete to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

-- ─── 10. Historias y fichas clínicas ─────────────────────────────────────
create policy historias_clinicos_lee
  on public.pc_historias for select to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','veterinario']::text[]))
  );

create policy historias_clinicos_inserta
  on public.pc_historias for insert to authenticated
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','veterinario']::text[]))
  );

create policy historias_clinicos_actualiza
  on public.pc_historias for update to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','veterinario']::text[]))
  )
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','veterinario']::text[]))
  );

create policy historias_admin_borra
  on public.pc_historias for delete to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

create policy fichas_clinicos_lee
  on public.pc_fichas_clinicas for select to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','veterinario']::text[]))
  );

create policy fichas_clinicos_inserta
  on public.pc_fichas_clinicas for insert to authenticated
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','veterinario']::text[]))
  );

create policy fichas_clinicos_actualiza
  on public.pc_fichas_clinicas for update to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','veterinario']::text[]))
  )
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','veterinario']::text[]))
  );

create policy fichas_admin_borra
  on public.pc_fichas_clinicas for delete to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

-- ─── 11. Aprendizaje y auditoría ─────────────────────────────────────────
create policy aprendizaje_admin_lee
  on public.vet_learning_aliases for select to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

create policy aprendizaje_admin_inserta
  on public.vet_learning_aliases for insert to authenticated
  with check (
    negocio_id = (select public.mi_negocio())
    and confirmed_by = (select auth.uid())
    and (select public.tiene_rol(array['admin']::text[]))
  );

create policy aprendizaje_admin_actualiza
  on public.vet_learning_aliases for update to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  )
  with check (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

create policy aprendizaje_admin_borra
  on public.vet_learning_aliases for delete to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

alter table public.pc_auditoria
  add column if not exists usuario_id uuid,
  add column if not exists antes jsonb,
  add column if not exists despues jsonb;

create sequence if not exists public.pc_auditoria_id_seq as bigint;
select setval(
  'public.pc_auditoria_id_seq',
  greatest(coalesce((select max(id) from public.pc_auditoria), 0) + 1, 1),
  false
);
alter sequence public.pc_auditoria_id_seq owned by public.pc_auditoria.id;
alter table public.pc_auditoria
  alter column id set default nextval('public.pc_auditoria_id_seq');

create or replace function public.registrar_auditoria_vetmake()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  fila jsonb;
  negocio uuid;
  monto numeric := 0;
begin
  fila := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  negocio := nullif(fila ->> 'negocio_id', '')::uuid;

  if negocio is null then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  if nullif(fila ->> 'total', '') is not null then
    monto := (fila ->> 'total')::numeric;
  elsif nullif(fila ->> 'monto', '') is not null then
    monto := (fila ->> 'monto')::numeric;
  elsif nullif(fila ->> 'totalpagado', '') is not null then
    monto := (fila ->> 'totalpagado')::numeric;
  end if;

  insert into public.pc_auditoria (
    negocio_id,
    fecha,
    usuario_id,
    usuario,
    tabla,
    accion,
    filaid,
    resumen,
    monto,
    antes,
    despues
  ) values (
    negocio,
    statement_timestamp(),
    (select auth.uid()),
    coalesce((select auth.jwt() ->> 'email'), (select auth.uid())::text, current_user),
    tg_table_name,
    lower(tg_op),
    coalesce(fila ->> 'id', ''),
    concat(tg_table_name, ' · ', lower(tg_op)),
    monto,
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else null end
  );

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function public.registrar_auditoria_vetmake() from public, anon, authenticated;

do $$
declare
  tabla text;
begin
  foreach tabla in array array[
    'pc_clientes', 'pc_ventas', 'pc_facturas', 'pc_inventario',
    'pc_empleados', 'pc_gastos', 'pc_citas', 'pc_seguimientos',
    'pc_pagos', 'pc_tarifas', 'pc_historias', 'pc_fichas_clinicas',
    'pc_depositos', 'pc_paquetes'
  ]
  loop
    execute format('drop trigger if exists vetmake_audita_cambios on public.%I', tabla);
    execute format(
      'create trigger vetmake_audita_cambios after insert or update or delete on public.%I for each row execute function public.registrar_auditoria_vetmake()',
      tabla
    );
  end loop;
end
$$;

create policy auditoria_admin_lee
  on public.pc_auditoria for select to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin']::text[]))
  );

comment on function public.mi_rol() is
  'Devuelve el rol activo de la membresía actual; se usa exclusivamente para autorización RLS.';
comment on table public.pc_auditoria is
  'Registro inmutable generado por triggers. La aplicación no puede insertar, modificar ni borrar auditorías.';
