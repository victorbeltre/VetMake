-- Correcciones, anulaciones e importaciones críticas confirmadas por servidor.
--
-- Las ventas se conservan como documentos contables: se corrigen con motivo o
-- se anulan, pero nunca se borran. Las importaciones históricas de ventas y
-- citas reutilizan las mismas validaciones atómicas que la operación diaria.

alter table public.pc_ventas
  add column if not exists corregida_en timestamptz,
  add column if not exists corregida_por uuid,
  add column if not exists ultima_correccion_motivo text,
  add column if not exists anulada_en timestamptz,
  add column if not exists anulada_por uuid,
  add column if not exists motivo_anulacion text;

create index if not exists pc_ventas_negocio_estado_fecha_idx
  on public.pc_ventas (negocio_id, estado, fecha);

create table if not exists private.vetmake_venta_mutaciones (
  negocio_id uuid not null references public.negocios(id) on delete cascade,
  operacion_id uuid not null,
  usuario_id uuid references auth.users(id) on delete set null,
  accion text not null check (accion in ('corregir', 'anular')),
  solicitud jsonb not null,
  resultado jsonb,
  creada_en timestamptz not null default statement_timestamp(),
  primary key (negocio_id, operacion_id)
);

revoke all on table private.vetmake_venta_mutaciones
  from public, anon, authenticated;

create index if not exists vetmake_venta_mutaciones_creada_idx
  on private.vetmake_venta_mutaciones (creada_en);

