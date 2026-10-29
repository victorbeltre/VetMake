-- VetMake · Facturas armadas desde ventas: guardar y editar sin duplicar
--
-- Problema (AI_HANDOFF 2026-10-23): una factura que nace de las ventas tiene un
-- id derivado ("venta_YYYY-MM-DD_mascota") que no existe en la base. Al
-- editarla, el frontend la mandaba a crear_factura, que siempre inserta una
-- fila NUEVA con un uuid y sin origen_ref. Si esa factura ya tenía NCF (fila
-- real con origen_ref = "venta_..."), quedaban dos facturas: la del NCF sin los
-- cambios y otra sin NCF con los cambios.
--
-- Arreglo en el servidor (el frontend también se corrigió):
--   · crear_factura guarda origenRef en origen_ref. Si ya existe una factura
--     con ese origen_ref en la clínica, NO inserta: corrige esa misma fila
--     (pasa por actualizar_factura, que exige admin y respeta el NCF).
--   · actualizar_factura acepta origenRef para seguir el id derivado cuando
--     cambia la fecha o la mascota de la factura.

create or replace function private.crear_factura(factura jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  usuario uuid := (select auth.uid());
  negocio uuid;
  rol text;
  lineas jsonb := coalesce(factura -> 'items', '[]'::jsonb);
  fecha_factura text := coalesce(nullif(btrim(factura ->> 'fecha'), ''), current_date::text);
  usa_itbis boolean := coalesce((factura ->> 'itbis')::boolean, false);
  origen text := nullif(left(btrim(coalesce(factura ->> 'origenRef', '')), 200), '');
  existente text;
  subtotal_calculado numeric := 0;
  itbis_calculado numeric := 0;
  total_calculado numeric := 0;
  fila public.pc_facturas%rowtype;
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Se requiere una sesión autenticada.';
  end if;

  select membresia.negocio_id, membresia.rol
  into negocio, rol
  from public.usuarios_negocio as membresia
  join public.negocios as clinica on clinica.id = membresia.negocio_id
  where membresia.usuario_id = usuario
    and membresia.activo = true
    and clinica.activo = true;

  if negocio is null or rol not in ('admin', 'caja', 'veterinario') then
    raise exception using errcode = '42501', message = 'Tu rol no puede emitir facturas.';
  end if;

  if factura is null or jsonb_typeof(factura) <> 'object' or pg_column_size(factura) > 262144 then
    raise exception using errcode = '22023', message = 'La factura no es válida o excede el tamaño permitido.';
  end if;

  -- Ya guardada (con o sin NCF): se corrige la misma fila, nunca se duplica.
  if origen is not null then
    select f.id into existente
      from public.pc_facturas f
     where f.negocio_id = negocio and f.origen_ref = origen
     limit 1;
    if existente is not null then
      return private.actualizar_factura(factura || jsonb_build_object('id', existente));
    end if;
  end if;

  if fecha_factura !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception using errcode = '22007', message = 'La fecha de la factura no es válida.';
  end if;
  perform fecha_factura::date;

  if jsonb_typeof(lineas) <> 'array'
     or jsonb_array_length(lineas) = 0
     or jsonb_array_length(lineas) > 100 then
    raise exception using errcode = '22023', message = 'La factura debe contener entre 1 y 100 líneas.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(lineas) as elemento
    where nullif(btrim(elemento ->> 'descripcion'), '') is null
      or coalesce((elemento ->> 'cantidad')::numeric, 0) <= 0
      or coalesce((elemento ->> 'precio')::numeric, -1) < 0
      or coalesce((elemento ->> 'descuento')::numeric, 0) not between 0 and 100
  ) then
    raise exception using errcode = '22023', message = 'Hay líneas de factura incompletas o con valores inválidos.';
  end if;

  select coalesce(sum(
    round(
      (elemento ->> 'precio')::numeric
      * (elemento ->> 'cantidad')::numeric
      * (1 - coalesce((elemento ->> 'descuento')::numeric, 0) / 100)
    )
  ), 0)
  into subtotal_calculado
  from jsonb_array_elements(lineas) as elemento;

  itbis_calculado := case when usa_itbis then round(subtotal_calculado * 0.18) else 0 end;
  total_calculado := subtotal_calculado + itbis_calculado;

  insert into public.pc_facturas (
    id, negocio_id, numero, fecha, mascota, propietario, telefono, items, metodopago, estado,
    itbis, subtotal, itbisamt, total, notas, clienteid, autogenerada, emitida_por, origen_ref
  ) values (
    gen_random_uuid()::text,
    negocio,
    null,
    fecha_factura,
    left(coalesce(factura ->> 'mascota', ''), 120),
    left(coalesce(factura ->> 'propietario', ''), 160),
    left(coalesce(factura ->> 'telefono', ''), 35),
    lineas,
    left(coalesce(nullif(factura ->> 'metodoPago', ''), 'Efectivo'), 50),
    case
      when factura ->> 'estado' in ('pagada', 'pendiente', 'anulada') then factura ->> 'estado'
      else 'pagada'
    end,
    usa_itbis,
    subtotal_calculado,
    itbis_calculado,
    total_calculado,
    left(coalesce(factura ->> 'notas', ''), 2000),
    nullif(left(coalesce(factura ->> 'clienteId', ''), 120), ''),
    false,
    usuario,
    origen
  )
  returning * into fila;

  return to_jsonb(fila);
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception using errcode = '22023', message = 'La factura contiene cantidades o precios inválidos.';
  when unique_violation then
    raise exception using errcode = '23505', message = 'Esa factura ya se guardó desde otro dispositivo. Recarga la lista.';
