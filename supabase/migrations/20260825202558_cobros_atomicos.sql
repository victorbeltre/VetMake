-- VetMake · Cobros atómicos e idempotentes
--
-- Un abono es dinero: no puede depender de un PATCH calculado en el navegador.
-- Esta función bloquea la venta, recalcula el saldo en PostgreSQL y registra
-- una operación idempotente, evitando cobros duplicados entre cajas o reintentos.

drop policy if exists factura_contador_solo_servidor
  on public.pc_factura_contadores;

create policy factura_contador_solo_servidor
  on public.pc_factura_contadores
  for all
  to authenticated
  using (false)
  with check (false);

create or replace function public.proteger_cobros_venta()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op <> 'UPDATE' then
    return new;
  end if;

  if current_setting('vetmake.cobro_rpc', true) = 'on'
     or coalesce((select auth.jwt() ->> 'role'), '') = 'service_role' then
    return new;
  end if;

  if new.abonos is distinct from old.abonos
     or new.abonado is distinct from old.abonado
     or new.formapago is distinct from old.formapago
     or new.fecharecordatorio is distinct from old.fecharecordatorio
     or new.cobradopor is distinct from old.cobradopor then
    raise exception using
      errcode = '42501',
      message = 'Los cobros deben registrarse con la operación transaccional de VetMake.';
  end if;

  if coalesce(old.abonado, 0) > 0
     and new.total is distinct from old.total then
    raise exception using
      errcode = '42501',
      message = 'No se puede cambiar el total de una venta que ya tiene abonos.';
  end if;

  return new;
end;
$$;

revoke all on function public.proteger_cobros_venta()
  from public, anon, authenticated;

drop trigger if exists vetmake_protege_cobros_venta on public.pc_ventas;
create trigger vetmake_protege_cobros_venta
before update on public.pc_ventas
for each row execute function public.proteger_cobros_venta();

