-- Cierre de hallazgos de los asesores de Supabase.
--
-- Las implementaciones financieras conservan SECURITY DEFINER para ejecutar
-- una transacción validada, pero se mueven fuera del esquema expuesto. En
-- public solo quedan wrappers SECURITY INVOKER con firmas compatibles.

alter function public.crear_factura(jsonb) set schema private;
alter function public.actualizar_factura(jsonb) set schema private;
alter function public.anular_factura(text, text) set schema private;
alter function public.registrar_cobro_venta(text, numeric, text, text, uuid) set schema private;

revoke all on function private.crear_factura(jsonb)
  from public, anon, authenticated;
revoke all on function private.actualizar_factura(jsonb)
  from public, anon, authenticated;
revoke all on function private.anular_factura(text, text)
  from public, anon, authenticated;
revoke all on function private.registrar_cobro_venta(text, numeric, text, text, uuid)
  from public, anon, authenticated;

grant usage on schema private to authenticated, service_role;
grant execute on function private.crear_factura(jsonb)
  to authenticated, service_role;
grant execute on function private.actualizar_factura(jsonb)
  to authenticated, service_role;
grant execute on function private.anular_factura(text, text)
  to authenticated, service_role;
grant execute on function private.registrar_cobro_venta(text, numeric, text, text, uuid)
  to authenticated, service_role;

create function public.crear_factura(factura jsonb)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.crear_factura(factura);
$$;

create function public.actualizar_factura(factura jsonb)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.actualizar_factura(factura);
$$;

create function public.anular_factura(factura_id text, motivo text)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.anular_factura(factura_id, motivo);
$$;

create function public.registrar_cobro_venta(
  p_venta_id text,
  p_monto numeric,
  p_forma text,
  p_fecha_recordatorio text default null,
  p_operacion_id uuid default gen_random_uuid()
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.registrar_cobro_venta(
    p_venta_id,
    p_monto,
    p_forma,
    p_fecha_recordatorio,
    p_operacion_id
  );
$$;

revoke all on function public.crear_factura(jsonb) from public, anon;
revoke all on function public.actualizar_factura(jsonb) from public, anon;
revoke all on function public.anular_factura(text, text) from public, anon;
revoke all on function public.registrar_cobro_venta(text, numeric, text, text, uuid)
  from public, anon;

grant execute on function public.crear_factura(jsonb) to authenticated;
grant execute on function public.actualizar_factura(jsonb) to authenticated;
grant execute on function public.anular_factura(text, text) to authenticated;
grant execute on function public.registrar_cobro_venta(text, numeric, text, text, uuid)
  to authenticated;

create index if not exists vetmake_venta_operaciones_usuario_idx
  on private.vetmake_venta_operaciones (usuario_id);
create index if not exists vetmake_cita_operaciones_usuario_idx
  on private.vetmake_cita_operaciones (usuario_id);
create index if not exists vetmake_venta_mutaciones_usuario_idx
  on private.vetmake_venta_mutaciones (usuario_id);

-- La tabla privada ya estaba revocada. Una política explícitamente falsa deja
-- documentada la intención y elimina el aviso de RLS sin política.
drop policy if exists vetmake_admision_limites_solo_servidor
  on private.vetmake_admision_limites;
create policy vetmake_admision_limites_solo_servidor
  on private.vetmake_admision_limites
  for all
  to authenticated
  using (false)
  with check (false);

comment on function public.crear_factura(jsonb) is
  'Wrapper invoker para la emisión validada en private.crear_factura.';
comment on function public.actualizar_factura(jsonb) is
  'Wrapper invoker para la corrección validada en private.actualizar_factura.';
comment on function public.anular_factura(text, text) is
  'Wrapper invoker para la anulación validada en private.anular_factura.';
comment on function public.registrar_cobro_venta(text, numeric, text, text, uuid) is
  'Wrapper invoker para el cobro idempotente en private.registrar_cobro_venta.';

notify pgrst, 'reload schema';