end;
$function$;

create or replace function private.actualizar_factura(factura jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  usuario uuid := (select auth.uid());
  negocio uuid;
  rol text;
  factura_id text;
  lineas jsonb;
  fecha_factura text;
  usa_itbis boolean;
  origen text := nullif(left(btrim(coalesce(factura ->> 'origenRef', '')), 200), '');
  subtotal_calculado numeric := 0;
  itbis_calculado numeric := 0;
  total_calculado numeric := 0;
  fila public.pc_facturas%rowtype;
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Se requiere una sesión autenticada.';
  end if;

  if factura is null or jsonb_typeof(factura) <> 'object' or pg_column_size(factura) > 262144 then
    raise exception using errcode = '22023', message = 'La corrección no es válida o excede el tamaño permitido.';
  end if;

  factura_id := nullif(btrim(factura ->> 'id'), '');
  if factura_id is null then
    raise exception using errcode = '22023', message = 'Falta identificar la factura que se corregirá.';
  end if;

  select membresia.negocio_id, membresia.rol
  into negocio, rol
  from public.usuarios_negocio as membresia
  join public.negocios as clinica on clinica.id = membresia.negocio_id
  where membresia.usuario_id = usuario
    and membresia.activo = true
    and clinica.activo = true;

  if negocio is null or rol <> 'admin' then
    raise exception using errcode = '42501', message = 'Solo un administrador puede corregir facturas emitidas.';
  end if;

  select factura_actual.*
  into fila
  from public.pc_facturas as factura_actual
  where factura_actual.id = factura_id
    and factura_actual.negocio_id = negocio
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'La factura no existe en este negocio.';
  end if;

  if fila.estado = 'anulada' then
    raise exception using errcode = '22023', message = 'Una factura anulada no puede modificarse.';
  end if;

  lineas := coalesce(factura -> 'items', '[]'::jsonb);
  fecha_factura := coalesce(nullif(btrim(factura ->> 'fecha'), ''), fila.fecha);
  usa_itbis := coalesce((factura ->> 'itbis')::boolean, false);

  if fecha_factura !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception using errcode = '22007', message = 'La fecha de la factura no es válida.';
  end if;
  perform fecha_factura::date;

  if jsonb_typeof(lineas) <> 'array'
     or jsonb_array_length(lineas) = 0
     or jsonb_array_length(lineas) > 100 then
    raise exception using errcode = '22023', message = 'La factura debe contener entre 1 y 100 líneas.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(lineas) as elemento
    where nullif(btrim(elemento ->> 'descripcion'), '') is null
      or coalesce((elemento ->> 'cantidad')::numeric, 0) <= 0
      or coalesce((elemento ->> 'precio')::numeric, -1) < 0
      or coalesce((elemento ->> 'descuento')::numeric, 0) not between 0 and 100
  ) then
    raise exception using errcode = '22023', message = 'Hay líneas de factura incompletas o con valores inválidos.';
  end if;

  if coalesce(factura ->> 'estado', '') not in ('pagada', 'pendiente') then
    raise exception using errcode = '22023', message = 'El estado de pago no es válido.';
  end if;

  select coalesce(sum(
    round(
      (elemento ->> 'precio')::numeric
      * (elemento ->> 'cantidad')::numeric
      * (1 - coalesce((elemento ->> 'descuento')::numeric, 0) / 100)
    )
  ), 0)
  into subtotal_calculado
  from jsonb_array_elements(lineas) as elemento;

  itbis_calculado := case when usa_itbis then round(subtotal_calculado * 0.18) else 0 end;
  total_calculado := subtotal_calculado + itbis_calculado;

  update public.pc_facturas
  set fecha = fecha_factura,
      mascota = left(coalesce(factura ->> 'mascota', ''), 120),
      propietario = left(coalesce(factura ->> 'propietario', ''), 160),
      telefono = left(coalesce(factura ->> 'telefono', ''), 35),
      items = lineas,
      metodopago = left(coalesce(nullif(factura ->> 'metodoPago', ''), 'Efectivo'), 50),
      estado = factura ->> 'estado',
      itbis = usa_itbis,
      subtotal = subtotal_calculado,
      itbisamt = itbis_calculado,
      total = total_calculado,
      notas = left(coalesce(factura ->> 'notas', ''), 2000),
      clienteid = nullif(left(coalesce(factura ->> 'clienteId', ''), 120), ''),
      -- Sigue al id derivado de las ventas si cambió la fecha o la mascota.
      origen_ref = case when fila.origen_ref is not null and origen like 'venta\_%' then origen else fila.origen_ref end
  where id = factura_id
    and negocio_id = negocio
  returning * into fila;

  return to_jsonb(fila);
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception using errcode = '22023', message = 'La factura contiene cantidades o precios inválidos.';
  when unique_violation then
    raise exception using errcode = '23505', message = 'Ya hay otra factura guardada para esa fecha y mascota.';
end;
$function$;