create or replace function private.corregir_venta_impl(
  p_venta jsonb,
  p_motivo text,
  p_operacion_id uuid
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
  operacion private.vetmake_venta_mutaciones%rowtype;
  solicitud_actual jsonb;
  fila public.pc_ventas%rowtype;
  venta_id text;
  motivo text := btrim(coalesce(p_motivo, ''));
  fecha_texto text;
  fecha_valida date;
  cliente_valor text;
  area_valor text;
  servicio_valor text;
  total_valor numeric;
  comision_valor numeric;
  descuento_valor numeric;
  abonado_real numeric := 0;
  items_valor jsonb;
  respuesta jsonb;
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Debes iniciar sesión para corregir una venta.';
  end if;
  if p_operacion_id is null then
    raise exception using errcode = '22023', message = 'Falta el identificador idempotente de la corrección.';
  end if;
  if p_venta is null or jsonb_typeof(p_venta) <> 'object' or pg_column_size(p_venta) > 262144 then
    raise exception using errcode = '22023', message = 'La corrección de la venta no es válida.';
  end if;
  if char_length(motivo) < 5 or char_length(motivo) > 500 then
    raise exception using errcode = '22023', message = 'Indica un motivo de corrección de 5 a 500 caracteres.';
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

  if negocio is null or rol <> 'admin' then
    raise exception using errcode = '42501', message = 'Solo un administrador puede corregir ventas.';
  end if;

  solicitud_actual := jsonb_build_object('venta', p_venta, 'motivo', motivo);
  insert into private.vetmake_venta_mutaciones (
    negocio_id, operacion_id, usuario_id, accion, solicitud
  ) values (
    negocio, p_operacion_id, usuario, 'corregir', solicitud_actual
  )
  on conflict (negocio_id, operacion_id) do nothing;

  select registro.*
  into operacion
  from private.vetmake_venta_mutaciones as registro
  where registro.negocio_id = negocio
    and registro.operacion_id = p_operacion_id
  for update;

  if not found or operacion.usuario_id is distinct from usuario then
    raise exception using errcode = '42501', message = 'La corrección pertenece a otro usuario.';
  end if;
  if operacion.accion <> 'corregir' or operacion.solicitud is distinct from solicitud_actual then
    raise exception using errcode = '22023', message = 'El identificador de corrección ya fue usado con otros datos.';
  end if;
  if operacion.resultado is not null then
    return operacion.resultado;
  end if;

  venta_id := nullif(btrim(coalesce(p_venta ->> 'id', '')), '');
  if venta_id is null then
    raise exception using errcode = '22023', message = 'Falta identificar la venta que se corregirá.';
  end if;

  select venta.*
  into fila
  from public.pc_ventas as venta
  where venta.negocio_id = negocio
    and venta.id = venta_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'La venta no existe en este negocio.';
  end if;
  if fila.estado = 'anulada' then
    raise exception using errcode = '22023', message = 'Una venta anulada no puede corregirse.';
  end if;

  fecha_texto := btrim(coalesce(p_venta ->> 'fecha', fila.fecha, ''));
  if fecha_texto !~ '^\d{4}-\d{2}-\d{2}$' then
    raise exception using errcode = '22007', message = 'La fecha de la venta debe usar YYYY-MM-DD.';
  end if;
  begin
    fecha_valida := fecha_texto::date;
  exception when others then
    raise exception using errcode = '22007', message = 'La fecha de la venta no existe.';
  end;
  if fecha_valida::text <> fecha_texto
     or fecha_valida > ((statement_timestamp() at time zone zona)::date) then
    raise exception using errcode = '22007', message = 'La fecha de la venta no es válida o está en el futuro.';
  end if;

  cliente_valor := left(btrim(coalesce(p_venta ->> 'cliente', fila.cliente, '')), 180);
  if cliente_valor = '' then
    raise exception using errcode = '22023', message = 'Falta el cliente o la mascota de la venta.';
  end if;

  area_valor := lower(btrim(coalesce(p_venta ->> 'area', fila.area, '')));
  if area_valor not in ('grooming', 'veterinaria', 'farmacia', 'tienda', 'mixta') then
    raise exception using errcode = '22023', message = 'El área de la venta no es válida.';
  end if;

  servicio_valor := left(btrim(coalesce(
    nullif(p_venta ->> 'servicio', ''),
    nullif(p_venta ->> 'descripcion', ''),
    fila.servicio,
    fila.descripcion,
    area_valor
  )), 1000);

  begin
    total_valor := round(coalesce(nullif(p_venta ->> 'total', '')::numeric, fila.total, 0), 2);
    comision_valor := round(coalesce(nullif(p_venta ->> 'comision', '')::numeric, fila.comision, 0), 2);
    descuento_valor := round(coalesce(nullif(p_venta ->> 'descuento', '')::numeric, fila.descuento, 0), 2);
  exception when invalid_text_representation or numeric_value_out_of_range then
    raise exception using errcode = '22023', message = 'Los montos de la venta no son válidos.';
  end;

  if total_valor < 0 or total_valor > 1000000000
     or descuento_valor < 0 or descuento_valor > 1000000000
     or comision_valor < 0
     or comision_valor > greatest(total_valor + descuento_valor, total_valor, 0) then
    raise exception using errcode = '22023', message = 'Los montos de la venta están fuera de rango.';
  end if;

  if jsonb_typeof(coalesce(fila.abonos, '[]'::jsonb)) <> 'array' then
    raise exception using errcode = '22023', message = 'El historial de cobros de la venta está dañado.';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(coalesce(fila.abonos, '[]'::jsonb)) as abono
    where coalesce(abono ->> 'monto', '') !~ '^[0-9]+([.][0-9]+)?$'
  ) then
    raise exception using errcode = '22023', message = 'El historial de cobros contiene un monto inválido.';
  end if;
  select greatest(
    coalesce(fila.abonado, 0),
    coalesce(sum((abono ->> 'monto')::numeric), 0)
  )
  into abonado_real
  from jsonb_array_elements(coalesce(fila.abonos, '[]'::jsonb)) as abono;

  if total_valor < abonado_real then
    raise exception using errcode = '22023', message = 'El total corregido no puede ser menor que lo ya cobrado.';
  end if;

  items_valor := case
    when p_venta ? 'items' then coalesce(p_venta -> 'items', '[]'::jsonb)
    else coalesce(fila.items, '[]'::jsonb)
  end;
  if jsonb_typeof(items_valor) <> 'array'
     or jsonb_array_length(items_valor) > 100
     or pg_column_size(items_valor) > 262144 then
    raise exception using errcode = '22023', message = 'El detalle de la venta no es válido.';
  end if;

  update public.pc_ventas
  set fecha = fecha_texto,
      cliente = cliente_valor,
      area = area_valor,
      servicio = servicio_valor,
      descripcion = servicio_valor,
      total = total_valor,
      comision = comision_valor,
      descuento = descuento_valor,
      items = items_valor,
      corregida_en = statement_timestamp(),
      corregida_por = usuario,
      ultima_correccion_motivo = motivo
  where negocio_id = negocio
    and id = venta_id
  returning * into fila;

  respuesta := jsonb_build_object(
    'operacionId', p_operacion_id,
    'venta', to_jsonb(fila)
  );
  update private.vetmake_venta_mutaciones
  set resultado = respuesta
  where negocio_id = negocio
    and operacion_id = p_operacion_id;

  return respuesta;
