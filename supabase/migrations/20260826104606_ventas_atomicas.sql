-- VetMake · registro atómico e idempotente de ventas
--
-- Una venta puede afectar caja, inventario, un plan prepagado y una cita.
-- Todo se confirma en una sola transacción para evitar ventas sin stock,
-- planes consumidos dos veces o citas completadas sin su venta asociada.

create sequence if not exists private.pc_ventas_id_seq as bigint;

select setval(
  'private.pc_ventas_id_seq',
  greatest(
    floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
    coalesce((
      select max(venta.id::bigint) + 1
      from public.pc_ventas as venta
      where venta.id ~ '^[0-9]+$'
    ), 1)
  ),
  false
);

revoke all on sequence private.pc_ventas_id_seq
  from public, anon, authenticated;

create table if not exists private.vetmake_venta_operaciones (
  negocio_id uuid not null references public.negocios(id) on delete cascade,
  operacion_id uuid not null,
  usuario_id uuid references auth.users(id) on delete set null,
  solicitud jsonb not null,
  resultado jsonb,
  creada_en timestamptz not null default statement_timestamp(),
  primary key (negocio_id, operacion_id)
);

revoke all on table private.vetmake_venta_operaciones
  from public, anon, authenticated;

alter table public.pc_citas
  add column if not exists venta_id text;

alter table public.pc_ventas
  add column if not exists estado text not null default 'activa',
  add column if not exists ajustes_inventario jsonb not null default '[]'::jsonb,
  add column if not exists paquete_id text,
  add column if not exists paquete_nuevo_id text,
  add column if not exists origen text;

-- Las ventas que ya existían antes de esta migración son históricas. Las
-- nuevas se marcan como operaciones normales; el RPC de importación cambia el
-- origen a "importacion" después de registrar cada fila.
update public.pc_ventas
set origen = 'legacy'
where origen is null;

alter table public.pc_ventas
  alter column origen set default 'operacion',
  alter column origen set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'pc_ventas_estado_check'
      and conrelid = 'public.pc_ventas'::regclass
  ) then
    alter table public.pc_ventas
      add constraint pc_ventas_estado_check
      check (estado in ('activa', 'anulada'));
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'pc_ventas_origen_check'
      and conrelid = 'public.pc_ventas'::regclass
  ) then
    alter table public.pc_ventas
      add constraint pc_ventas_origen_check
      check (origen in ('operacion', 'importacion', 'legacy'));
  end if;
end;
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'pc_ventas_negocio_id_id_key'
      and conrelid = 'public.pc_ventas'::regclass
  ) then
    alter table public.pc_ventas
      add constraint pc_ventas_negocio_id_id_key unique (negocio_id, id);
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'pc_citas_venta_negocio_fkey'
      and conrelid = 'public.pc_citas'::regclass
  ) then
    alter table public.pc_citas
      add constraint pc_citas_venta_negocio_fkey
      foreign key (negocio_id, venta_id)
      references public.pc_ventas (negocio_id, id)
      on update cascade
      on delete restrict;
  end if;
end;
$$;

create unique index if not exists pc_citas_venta_id_unica_idx
  on public.pc_citas (negocio_id, venta_id)
  where venta_id is not null;

create index if not exists vetmake_venta_operaciones_creada_idx
  on private.vetmake_venta_operaciones (creada_en);

