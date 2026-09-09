-- Cierra el esquema private con mínimo privilegio y defensa en profundidad.
-- Las funciones SECURITY DEFINER autorizadas siguen siendo la única entrada;
-- sus wrappers públicos son SECURITY INVOKER y comprueban sesión/tenant/rol.

-- ─── 1. RLS y denegación explícita de acceso directo ────────────────────

alter table private.pc_citas_diagnostico_archivo enable row level security;
alter table private.vetmake_admision_limites enable row level security;
alter table private.vetmake_cita_operaciones enable row level security;
alter table private.vetmake_cliente_operaciones enable row level security;
alter table private.vetmake_clinica_operaciones enable row level security;
alter table private.vetmake_inventario_archivo enable row level security;
alter table private.vetmake_inventario_operaciones enable row level security;
alter table private.vetmake_tarifas_operaciones enable row level security;
alter table private.vetmake_venta_mutaciones enable row level security;
alter table private.vetmake_venta_operaciones enable row level security;

drop policy if exists pc_citas_diagnostico_archivo_sin_acceso_directo
  on private.pc_citas_diagnostico_archivo;
create policy pc_citas_diagnostico_archivo_sin_acceso_directo
  on private.pc_citas_diagnostico_archivo for all to anon, authenticated
  using (false) with check (false);

drop policy if exists vetmake_cita_operaciones_sin_acceso_directo
  on private.vetmake_cita_operaciones;
create policy vetmake_cita_operaciones_sin_acceso_directo
  on private.vetmake_cita_operaciones for all to anon, authenticated
  using (false) with check (false);

drop policy if exists vetmake_cliente_operaciones_sin_acceso_directo
  on private.vetmake_cliente_operaciones;
create policy vetmake_cliente_operaciones_sin_acceso_directo
  on private.vetmake_cliente_operaciones for all to anon, authenticated
  using (false) with check (false);

drop policy if exists vetmake_clinica_operaciones_sin_acceso_directo
  on private.vetmake_clinica_operaciones;
create policy vetmake_clinica_operaciones_sin_acceso_directo
  on private.vetmake_clinica_operaciones for all to anon, authenticated
  using (false) with check (false);

drop policy if exists vetmake_inventario_archivo_sin_acceso_directo
  on private.vetmake_inventario_archivo;
create policy vetmake_inventario_archivo_sin_acceso_directo
  on private.vetmake_inventario_archivo for all to anon, authenticated
  using (false) with check (false);

drop policy if exists vetmake_inventario_operaciones_sin_acceso_directo
  on private.vetmake_inventario_operaciones;
create policy vetmake_inventario_operaciones_sin_acceso_directo
  on private.vetmake_inventario_operaciones for all to anon, authenticated
  using (false) with check (false);

drop policy if exists vetmake_tarifas_operaciones_sin_acceso_directo
  on private.vetmake_tarifas_operaciones;
create policy vetmake_tarifas_operaciones_sin_acceso_directo
  on private.vetmake_tarifas_operaciones for all to anon, authenticated
  using (false) with check (false);

drop policy if exists vetmake_venta_mutaciones_sin_acceso_directo
  on private.vetmake_venta_mutaciones;
create policy vetmake_venta_mutaciones_sin_acceso_directo
  on private.vetmake_venta_mutaciones for all to anon, authenticated
  using (false) with check (false);

drop policy if exists vetmake_venta_operaciones_sin_acceso_directo
  on private.vetmake_venta_operaciones;
create policy vetmake_venta_operaciones_sin_acceso_directo
  on private.vetmake_venta_operaciones for all to anon, authenticated
  using (false) with check (false);

-- vetmake_admision_limites ya tiene su política histórica de denegación
-- vetmake_admision_limites_solo_servidor; se conserva sin duplicarla.

-- ─── 2. Tablas, secuencias y esquema sin acceso directo ─────────────────

revoke all privileges on all tables in schema private
  from public, anon, authenticated, service_role;
revoke all privileges on all sequences in schema private
  from public, anon, authenticated, service_role;