end;
$$;

create or replace function private.anular_venta_impl(
  p_venta_id text,
  p_motivo text,
  p_operacion_id uuid
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
  venta_id text := nullif(btrim(coalesce(p_venta_id, '')), '');
  motivo text := btrim(coalesce(p_motivo, ''));
  solicitud_actual jsonb;
  operacion private.vetmake_venta_mutaciones%rowtype;
  fila public.pc_ventas%rowtype;
  ajuste jsonb;
  ajuste_id text;
  ajuste_cantidad numeric;
  producto public.pc_inventario%rowtype;
  inventario_resultado jsonb := '[]'::jsonb;
  paquete public.pc_paquetes%rowtype;
  paquete_resultado jsonb := null;
  respuesta jsonb;
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Debes iniciar sesión para anular una venta.';
  end if;
  if p_operacion_id is null or venta_id is null then
    raise exception using errcode = '22023', message = 'Faltan datos para anular la venta.';
  end if;
  if char_length(motivo) < 5 or char_length(motivo) > 500 then
    raise exception using errcode = '22023', message = 'Indica un motivo de anulación de 5 a 500 caracteres.';
  end if;

  select membresia.negocio_id, membresia.rol
  into negocio, rol
  from public.usuarios_negocio as membresia
  join public.negocios as clinica on clinica.id = membresia.negocio_id
  where membresia.usuario_id = usuario
    and membresia.activo = true
    and clinica.activo = true;

  if negocio is null or rol <> 'admin' then
    raise exception using errcode = '42501', message = 'Solo un administrador puede anular ventas.';
  end if;

  solicitud_actual := jsonb_build_object('ventaId', venta_id, 'motivo', motivo);
  insert into private.vetmake_venta_mutaciones (
    negocio_id, operacion_id, usuario_id, accion, solicitud
  ) values (
    negocio, p_operacion_id, usuario, 'anular', solicitud_actual
  )
  on conflict (negocio_id, operacion_id) do nothing;

  select registro.*
  into operacion
  from private.vetmake_venta_mutaciones as registro
  where registro.negocio_id = negocio
    and registro.operacion_id = p_operacion_id
  for update;

  if not found or operacion.usuario_id is distinct from usuario then
    raise exception using errcode = '42501', message = 'La anulación pertenece a otro usuario.';
  end if;
  if operacion.accion <> 'anular' or operacion.solicitud is distinct from solicitud_actual then
    raise exception using errcode = '22023', message = 'El identificador de anulación ya fue usado con otros datos.';
  end if;
  if operacion.resultado is not null then
    return operacion.resultado;
  end if;

  select venta.*
  into fila
  from public.pc_ventas as venta
  where venta.negocio_id = negocio
    and venta.id = venta_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'La venta no existe en este negocio.';
  end if;

  if fila.estado = 'anulada' then
    respuesta := jsonb_build_object(
      'operacionId', p_operacion_id,
      'venta', to_jsonb(fila),
      'inventario', inventario_resultado,
      'paquete', paquete_resultado
    );
    update private.vetmake_venta_mutaciones
    set resultado = respuesta
    where negocio_id = negocio
      and operacion_id = p_operacion_id;
    return respuesta;
  end if;

  if jsonb_typeof(coalesce(fila.ajustes_inventario, '[]'::jsonb)) <> 'array' then
    raise exception using errcode = '22023', message = 'La trazabilidad de inventario de la venta está dañada.';
  end if;

  for ajuste in
    select value
    from jsonb_array_elements(coalesce(fila.ajustes_inventario, '[]'::jsonb))
  loop
    ajuste_id := btrim(coalesce(ajuste ->> 'id', ''));
    if jsonb_typeof(ajuste) <> 'object'
       or ajuste_id = ''
       or coalesce(ajuste ->> 'cantidad', '') !~ '^[0-9]+([.][0-9]{1,3})?$'
       or (ajuste ->> 'cantidad')::numeric <= 0 then
      raise exception using errcode = '22023', message = 'La trazabilidad de inventario contiene un ajuste inválido.';
    end if;
    ajuste_cantidad := (ajuste ->> 'cantidad')::numeric;

    update public.pc_inventario
    set stock = round(coalesce(stock, 0) + ajuste_cantidad, 3)
    where negocio_id = negocio
      and id = ajuste_id
    returning * into producto;

    if not found then
      raise exception using errcode = 'P0002', message = 'No se puede devolver inventario porque un producto de la venta ya no existe.';
    end if;
    inventario_resultado := inventario_resultado || jsonb_build_array(to_jsonb(producto));
  end loop;

  if fila.paquete_id is not null then
    select plan.*
    into paquete
    from public.pc_paquetes as plan
    where plan.negocio_id = negocio
      and plan.id = fila.paquete_id
    for update;
    if not found then
      raise exception using errcode = 'P0002', message = 'No se puede restaurar el plan consumido porque ya no existe.';
    end if;
    if coalesce(paquete.banosusados, 0) <= 0 then
      raise exception using errcode = '22023', message = 'El plan vinculado no conserva el uso que produjo esta venta.';
    end if;
    update public.pc_paquetes
    set banosusados = greatest(coalesce(banosusados, 0) - 1, 0),
        estado = case
          when coalesce(banosusados, 0) - 1 < coalesce(banostotal, 0) then 'activo'
          else estado
        end
    where negocio_id = negocio
      and id = fila.paquete_id
    returning * into paquete;
    paquete_resultado := to_jsonb(paquete);
  elsif fila.paquete_nuevo_id is not null then
    select plan.*
    into paquete
    from public.pc_paquetes as plan
    where plan.negocio_id = negocio
      and plan.id = fila.paquete_nuevo_id
    for update;
    if not found then
      raise exception using errcode = 'P0002', message = 'El plan creado por esta venta ya no existe.';
    end if;
    if coalesce(paquete.banosusados, 0) > 0 then
      raise exception using errcode = '22023', message = 'El plan ya fue utilizado; corrige sus usos antes de anular la venta.';
    end if;
    update public.pc_paquetes
    set estado = 'cancelado',
        notas = left(concat_ws(E'\n', nullif(notas, ''), '[PLAN CANCELADO] ' || motivo), 2000)
    where negocio_id = negocio
      and id = fila.paquete_nuevo_id
    returning * into paquete;
    paquete_resultado := to_jsonb(paquete);
  end if;

  update public.pc_citas as cita
  set venta_id = null,
      actualizado = statement_timestamp()
  where cita.negocio_id = negocio
    and cita.venta_id = fila.id;

  update public.pc_ventas
  set estado = 'anulada',
      anulada_en = statement_timestamp(),
      anulada_por = usuario,
      motivo_anulacion = motivo
  where negocio_id = negocio
    and id = venta_id
  returning * into fila;

  respuesta := jsonb_build_object(
    'operacionId', p_operacion_id,
    'venta', to_jsonb(fila),
    'inventario', inventario_resultado,
    'paquete', paquete_resultado
  );
  update private.vetmake_venta_mutaciones
  set resultado = respuesta
  where negocio_id = negocio
    and operacion_id = p_operacion_id;

  return respuesta;
end;
$$;

create or replace function private.importar_datos_criticos_impl(
  p_modulo text,
  p_filas jsonb,
  p_operacion_id uuid
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
  modulo text := lower(btrim(coalesce(p_modulo, '')));
  entrada jsonb;
  posicion bigint;
  operacion_hija uuid;
  resultado_fila jsonb;
  resultados jsonb := '[]'::jsonb;
  venta_fila public.pc_ventas%rowtype;
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Debes iniciar sesión para importar datos.';
  end if;
  if p_operacion_id is null then
    raise exception using errcode = '22023', message = 'Falta el identificador idempotente de la importación.';
  end if;
  if modulo not in ('ventas', 'citas') then
    raise exception using errcode = '22023', message = 'Ese módulo no admite importación crítica.';
  end if;
  if p_filas is null
     or jsonb_typeof(p_filas) <> 'array'
     or jsonb_array_length(p_filas) < 1
     or jsonb_array_length(p_filas) > 200
     or pg_column_size(p_filas) > 2097152 then
    raise exception using errcode = '22023', message = 'Cada lote debe contener entre 1 y 200 filas válidas.';
  end if;

  select membresia.negocio_id, membresia.rol
  into negocio, rol
  from public.usuarios_negocio as membresia
  join public.negocios as clinica on clinica.id = membresia.negocio_id
  where membresia.usuario_id = usuario
    and membresia.activo = true
    and clinica.activo = true;

  if negocio is null or rol <> 'admin' then
    raise exception using errcode = '42501', message = 'Solo un administrador puede importar ventas o citas.';
  end if;

  for entrada, posicion in
    select elemento.value, elemento.ordinality
    from jsonb_array_elements(p_filas) with ordinality as elemento(value, ordinality)
  loop
    if jsonb_typeof(entrada) <> 'object' then
      raise exception using errcode = '22023', message = format('La fila %s no tiene un formato válido.', posicion);
    end if;
    operacion_hija := md5(p_operacion_id::text || ':' || modulo || ':' || posicion::text)::uuid;
    begin
      if modulo = 'ventas' then
        resultado_fila := private.registrar_venta_atomica_impl(
          entrada - 'id' - 'negocio_id' - 'created_at',
          '[]'::jsonb,
          null,
          null,
          null,
          operacion_hija
        );
        update public.pc_ventas
        set origen = 'importacion'
        where negocio_id = negocio
          and id = resultado_fila -> 'venta' ->> 'id'
        returning * into venta_fila;
        resultados := resultados || jsonb_build_array(to_jsonb(venta_fila));
      else
        resultado_fila := private.guardar_cita_atomica_impl(
          entrada - 'id' - 'negocio_id' - 'actualizado'
            - 'gcaleventid' - 'gcalEventId' - 'gcalsync' - 'gcalSync'
            - 'venta_id' - 'ventaId',
          operacion_hija
        );
        resultados := resultados || jsonb_build_array(resultado_fila -> 'cita');
      end if;
    exception when others then
      raise exception using
        errcode = sqlstate,
        message = format('Fila %s: %s', posicion, sqlerrm);
    end;
  end loop;

  return jsonb_build_object(
    'operacionId', p_operacion_id,
    'modulo', modulo,
    'cantidad', jsonb_array_length(resultados),
    'filas', resultados
  );
end;
$$;

create or replace function public.corregir_venta(
  p_venta jsonb,
  p_motivo text,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.corregir_venta_impl(p_venta, p_motivo, p_operacion_id);
$$;

create or replace function public.anular_venta(
  p_venta_id text,
  p_motivo text,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.anular_venta_impl(p_venta_id, p_motivo, p_operacion_id);
$$;

create or replace function public.importar_datos_criticos(
  p_modulo text,
  p_filas jsonb,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.importar_datos_criticos_impl(p_modulo, p_filas, p_operacion_id);
$$;

revoke all on function private.corregir_venta_impl(jsonb, text, uuid)
  from public, anon, authenticated;
revoke all on function private.anular_venta_impl(text, text, uuid)
  from public, anon, authenticated;
revoke all on function private.importar_datos_criticos_impl(text, jsonb, uuid)
  from public, anon, authenticated;
revoke all on function public.corregir_venta(jsonb, text, uuid)
  from public, anon;
revoke all on function public.anular_venta(text, text, uuid)
  from public, anon;
revoke all on function public.importar_datos_criticos(text, jsonb, uuid)
  from public, anon;

grant usage on schema private to authenticated, service_role;
grant execute on function private.corregir_venta_impl(jsonb, text, uuid)
  to authenticated, service_role;
grant execute on function private.anular_venta_impl(text, text, uuid)
  to authenticated, service_role;
grant execute on function private.importar_datos_criticos_impl(text, jsonb, uuid)
  to authenticated, service_role;
grant execute on function public.corregir_venta(jsonb, text, uuid)
  to authenticated;
grant execute on function public.anular_venta(text, text, uuid)
  to authenticated;
grant execute on function public.importar_datos_criticos(text, jsonb, uuid)
  to authenticated;

-- Después de migrar todos los flujos del navegador, las tablas financieras y
-- de agenda dejan de aceptar escrituras genéricas por PostgREST. Los RPC
-- anteriores conservan SELECT para la interfaz y realizan las mutaciones como
-- funciones validadas.
revoke insert, update, delete on table public.pc_ventas from authenticated;
revoke insert, update, delete on table public.pc_citas from authenticated;
grant select on table public.pc_ventas, public.pc_citas to authenticated;

comment on function public.corregir_venta(jsonb, text, uuid) is
  'Corrige una venta activa como administrador, exige motivo y conserva cobros, stock y auditoría.';
comment on function public.anular_venta(text, text, uuid) is
  'Anula una venta sin borrarla y revierte de forma transaccional inventario, plan y vínculo de cita.';
comment on function public.importar_datos_criticos(text, jsonb, uuid) is
  'Importa lotes históricos de ventas o citas usando las operaciones atómicas canónicas.';

notify pgrst, 'reload schema';