create or replace function private.registrar_venta_atomica_impl(
  p_venta jsonb,
  p_ajustes_inventario jsonb default '[]'::jsonb,
  p_paquete_id text default null,
  p_paquete_nuevo jsonb default null,
  p_cita_id bigint default null,
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
  operacion uuid := coalesce(p_operacion_id, gen_random_uuid());
  solicitud_actual jsonb;
  solicitud_guardada jsonb;
  resultado_guardado jsonb;
  nueva_venta_id text;
  fecha_venta date;
  cliente text;
  area text;
  servicio text;
  total numeric;
  comision numeric;
  descuento numeric;
  forma_pago text;
  recibido_por text;
  cobrado_por text;
  empleado_id text;
  empleado_actual public.pc_empleados%rowtype;
  items jsonb;
  abonos_entrada jsonb;
  abonos_normalizados jsonb := '[]'::jsonb;
  abonado numeric := 0;
  fecha_recordatorio text;
  ajuste jsonb;
  ajuste_id text;
  ajuste_cantidad numeric;
  inventario_actualizado jsonb := '[]'::jsonb;
  ajustes_aplicados jsonb := '[]'::jsonb;
  inventario_fila public.pc_inventario%rowtype;
  paquete_fila public.pc_paquetes%rowtype;
  paquete_resultado jsonb := null;
  cita_fila public.pc_citas%rowtype;
  cita_resultado jsonb := null;
  venta_fila public.pc_ventas%rowtype;
  movimiento jsonb;
  movimiento_monto numeric;
  movimiento_indice integer := 0;
  notas text;
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Se requiere una sesión autenticada.';
  end if;

  select membresia.negocio_id,
         membresia.rol,
         coalesce(clinica.zona_horaria, 'America/Santo_Domingo')
  into negocio, rol, zona
  from public.usuarios_negocio as membresia
  join public.negocios as clinica on clinica.id = membresia.negocio_id
  where membresia.usuario_id = usuario
    and membresia.activo = true
    and clinica.activo = true;

  if negocio is null or rol not in ('admin', 'caja', 'veterinario', 'groomer') then
    raise exception using errcode = '42501', message = 'Tu rol no puede registrar ventas.';
  end if;

  if p_venta is null or jsonb_typeof(p_venta) <> 'object' then
    raise exception using errcode = '22023', message = 'Los datos de la venta no son válidos.';
  end if;

  if p_ajustes_inventario is null then
    p_ajustes_inventario := '[]'::jsonb;
  end if;
  if jsonb_typeof(p_ajustes_inventario) <> 'array'
     or jsonb_array_length(p_ajustes_inventario) > 100 then
    raise exception using errcode = '22023', message = 'Los ajustes de inventario no son válidos.';
  end if;

  if p_paquete_nuevo is not null and jsonb_typeof(p_paquete_nuevo) <> 'object' then
    raise exception using errcode = '22023', message = 'El plan prepagado no es válido.';
  end if;
  if nullif(btrim(coalesce(p_paquete_id, '')), '') is not null
     and p_paquete_nuevo is not null then
    raise exception using errcode = '22023', message = 'No se puede vender y consumir un plan en la misma operación.';
  end if;

  solicitud_actual := jsonb_build_object(
    'venta', p_venta,
    'ajustesInventario', p_ajustes_inventario,
    'paqueteId', nullif(btrim(coalesce(p_paquete_id, '')), ''),
    'paqueteNuevo', p_paquete_nuevo,
    'citaId', p_cita_id
  );

  insert into private.vetmake_venta_operaciones (
    negocio_id, operacion_id, usuario_id, solicitud
  ) values (
    negocio, operacion, usuario, solicitud_actual
  )
  on conflict (negocio_id, operacion_id) do nothing;

  select registro.solicitud, registro.resultado
  into solicitud_guardada, resultado_guardado
  from private.vetmake_venta_operaciones as registro
  where registro.negocio_id = negocio
    and registro.operacion_id = operacion
    and registro.usuario_id = usuario
  for update;

  if not found then
    raise exception using errcode = '42501', message = 'La operación pertenece a otro usuario.';
  end if;
  if solicitud_guardada is distinct from solicitud_actual then
    raise exception using errcode = '22023', message = 'El identificador de operación ya fue usado con otros datos.';
  end if;
  if resultado_guardado is not null then
    return resultado_guardado;
  end if;

  begin
    fecha_venta := nullif(btrim(coalesce(p_venta ->> 'fecha', '')), '')::date;
  exception when others then
    raise exception using errcode = '22007', message = 'La fecha de la venta no es válida.';
  end;
  if fecha_venta is null then
    raise exception using errcode = '22007', message = 'Falta la fecha de la venta.';
  end if;
  if fecha_venta > ((statement_timestamp() at time zone zona)::date) then
    raise exception using errcode = '22007', message = 'No se pueden registrar ventas con fecha futura.';
  end if;

  cliente := left(btrim(coalesce(p_venta ->> 'cliente', '')), 180);
  if cliente = '' then
    raise exception using errcode = '22023', message = 'Falta el cliente o la mascota de la venta.';
  end if;

  area := lower(btrim(coalesce(p_venta ->> 'area', '')));
  if area not in ('grooming', 'veterinaria', 'farmacia', 'tienda', 'mixta') then
    raise exception using errcode = '22023', message = 'El área de la venta no es válida.';
  end if;

  servicio := left(btrim(coalesce(
    nullif(p_venta ->> 'servicio', ''),
    nullif(p_venta ->> 'descripcion', ''),
    area
  )), 1000);

  begin
    total := round(coalesce(nullif(p_venta ->> 'total', '')::numeric, 0), 2);
    comision := round(coalesce(nullif(p_venta ->> 'comision', '')::numeric, 0), 2);
    descuento := round(coalesce(nullif(p_venta ->> 'descuento', '')::numeric, 0), 2);
  exception when invalid_text_representation or numeric_value_out_of_range then
    raise exception using errcode = '22023', message = 'Los montos de la venta no son válidos.';
  end;

  if total < 0 or total > 1000000000 then
    raise exception using errcode = '22023', message = 'El total de la venta no es válido.';
  end if;
  if comision < 0 or comision > greatest(total + descuento, total, 0) then
    raise exception using errcode = '22023', message = 'La comisión de la venta no es válida.';
  end if;
  if descuento < 0 or descuento > 1000000000 then
    raise exception using errcode = '22023', message = 'El descuento de la venta no es válido.';
  end if;

  forma_pago := left(btrim(coalesce(
    nullif(p_venta ->> 'formapago', ''),
    nullif(p_venta ->> 'formaPago', ''),
    'Pago pendiente'
  )), 80);
  recibido_por := left(btrim(coalesce(
    nullif(p_venta ->> 'recibidopor', ''),
    nullif(p_venta ->> 'recibidoPor', ''),
    ''
  )), 180);
  cobrado_por := left(btrim(coalesce(
    nullif(p_venta ->> 'cobradopor', ''),
    nullif(p_venta ->> 'cobradoPor', ''),
    coalesce((select auth.jwt() ->> 'email'), usuario::text)
  )), 180);
  empleado_id := nullif(btrim(coalesce(
    nullif(p_venta ->> 'empleadoid', ''),
    nullif(p_venta ->> 'empleadoId', ''),
    ''
  )), '');

  if empleado_id is not null then
    select empleado.*
    into empleado_actual
    from public.pc_empleados as empleado
    where empleado.negocio_id = negocio
      and empleado.id = empleado_id
      and empleado.activo = true;
    if not found then
      raise exception using errcode = '22023', message = 'El empleado asignado no existe o está inactivo.';
    end if;
  elsif recibido_por <> '' then
    select empleado.*
    into empleado_actual
    from public.pc_empleados as empleado
    where empleado.negocio_id = negocio
      and empleado.activo = true
      and lower(btrim(empleado.nombre)) = lower(recibido_por)
    order by empleado.id
    limit 1;
    if found then
      empleado_id := empleado_actual.id;
    end if;
  end if;

  if rol in ('veterinario', 'groomer') then
    select empleado.*
    into empleado_actual
    from public.pc_empleados as empleado
    where empleado.negocio_id = negocio
      and empleado.usuario_id = usuario
      and empleado.activo = true;
    if not found then
      raise exception using errcode = '42501', message = 'Tu cuenta no está vinculada a un empleado activo.';
    end if;
    empleado_id := empleado_actual.id;
    recibido_por := empleado_actual.nombre;
  end if;

  items := coalesce(p_venta -> 'items', '[]'::jsonb);
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) > 100 then
    raise exception using errcode = '22023', message = 'Las líneas de la venta no son válidas.';
  end if;
  if pg_column_size(items) > 262144 then
    raise exception using errcode = '22023', message = 'El detalle de la venta es demasiado grande.';
  end if;

  abonos_entrada := coalesce(p_venta -> 'abonos', '[]'::jsonb);
  if jsonb_typeof(abonos_entrada) <> 'array' or jsonb_array_length(abonos_entrada) > 20 then
    raise exception using errcode = '22023', message = 'El abono inicial no es válido.';
  end if;

  for movimiento in select value from jsonb_array_elements(abonos_entrada)
  loop
    movimiento_indice := movimiento_indice + 1;
    if jsonb_typeof(movimiento) <> 'object'
       or coalesce(movimiento ->> 'monto', '') !~ '^[0-9]+([.][0-9]{1,2})?$' then
      raise exception using errcode = '22023', message = 'El abono inicial contiene un monto inválido.';
    end if;
    movimiento_monto := round((movimiento ->> 'monto')::numeric, 2);
    if movimiento_monto <= 0 then
      raise exception using errcode = '22023', message = 'El abono inicial debe ser mayor que cero.';
    end if;
    abonado := round(abonado + movimiento_monto, 2);
    abonos_normalizados := abonos_normalizados || jsonb_build_array(jsonb_build_object(
      'id', operacion::text || '-inicial-' || movimiento_indice::text,
      'fecha', fecha_venta::text,
      'monto', movimiento_monto,
      'forma', left(lower(btrim(coalesce(movimiento ->> 'forma', 'efectivo'))), 40),
      'banco', left(btrim(coalesce(movimiento ->> 'banco', '')), 100),
      'por', cobrado_por
    ));
  end loop;

  if abonado > total then
    raise exception using errcode = '22023', message = 'El abono inicial excede el total de la venta.';
  end if;
  if abonado > 0 and abonado < total then
    forma_pago := 'Pago pendiente';
  elsif abonado = total and total > 0 then
    forma_pago := initcap(coalesce(abonos_normalizados -> 0 ->> 'forma', 'Efectivo'));
  end if;

  fecha_recordatorio := nullif(btrim(coalesce(
    p_venta ->> 'fecharecordatorio',
    p_venta ->> 'fechaRecordatorio',
    ''
  )), '');
  if fecha_recordatorio is not null then
    begin
      perform fecha_recordatorio::date;
    exception when others then
      raise exception using errcode = '22007', message = 'La fecha del recordatorio no es válida.';
    end;
  end if;
  if lower(forma_pago) <> 'pago pendiente' then
    fecha_recordatorio := null;
  end if;

  notas := nullif(left(btrim(coalesce(p_venta ->> 'notas', '')), 4000), '');
  nueva_venta_id := nextval('private.pc_ventas_id_seq')::text;

  insert into public.pc_ventas (
    id, fecha, cliente, area, servicio, descripcion, total, comision,
    formapago, recibidopor, empleadoid, cobradopor, descuento, banco,
    items, abonos, abonado, fecharecordatorio, notas, negocio_id
  ) values (
    nueva_venta_id, fecha_venta::text, cliente, area, servicio, servicio, total, comision,
    forma_pago, nullif(recibido_por, ''), empleado_id, nullif(cobrado_por, ''),
    descuento, nullif(left(btrim(coalesce(p_venta ->> 'banco', '')), 100), ''),
    items, abonos_normalizados, abonado, fecha_recordatorio, notas, negocio
  )
  returning * into venta_fila;

  for ajuste in
    select jsonb_build_object(
      'id', grupo.id,
      'cantidad', sum(grupo.cantidad)
    )
    from (
      select btrim(value ->> 'id') as id,
             (value ->> 'cantidad')::numeric as cantidad
      from jsonb_array_elements(p_ajustes_inventario)
      where jsonb_typeof(value) = 'object'
        and coalesce(value ->> 'id', '') <> ''
        and coalesce(value ->> 'cantidad', '') ~ '^[0-9]+([.][0-9]{1,3})?$'
    ) as grupo
    group by grupo.id
  loop
    ajuste_id := ajuste ->> 'id';
    ajuste_cantidad := (ajuste ->> 'cantidad')::numeric;
    if ajuste_cantidad <= 0 then
      raise exception using errcode = '22023', message = 'La cantidad de inventario debe ser mayor que cero.';
    end if;

    select producto.*
    into inventario_fila
    from public.pc_inventario as producto
    where producto.negocio_id = negocio
      and producto.id = ajuste_id
    for update;

    if not found then
      raise exception using errcode = 'P0002', message = 'Un producto de la venta ya no existe en el inventario.';
    end if;
    if coalesce(inventario_fila.stock, 0) < ajuste_cantidad then
      raise exception using
        errcode = '22023',
        message = format('Stock insuficiente para %s. Disponible: %s.', inventario_fila.nombre, coalesce(inventario_fila.stock, 0));
    end if;

    update public.pc_inventario
    set stock = round(coalesce(stock, 0) - ajuste_cantidad, 3)
    where negocio_id = negocio
      and id = ajuste_id
    returning * into inventario_fila;

    inventario_actualizado := inventario_actualizado || jsonb_build_array(to_jsonb(inventario_fila));
    ajustes_aplicados := ajustes_aplicados || jsonb_build_array(jsonb_build_object(
      'id', ajuste_id,
      'cantidad', ajuste_cantidad
    ));
  end loop;

  -- Si había entradas mal formadas no deben ignorarse silenciosamente.
  if jsonb_array_length(p_ajustes_inventario) <> (
    select count(*)
    from jsonb_array_elements(p_ajustes_inventario) as entrada
    where jsonb_typeof(entrada) = 'object'
      and coalesce(entrada ->> 'id', '') <> ''
      and coalesce(entrada ->> 'cantidad', '') ~ '^[0-9]+([.][0-9]{1,3})?$'
      and (entrada ->> 'cantidad')::numeric > 0
  ) then
    raise exception using errcode = '22023', message = 'Un ajuste de inventario está incompleto.';
  end if;

  if nullif(btrim(coalesce(p_paquete_id, '')), '') is not null then
    select paquete.*
    into paquete_fila
    from public.pc_paquetes as paquete
    where paquete.negocio_id = negocio
      and paquete.id = btrim(p_paquete_id)
    for update;

    if not found then
      raise exception using errcode = 'P0002', message = 'El plan prepagado no existe en este negocio.';
    end if;
    if paquete_fila.estado <> 'activo'
       or coalesce(paquete_fila.banosusados, 0) >= coalesce(paquete_fila.banostotal, 0) then
      raise exception using errcode = '22023', message = 'El plan prepagado ya no tiene servicios disponibles.';
    end if;
    if nullif(paquete_fila.vence, '') is not null and paquete_fila.vence::date < fecha_venta then
      raise exception using errcode = '22023', message = 'El plan prepagado está vencido.';
    end if;

    update public.pc_paquetes
    set banosusados = coalesce(banosusados, 0) + 1,
        estado = case
          when coalesce(banosusados, 0) + 1 >= coalesce(banostotal, 0) then 'agotado'
          else estado
        end
    where negocio_id = negocio
      and id = paquete_fila.id
    returning * into paquete_fila;
    paquete_resultado := to_jsonb(paquete_fila);
  elsif p_paquete_nuevo is not null then
    if coalesce(p_paquete_nuevo ->> 'banostotal', '') !~ '^[0-9]+([.][0-9]+)?$'
       or (p_paquete_nuevo ->> 'banostotal')::numeric < 1
       or (p_paquete_nuevo ->> 'banostotal')::numeric > 100 then
      raise exception using errcode = '22023', message = 'La cantidad de servicios del plan no es válida.';
    end if;

    insert into public.pc_paquetes (
      id, mascota, clienteid, nombre, banostotal, banosusados,
      precio, fecha, vence, estado, notas, negocio_id
    ) values (
      nueva_venta_id || '-plan',
      left(btrim(coalesce(p_paquete_nuevo ->> 'mascota', cliente)), 180),
      nullif(left(btrim(coalesce(p_paquete_nuevo ->> 'clienteid', '')), 120), ''),
      left(btrim(coalesce(p_paquete_nuevo ->> 'nombre', 'Plan prepagado')), 240),
      (p_paquete_nuevo ->> 'banostotal')::numeric,
      0,
      total,
      fecha_venta::text,
      nullif(btrim(coalesce(p_paquete_nuevo ->> 'vence', '')), ''),
      'activo',
      nullif(left(btrim(coalesce(p_paquete_nuevo ->> 'notas', '')), 2000), ''),
      negocio
    )
    returning * into paquete_fila;

    if nullif(paquete_fila.vence, '') is not null then
      begin
        perform paquete_fila.vence::date;
      exception when others then
        raise exception using errcode = '22007', message = 'La fecha de vencimiento del plan no es válida.';
      end;
      if paquete_fila.vence::date < fecha_venta then
        raise exception using errcode = '22007', message = 'El plan no puede vencer antes de su venta.';
      end if;
    end if;
    paquete_resultado := to_jsonb(paquete_fila);
  end if;

  -- La venta conserva el efecto lateral exacto que produjo. Una anulación
  -- posterior puede devolver stock o restaurar el plan sin inferir datos desde
  -- descripciones editables del recibo.
  update public.pc_ventas
  set ajustes_inventario = ajustes_aplicados,
      paquete_id = nullif(btrim(coalesce(p_paquete_id, '')), ''),
      paquete_nuevo_id = case when p_paquete_nuevo is null then null else nueva_venta_id || '-plan' end
  where negocio_id = negocio
    and id = nueva_venta_id
  returning * into venta_fila;

  if p_cita_id is not null then
    select cita.*
    into cita_fila
    from public.pc_citas as cita
    where cita.negocio_id = negocio
      and cita.id = p_cita_id
    for update;

    if not found then
      raise exception using errcode = 'P0002', message = 'La cita ya no existe en este negocio.';
    end if;
    if cita_fila.venta_id is not null and cita_fila.venta_id <> nueva_venta_id then
      raise exception using errcode = '23505', message = 'La cita ya tiene una venta registrada.';
    end if;
    if cita_fila.estado in ('cancelada', 'noshow') then
      raise exception using errcode = '22023', message = 'No se puede cobrar una cita cancelada o marcada como no-show.';
    end if;

    update public.pc_citas
    set estado = 'completada',
        venta_id = nueva_venta_id,
        actualizado = statement_timestamp()
    where negocio_id = negocio
      and id = cita_fila.id
    returning * into cita_fila;
    cita_resultado := to_jsonb(cita_fila);
  end if;

  resultado_guardado := jsonb_build_object(
    'venta', to_jsonb(venta_fila),
    'inventario', inventario_actualizado,
    'paquete', paquete_resultado,
    'cita', cita_resultado,
    'operacionId', operacion::text
  );

  update private.vetmake_venta_operaciones
  set resultado = resultado_guardado
  where negocio_id = negocio
    and operacion_id = operacion;

  return resultado_guardado;
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception using errcode = '22023', message = 'La venta contiene un número o una fecha inválidos.';
end;
$$;

revoke all on function private.registrar_venta_atomica_impl(jsonb, jsonb, text, jsonb, bigint, uuid)
  from public, anon;
grant execute on function private.registrar_venta_atomica_impl(jsonb, jsonb, text, jsonb, bigint, uuid)
  to authenticated, service_role;
grant usage on schema private to authenticated, service_role;

create or replace function public.registrar_venta_atomica(
  p_venta jsonb,
  p_ajustes_inventario jsonb default '[]'::jsonb,
  p_paquete_id text default null,
  p_paquete_nuevo jsonb default null,
  p_cita_id bigint default null,
  p_operacion_id uuid default gen_random_uuid()
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.registrar_venta_atomica_impl(
    p_venta,
    p_ajustes_inventario,
    p_paquete_id,
    p_paquete_nuevo,
    p_cita_id,
    p_operacion_id
  );
$$;

revoke all on function public.registrar_venta_atomica(jsonb, jsonb, text, jsonb, bigint, uuid)
  from public, anon;
grant execute on function public.registrar_venta_atomica(jsonb, jsonb, text, jsonb, bigint, uuid)
  to authenticated, service_role;

notify pgrst, 'reload schema';