create or replace function public.registrar_cobro_venta(
  p_venta_id text,
  p_monto numeric,
  p_forma text,
  p_fecha_recordatorio text default null,
  p_operacion_id uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  usuario uuid := (select auth.uid());
  negocio uuid;
  rol text;
  zona text;
  fila public.pc_ventas%rowtype;
  movimientos jsonb;
  operacion uuid := coalesce(p_operacion_id, gen_random_uuid());
  monto numeric := round(coalesce(p_monto, 0), 2);
  total_venta numeric;
  suma_detalle numeric := 0;
  abonado_actual numeric := 0;
  abonado_nuevo numeric;
  saldo_actual numeric;
  saldo_nuevo numeric;
  forma text;
  fecha_cobro text;
  recordatorio text := nullif(btrim(coalesce(p_fecha_recordatorio, '')), '');
  actor text := left(coalesce((select auth.jwt() ->> 'email'), usuario::text), 160);
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Se requiere una sesión autenticada.';
  end if;

  select membresia.negocio_id, membresia.rol, coalesce(clinica.zona_horaria, 'America/Santo_Domingo')
  into negocio, rol, zona
  from public.usuarios_negocio as membresia
  join public.negocios as clinica on clinica.id = membresia.negocio_id
  where membresia.usuario_id = usuario
    and membresia.activo = true
    and clinica.activo = true;

  if negocio is null or rol not in ('admin', 'caja', 'veterinario') then
    raise exception using errcode = '42501', message = 'Tu rol no puede registrar cobros.';
  end if;

  if nullif(btrim(coalesce(p_venta_id, '')), '') is null then
    raise exception using errcode = '22023', message = 'Falta identificar la venta.';
  end if;

  if monto <= 0 then
    raise exception using errcode = '22023', message = 'El monto del cobro debe ser mayor que cero.';
  end if;

  forma := case lower(btrim(coalesce(p_forma, '')))
    when 'efectivo' then 'Efectivo'
    when 'tarjeta' then 'Tarjeta'
    when 'transferencia' then 'Transferencia'
    else null
  end;

  if forma is null then
    raise exception using errcode = '22023', message = 'La forma de pago no es válida.';
  end if;

  select venta.*
  into fila
  from public.pc_ventas as venta
  where venta.id = p_venta_id
    and venta.negocio_id = negocio
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'La venta no existe en este negocio.';
  end if;

  movimientos := coalesce(fila.abonos, '[]'::jsonb);
  if jsonb_typeof(movimientos) <> 'array' then
    raise exception using errcode = '22023', message = 'El historial de cobros de la venta está dañado.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(movimientos) as movimiento
    where movimiento ->> 'id' = operacion::text
  ) then
    return to_jsonb(fila);
  end if;

  if exists (
    select 1
    from jsonb_array_elements(movimientos) as movimiento
    where coalesce(movimiento ->> 'monto', '') !~ '^[0-9]+([.][0-9]+)?$'
       or (movimiento ->> 'monto')::numeric <= 0
  ) then
    raise exception using errcode = '22023', message = 'El historial de cobros contiene un monto inválido.';
  end if;

  select coalesce(sum((movimiento ->> 'monto')::numeric), 0)
  into suma_detalle
  from jsonb_array_elements(movimientos) as movimiento;

  total_venta := round(greatest(coalesce(fila.total, 0), 0), 2);
  abonado_actual := round(greatest(suma_detalle, coalesce(fila.abonado, 0), 0), 2);

  -- Conserva saldos históricos que existan en la columna agregada aunque una
  -- versión antigua no haya guardado su detalle JSON.
  if abonado_actual > suma_detalle then
    movimientos := movimientos || jsonb_build_array(jsonb_build_object(
      'id', 'legacy-' || fila.id,
      'fecha', coalesce(nullif(fila.fecha, ''), current_date::text),
      'monto', round(abonado_actual - suma_detalle, 2),
      'forma', 'Pago anterior',
      'banco', '',
      'por', 'Migrado por VetMake'
    ));
  end if;

  saldo_actual := round(greatest(total_venta - abonado_actual, 0), 2);
  if saldo_actual <= 0 then
    raise exception using errcode = '22023', message = 'La venta ya está saldada.';
  end if;

  if monto > saldo_actual then
    raise exception using
      errcode = '22023',
      message = format('El cobro excede el saldo pendiente de %s.', saldo_actual);
  end if;

  fecha_cobro := ((statement_timestamp() at time zone zona)::date)::text;
  abonado_nuevo := round(abonado_actual + monto, 2);
  saldo_nuevo := round(greatest(total_venta - abonado_nuevo, 0), 2);

  if saldo_nuevo > 0 and recordatorio is not null then
    if recordatorio !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
      raise exception using errcode = '22007', message = 'La fecha del recordatorio no es válida.';
    end if;
    perform recordatorio::date;
  else
    recordatorio := null;
  end if;

  movimientos := movimientos || jsonb_build_array(jsonb_build_object(
    'id', operacion::text,
    'fecha', fecha_cobro,
    'monto', monto,
    'forma', lower(forma),
    'banco', '',
    'por', actor
  ));

  perform set_config('vetmake.cobro_rpc', 'on', true);

  update public.pc_ventas
  set abonos = movimientos,
      abonado = abonado_nuevo,
      formapago = case when saldo_nuevo > 0 then 'Pago pendiente' else forma end,
      fecharecordatorio = recordatorio,
      cobradopor = actor
  where id = fila.id
    and negocio_id = negocio
  returning * into fila;

  return to_jsonb(fila);
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception using errcode = '22023', message = 'El cobro contiene un monto o una fecha inválidos.';
end;
$$;

revoke all on function public.registrar_cobro_venta(text, numeric, text, text, uuid)
  from public, anon;
grant execute on function public.registrar_cobro_venta(text, numeric, text, text, uuid)
  to authenticated, service_role;
