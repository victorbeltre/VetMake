-- VetMake · Fase 1: cerrar permisos explícitos de anon
--
-- La migración 0003 dejó RLS habilitado, pero la plantilla de permisos del
-- proyecto también había otorgado privilegios de tabla a anon. Sin políticas
-- de anon las filas ya estaban bloqueadas; revocamos además el privilegio de
-- llegar al Data API para que la frontera sea explícita.

revoke all on table
  public.negocios,
  public.usuarios_negocio,
  public.pc_clientes,
  public.pc_ventas,
  public.pc_facturas,
  public.pc_inventario,
  public.pc_empleados,
  public.pc_gastos,
  public.pc_citas
  from anon;

revoke execute on function public.mi_negocio() from public, anon;
grant execute on function public.mi_negocio() to authenticated, service_role;

-- Reafirmar los permisos mínimos que usa la aplicación autenticada después
-- de retirar los permisos anónimos.
grant select on table public.negocios, public.usuarios_negocio to authenticated;
grant select, insert, update, delete on table
  public.pc_clientes,
  public.pc_ventas,
  public.pc_facturas,
  public.pc_inventario,
  public.pc_empleados,
  public.pc_gastos,
  public.pc_citas
  to authenticated;