revoke all privileges on schema private from public, anon;
revoke create on schema private from authenticated, service_role;
grant usage on schema private to authenticated, service_role;

-- ─── 3. Funciones: cerrar todo y reabrir solo endpoints auditados ────────

revoke all privileges on all functions in schema private
  from public, anon, authenticated, service_role;

grant execute on function private.actualizar_factura(jsonb)
  to authenticated, service_role;
grant execute on function private.anular_factura(text, text)
  to authenticated, service_role;
grant execute on function private.anular_venta_impl(text, text, uuid)
  to authenticated, service_role;
grant execute on function private.corregir_venta_impl(jsonb, text, uuid)
  to authenticated, service_role;
grant execute on function private.crear_factura(jsonb)
  to authenticated, service_role;
grant execute on function private.eliminar_cita_segura_impl(bigint, uuid)
  to authenticated, service_role;
grant execute on function private.eliminar_cliente_impl(numeric, uuid)
  to authenticated, service_role;
grant execute on function private.eliminar_producto_inventario_impl(text, uuid)
  to authenticated, service_role;
grant execute on function private.fusionar_clientes_impl(numeric, numeric[], jsonb, text[], uuid)
  to authenticated, service_role;
grant execute on function private.generar_respaldo_negocio_impl()
  to authenticated, service_role;
grant execute on function private.guardar_cita_atomica_impl(jsonb, uuid)
  to authenticated, service_role;
grant execute on function private.guardar_cliente_crm_atomico_impl(numeric, jsonb, uuid)
  to authenticated, service_role;
grant execute on function private.guardar_ficha_clinica_atomica_impl(numeric, jsonb, jsonb, uuid)
  to authenticated, service_role;
grant execute on function private.guardar_ficha_medica_atomica_impl(numeric, jsonb, uuid)
  to authenticated, service_role;
grant execute on function private.guardar_inventario_lote_impl(jsonb, text, uuid)
  to authenticated, service_role;
grant execute on function private.guardar_tarifas_lote_impl(jsonb, text, uuid)
  to authenticated, service_role;
grant execute on function private.guardar_telefono_cliente_venta_impl(numeric, text, text, uuid)
  to authenticated, service_role;
grant execute on function private.importar_catalogo_impl(jsonb, jsonb, text, uuid)
  to authenticated, service_role;
grant execute on function private.importar_clientes_atomico_impl(jsonb, text, uuid)
  to authenticated, service_role;
grant execute on function private.importar_datos_criticos_impl(text, jsonb, uuid)
  to authenticated, service_role;
grant execute on function private.importar_inventario_impl(jsonb, text, uuid)
  to authenticated, service_role;
grant execute on function private.probar_respaldo_negocio_impl()
  to authenticated, service_role;
grant execute on function private.registrar_cobro_venta(text, numeric, text, text, uuid)
  to authenticated, service_role;
grant execute on function private.registrar_venta_atomica_impl(jsonb, jsonb, text, jsonb, bigint, uuid)
  to authenticated, service_role;
grant execute on function private.retirar_tarifa_impl(text, uuid)
  to authenticated, service_role;

-- ─── 4. Objetos futuros: cerrados hasta un GRANT explícito ──────────────

alter default privileges for role postgres in schema private
  revoke select, insert, update, delete, truncate, references, trigger
  on tables from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema private
  revoke usage, select, update
  on sequences from public, anon, authenticated, service_role;

-- PostgreSQL concede EXECUTE a PUBLIC globalmente en funciones nuevas. Una
-- revocación por esquema no puede contradecir ese privilegio global inicial.
-- Se cierra para todas las funciones futuras y cada RPC deberá hacer GRANT.
alter default privileges for role postgres
  revoke execute on functions from public, anon, authenticated, service_role;

comment on schema private is
  'Objetos internos VetMake: sin acceso tabular directo; solo endpoints SECURITY DEFINER auditados mediante wrappers públicos.';

notify pgrst, 'reload schema';
