-- VetMake · catálogo de servicios y tarifas atómico
--
-- Conserva las tarifas existentes, normaliza la comisión veterinaria como
-- porcentaje 0..100 y centraliza altas, ediciones, importaciones y retiros en
-- PostgreSQL. El Data API autenticado queda de solo lectura para pc_tarifas.

-- ─── 1. Esquema canónico y trazabilidad ─────────────────────────────────

alter table public.pc_tarifas
  add column if not exists activo boolean not null default true,
  add column if not exists updated_at timestamptz not null default now();

-- El frontend histórico interpretaba 0.30 como 30 % y los valores mayores a
-- 1 como porcentaje entero. Desde esta migración se guarda siempre 0..100.
update public.pc_tarifas
set comision = case
      when area = 'vet' and comision between 0 and 1 then comision * 100
      else coalesce(comision, 0)
    end,
    activo = coalesce(activo, true),
    updated_at = coalesce(updated_at, now());

update public.pc_tarifas
set nombre = btrim(nombre),
    area = lower(btrim(area)),
    precio = coalesce(precio, 0),
    comision = coalesce(comision, 0);

alter table public.pc_tarifas
  alter column nombre set not null,
  alter column precio set not null,
  alter column comision set not null,
  alter column area set not null;

alter table public.pc_tarifas
  drop constraint if exists pc_tarifas_nombre_chk,
  drop constraint if exists pc_tarifas_area_chk,
  drop constraint if exists pc_tarifas_precio_chk,
  drop constraint if exists pc_tarifas_comision_chk;

alter table public.pc_tarifas
  add constraint pc_tarifas_nombre_chk
    check (nullif(btrim(nombre), '') is not null),
  add constraint pc_tarifas_area_chk
    check (area in ('grooming', 'vet')),
  add constraint pc_tarifas_precio_chk
    check (precio > 0 and precio <= 1000000000000),
  add constraint pc_tarifas_comision_chk
    check (
      (area = 'grooming' and comision between 0 and precio)
      or (area = 'vet' and comision between 0 and 100)
    );

create unique index if not exists pc_tarifas_negocio_area_nombre_uidx
  on public.pc_tarifas (negocio_id, area, lower(btrim(nombre)));

create index if not exists pc_tarifas_negocio_activo_area_idx
  on public.pc_tarifas (negocio_id, activo, area, id);

drop index if exists public.pc_tarifas_negocio_id_idx;

create sequence if not exists private.pc_tarifas_id_seq as bigint start with 1;
revoke all on sequence private.pc_tarifas_id_seq
  from public, anon, authenticated;

do $$
declare
  maximo bigint;
  actual bigint;
begin
  select coalesce(max(substring(id from '^tar_([0-9]+)$')::bigint), 0)
    into maximo
  from public.pc_tarifas
  where id ~ '^tar_[0-9]+$';

  select last_value into actual from private.pc_tarifas_id_seq;
  if maximo = 0 and coalesce(actual, 1) = 1 then
    perform setval('private.pc_tarifas_id_seq'::regclass, 1, false);
  else
    perform setval(
      'private.pc_tarifas_id_seq'::regclass,
      greatest(coalesce(actual, 1), maximo, 1),
      true
    );
  end if;
end
$$;

-- ─── 2. Idempotencia privada ─────────────────────────────────────────────

create table if not exists private.vetmake_tarifas_operaciones (
  negocio_id uuid not null references public.negocios(id) on delete cascade,
  usuario_id uuid not null,
  operacion_id uuid not null,
  accion text not null check (
    accion in ('guardar_tarifas', 'importar_catalogo', 'retirar_tarifa')
  ),
  solicitud_hash text not null check (solicitud_hash ~ '^[0-9a-f]{32}$'),
  resultado jsonb not null,
  created_at timestamptz not null default now(),
  primary key (negocio_id, operacion_id)
);

alter table private.vetmake_tarifas_operaciones enable row level security;
revoke all on table private.vetmake_tarifas_operaciones
  from public, anon, authenticated;

-- ─── 3. Validación y escritura interna ──────────────────────────────────

create or replace function private.guardar_tarifa_fila(
  p_negocio uuid,
  p_tarifa jsonb
)
returns public.pc_tarifas
language plpgsql
security invoker
set search_path = ''
as $$
declare
  datos jsonb := coalesce(p_tarifa, '{}'::jsonb);
  tarifa_id text;
  tarifa_actual public.pc_tarifas%rowtype;
  tarifa_guardada public.pc_tarifas%rowtype;
  nombre_limpio text;
  area_limpia text;
  precio_valor numeric;
  comision_valor numeric;
  intento integer := 0;
  restriccion text;
begin
  if p_negocio is null then
    raise exception using errcode = '42501', message = 'La clínica no es válida.';
  end if;
  if jsonb_typeof(datos) <> 'object' then
    raise exception using errcode = '22023', message = 'La tarifa no tiene un formato válido.';
  end if;
  if octet_length(datos::text) > 32768 then
    raise exception using errcode = '22023', message = 'La tarifa excede el tamaño permitido.';
  end if;

  tarifa_id := nullif(left(btrim(coalesce(datos ->> 'id', '')), 160), '');
  if tarifa_id is not null and tarifa_id !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$' then
    raise exception using errcode = '22023', message = 'La tarifa no tiene un identificador válido.';
  end if;

  if tarifa_id is not null then
    select tarifa.*
      into tarifa_actual
    from public.pc_tarifas as tarifa
    where tarifa.negocio_id = p_negocio
      and tarifa.id = tarifa_id
    for update;

    if not found then
      raise exception using errcode = 'P0002', message = 'La tarifa no existe o pertenece a otra clínica.';
    end if;
    if tarifa_actual.activo = false then
      raise exception using errcode = 'P0002', message = 'La tarifa está retirada. Créala nuevamente para reactivarla.';
    end if;
  end if;

  if datos ? 'nombre' then
    nombre_limpio := nullif(
      left(btrim(regexp_replace(coalesce(datos ->> 'nombre', ''), '[<>]', '', 'g')), 200),
      ''
    );
  elsif tarifa_id is not null then
    nombre_limpio := tarifa_actual.nombre;
  end if;
  if nombre_limpio is null then
    raise exception using errcode = '22023', message = 'El nombre del servicio es obligatorio.';
  end if;

  if datos ? 'area' then
    area_limpia := lower(left(btrim(coalesce(datos ->> 'area', '')), 20));
  elsif tarifa_id is not null then
    area_limpia := tarifa_actual.area;
  end if;
  if area_limpia is null or area_limpia not in ('grooming', 'vet') then
    raise exception using errcode = '22023', message = 'El área debe ser grooming o veterinaria.';
  end if;
  if tarifa_id is not null and area_limpia <> tarifa_actual.area then
    raise exception using errcode = '22023', message = 'El área de una tarifa existente es inmutable.';
  end if;

  if datos ? 'precio' then
    precio_valor := private.inventario_numero(
      datos -> 'precio', 'El precio', null, 1000000000000, 2
    );
  elsif tarifa_id is not null then
    precio_valor := tarifa_actual.precio;
  end if;
  if precio_valor is null or precio_valor <= 0 then
    raise exception using errcode = '22023', message = 'El precio debe ser mayor que cero.';
  end if;

  if datos ? 'comision' then
    comision_valor := private.inventario_numero(
      datos -> 'comision', 'La comisión', null, 1000000000000, 2
    );
  elsif tarifa_id is not null then
    comision_valor := tarifa_actual.comision;
  else
    comision_valor := 0;
  end if;

  if area_limpia = 'grooming' and comision_valor > precio_valor then
    raise exception using errcode = '22023', message = 'La comisión fija no puede superar el precio del servicio.';
  end if;
  if area_limpia = 'vet' and comision_valor > 100 then
    raise exception using errcode = '22023', message = 'La comisión veterinaria debe ser un porcentaje entre 0 y 100.';
  end if;

  if tarifa_id is not null then
    begin
      update public.pc_tarifas as tarifa
      set nombre = nombre_limpio,
          precio = precio_valor,
          comision = comision_valor,
          updated_at = now()
      where tarifa.negocio_id = p_negocio
        and tarifa.id = tarifa_id
      returning tarifa.* into tarifa_guardada;
    exception
      when unique_violation then
        raise exception using errcode = '23505', message = 'Ya existe otro servicio con ese nombre en el área.';
    end;
    return tarifa_guardada;
  end if;

  select tarifa.*
    into tarifa_actual
  from public.pc_tarifas as tarifa
  where tarifa.negocio_id = p_negocio
    and tarifa.area = area_limpia
    and lower(btrim(tarifa.nombre)) = lower(btrim(nombre_limpio))
  for update;

  if found then
    if tarifa_actual.activo then
      raise exception using errcode = '23505', message = 'Ya existe un servicio con ese nombre en el área.';
    end if;
    update public.pc_tarifas as tarifa
    set nombre = nombre_limpio,
        precio = precio_valor,
        comision = comision_valor,
        activo = true,
        updated_at = now()
    where tarifa.negocio_id = p_negocio
      and tarifa.id = tarifa_actual.id
    returning tarifa.* into tarifa_guardada;
    return tarifa_guardada;
  end if;

  loop
    intento := intento + 1;
    tarifa_id := 'tar_' || nextval('private.pc_tarifas_id_seq'::regclass)::text;
    begin
      insert into public.pc_tarifas (
        id, negocio_id, nombre, precio, comision, area, activo, updated_at
      ) values (
        tarifa_id, p_negocio, nombre_limpio, precio_valor, comision_valor,
        area_limpia, true, now()
      )
      returning * into tarifa_guardada;
      return tarifa_guardada;
    exception
      when unique_violation then
        get stacked diagnostics restriccion = constraint_name;
        if restriccion = 'pc_tarifas_pkey' and intento < 5 then
          continue;
        end if;
        raise exception using errcode = '23505', message = 'Ya existe un servicio con ese nombre en el área.';
    end;
  end loop;
end;
$$;

create or replace function private.procesar_tarifas_lote(
  p_negocio uuid,
  p_tarifas jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  tarifa jsonb;
  posicion bigint;
  fila public.pc_tarifas%rowtype;
  tarifas_resultado jsonb := '[]'::jsonb;
  error_estado text;
  error_mensaje text;
begin
  -- Bloqueo consistente de las filas existentes para evitar deadlocks si dos
  -- administradores editan el mismo lote en distinto orden.
  perform 1
  from public.pc_tarifas as existente
  where existente.negocio_id = p_negocio
    and existente.id in (
      select elemento.value ->> 'id'
      from jsonb_array_elements(p_tarifas) as elemento(value)
      where nullif(btrim(coalesce(elemento.value ->> 'id', '')), '') is not null
    )
  order by existente.id
  for update;

  for tarifa, posicion in
    select elemento.value, elemento.ordinality
    from jsonb_array_elements(p_tarifas) with ordinality as elemento(value, ordinality)
    order by elemento.ordinality
  loop
    if jsonb_typeof(tarifa) <> 'object' then
      raise exception using
        errcode = '22023',
        message = format('Fila %s: la tarifa no tiene un formato válido.', posicion);
    end if;
    begin
      fila := private.guardar_tarifa_fila(p_negocio, tarifa);
    exception
      when others then
        get stacked diagnostics
          error_estado = returned_sqlstate,
          error_mensaje = message_text;
        raise exception using
          errcode = error_estado,
          message = format('Fila %s: %s', posicion, error_mensaje);
    end;
    tarifas_resultado := tarifas_resultado || jsonb_build_array(to_jsonb(fila) - 'negocio_id');
  end loop;
  return tarifas_resultado;
end;
$$;

revoke all on function private.guardar_tarifa_fila(uuid, jsonb)
  from public, anon, authenticated, service_role;
revoke all on function private.procesar_tarifas_lote(uuid, jsonb)
  from public, anon, authenticated, service_role;

-- ─── 4. Alta y edición por lote: solo Administración ────────────────────

create or replace function private.guardar_tarifas_lote_impl(
  p_tarifas jsonb,
  p_fuente text,
  p_operacion_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  negocio uuid;
  usuario uuid;
  fuente_limpia text;
  cantidad integer;
  accion_previa text;
  hash_previo text;
  solicitud_hash text;
  resultado_previo jsonb;
  tarifas_resultado jsonb;
  resultado jsonb;
begin
  usuario := auth.uid();
  negocio := public.mi_negocio();
  if usuario is null or negocio is null then
    raise exception using errcode = '42501', message = 'Sesión o clínica no válida.';
  end if;
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception using errcode = '42501', message = 'Solo administración puede modificar el catálogo.';
  end if;
  if p_operacion_id is null then
    raise exception using errcode = '22023', message = 'La operación requiere un identificador idempotente.';
  end if;
  if p_tarifas is null or jsonb_typeof(p_tarifas) <> 'array' then
    raise exception using errcode = '22023', message = 'El lote de tarifas no tiene un formato válido.';
  end if;
  cantidad := jsonb_array_length(p_tarifas);
  if cantidad < 1 or cantidad > 200 then
    raise exception using errcode = '22023', message = 'Cada lote debe contener entre 1 y 200 tarifas.';
  end if;
  if octet_length(p_tarifas::text) > 2097152 then
    raise exception using errcode = '22023', message = 'El lote de tarifas excede el tamaño permitido.';
  end if;
  fuente_limpia := nullif(
    left(btrim(regexp_replace(coalesce(p_fuente, ''), '[<>]', '', 'g')), 500),
    ''
  );
  if fuente_limpia is null then
    raise exception using errcode = '22023', message = 'La operación requiere una fuente identificable.';
  end if;
  solicitud_hash := md5(jsonb_build_object(
    'tarifas', p_tarifas,
    'fuente', fuente_limpia
  )::text);

  perform pg_advisory_xact_lock(hashtextextended(
    negocio::text || ':guardar-tarifas:' || p_operacion_id::text,
    0
  ));

  select operacion.accion, operacion.solicitud_hash, operacion.resultado
    into accion_previa, hash_previo, resultado_previo
  from private.vetmake_tarifas_operaciones as operacion
  where operacion.negocio_id = negocio
    and operacion.operacion_id = p_operacion_id;

  if found then
    if accion_previa <> 'guardar_tarifas' or hash_previo <> solicitud_hash then
      raise exception using errcode = '22023', message = 'El identificador ya pertenece a una solicitud diferente.';
    end if;
    return resultado_previo;
  end if;

  tarifas_resultado := private.procesar_tarifas_lote(negocio, p_tarifas);
  resultado := jsonb_build_object(
    'tarifas', tarifas_resultado,
    'cantidad', cantidad,
    'fuente', fuente_limpia,
    'operacionId', p_operacion_id
  );

  insert into private.vetmake_tarifas_operaciones (
    negocio_id, usuario_id, operacion_id, accion, solicitud_hash, resultado
  ) values (
    negocio, usuario, p_operacion_id, 'guardar_tarifas', solicitud_hash, resultado
  );
  return resultado;
end;
$$;

-- ─── 5. Importación combinada de servicios y productos ─────────────────

create or replace function private.importar_catalogo_impl(
  p_tarifas jsonb,
  p_productos jsonb,
  p_fuente text,
  p_operacion_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  negocio uuid;
  usuario uuid;
  fuente_limpia text;
  cantidad_tarifas integer;
  cantidad_productos integer;
  accion_previa text;
  hash_previo text;
  solicitud_hash text;
  resultado_previo jsonb;
  tarifas_resultado jsonb := '[]'::jsonb;
  productos_resultado jsonb := '[]'::jsonb;
  resultado jsonb;
begin
  usuario := auth.uid();
  negocio := public.mi_negocio();
  if usuario is null or negocio is null then
    raise exception using errcode = '42501', message = 'Sesión o clínica no válida.';
  end if;
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception using errcode = '42501', message = 'Solo administración puede importar el catálogo.';
  end if;
  if p_operacion_id is null then
    raise exception using errcode = '22023', message = 'La importación requiere un identificador idempotente.';
  end if;
  if p_tarifas is null or jsonb_typeof(p_tarifas) <> 'array'
     or p_productos is null or jsonb_typeof(p_productos) <> 'array' then
    raise exception using errcode = '22023', message = 'El catálogo no tiene un formato válido.';
  end if;
  cantidad_tarifas := jsonb_array_length(p_tarifas);
  cantidad_productos := jsonb_array_length(p_productos);
  if cantidad_tarifas > 200 or cantidad_productos > 200
     or cantidad_tarifas + cantidad_productos < 1 then
    raise exception using errcode = '22023', message = 'La importación admite hasta 200 servicios y 200 productos.';
  end if;
  if octet_length(p_tarifas::text) + octet_length(p_productos::text) > 4194304 then
    raise exception using errcode = '22023', message = 'El catálogo excede el tamaño permitido.';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_tarifas) as elemento(fila)
    where elemento.fila ? 'id'
      and nullif(btrim(coalesce(elemento.fila ->> 'id', '')), '') is not null
  ) or exists (
    select 1 from jsonb_array_elements(p_productos) as elemento(fila)
    where elemento.fila ? 'id'
      and nullif(btrim(coalesce(elemento.fila ->> 'id', '')), '') is not null
  ) then
    raise exception using errcode = '22023', message = 'Una importación nueva no puede elegir identificadores.';
  end if;
  fuente_limpia := nullif(
    left(btrim(regexp_replace(coalesce(p_fuente, ''), '[<>]', '', 'g')), 500),
    ''
  );
  if fuente_limpia is null then
    raise exception using errcode = '22023', message = 'La importación requiere una fuente identificable.';
  end if;
  solicitud_hash := md5(jsonb_build_object(
    'tarifas', p_tarifas,
    'productos', p_productos,
    'fuente', fuente_limpia
  )::text);

  perform pg_advisory_xact_lock(hashtextextended(
    negocio::text || ':importar-catalogo:' || p_operacion_id::text,
    0
  ));

  select operacion.accion, operacion.solicitud_hash, operacion.resultado
    into accion_previa, hash_previo, resultado_previo
  from private.vetmake_tarifas_operaciones as operacion
  where operacion.negocio_id = negocio
    and operacion.operacion_id = p_operacion_id;

  if found then
    if accion_previa <> 'importar_catalogo' or hash_previo <> solicitud_hash then
      raise exception using errcode = '22023', message = 'El identificador ya pertenece a una solicitud diferente.';
    end if;
    return resultado_previo;
  end if;

  if cantidad_tarifas > 0 then
    tarifas_resultado := private.procesar_tarifas_lote(negocio, p_tarifas);
  end if;
  if cantidad_productos > 0 then
    productos_resultado := private.procesar_inventario_lote(negocio, p_productos);
  end if;

  resultado := jsonb_build_object(
    'tarifas', tarifas_resultado,
    'productos', productos_resultado,
    'cantidadTarifas', cantidad_tarifas,
    'cantidadProductos', cantidad_productos,
    'fuente', fuente_limpia,
    'operacionId', p_operacion_id
  );

  insert into private.vetmake_tarifas_operaciones (
    negocio_id, usuario_id, operacion_id, accion, solicitud_hash, resultado
  ) values (
    negocio, usuario, p_operacion_id, 'importar_catalogo', solicitud_hash, resultado
  );
  return resultado;
end;
$$;

-- ─── 6. Retiro lógico: solo Administración ──────────────────────────────

create or replace function private.retirar_tarifa_impl(
  p_tarifa_id text,
  p_operacion_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  negocio uuid;
  usuario uuid;
  tarifa_id text;
  tarifa public.pc_tarifas%rowtype;
  accion_previa text;
  hash_previo text;
  solicitud_hash text;
  resultado_previo jsonb;
  resultado jsonb;
begin
  usuario := auth.uid();
  negocio := public.mi_negocio();
  if usuario is null or negocio is null then
    raise exception using errcode = '42501', message = 'Sesión o clínica no válida.';
  end if;
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception using errcode = '42501', message = 'Solo administración puede retirar servicios.';
  end if;
  if p_operacion_id is null then
    raise exception using errcode = '22023', message = 'La operación requiere un identificador idempotente.';
  end if;
  tarifa_id := nullif(left(btrim(coalesce(p_tarifa_id, '')), 160), '');
  if tarifa_id is null or tarifa_id !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$' then
    raise exception using errcode = '22023', message = 'La tarifa no tiene un identificador válido.';
  end if;
  solicitud_hash := md5(jsonb_build_object('tarifaId', tarifa_id)::text);

  perform pg_advisory_xact_lock(hashtextextended(
    negocio::text || ':retirar-tarifa:' || p_operacion_id::text,
    0
  ));

  select operacion.accion, operacion.solicitud_hash, operacion.resultado
    into accion_previa, hash_previo, resultado_previo
  from private.vetmake_tarifas_operaciones as operacion
  where operacion.negocio_id = negocio
    and operacion.operacion_id = p_operacion_id;

  if found then
    if accion_previa <> 'retirar_tarifa' or hash_previo <> solicitud_hash then
      raise exception using errcode = '22023', message = 'El identificador ya pertenece a una solicitud diferente.';
    end if;
    return resultado_previo;
  end if;

  select fila.*
    into tarifa
  from public.pc_tarifas as fila
  where fila.negocio_id = negocio
    and fila.id = tarifa_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'La tarifa no existe o pertenece a otra clínica.';
  end if;

  if tarifa.activo then
    update public.pc_tarifas as fila
    set activo = false,
        updated_at = now()
    where fila.negocio_id = negocio
      and fila.id = tarifa_id
    returning fila.* into tarifa;
  end if;

  resultado := jsonb_build_object(
    'tarifa', to_jsonb(tarifa) - 'negocio_id',
    'operacionId', p_operacion_id
  );
  insert into private.vetmake_tarifas_operaciones (
    negocio_id, usuario_id, operacion_id, accion, solicitud_hash, resultado
  ) values (
    negocio, usuario, p_operacion_id, 'retirar_tarifa', solicitud_hash, resultado
  );
  return resultado;
end;
$$;

-- ─── 7. Wrappers públicos y permisos explícitos ─────────────────────────

create or replace function public.guardar_tarifas_lote(
  p_tarifas jsonb,
  p_fuente text,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.guardar_tarifas_lote_impl(p_tarifas, p_fuente, p_operacion_id);
$$;

create or replace function public.importar_catalogo(
  p_tarifas jsonb,
  p_productos jsonb,
  p_fuente text,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.importar_catalogo_impl(p_tarifas, p_productos, p_fuente, p_operacion_id);
$$;

create or replace function public.retirar_tarifa(
  p_tarifa_id text,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.retirar_tarifa_impl(p_tarifa_id, p_operacion_id);
$$;

revoke all on function private.guardar_tarifas_lote_impl(jsonb, text, uuid)
  from public, anon;
revoke all on function private.importar_catalogo_impl(jsonb, jsonb, text, uuid)
  from public, anon;
revoke all on function private.retirar_tarifa_impl(text, uuid)
  from public, anon;
revoke all on function public.guardar_tarifas_lote(jsonb, text, uuid)
  from public, anon;
revoke all on function public.importar_catalogo(jsonb, jsonb, text, uuid)
  from public, anon;
revoke all on function public.retirar_tarifa(text, uuid)
  from public, anon;

grant usage on schema private to authenticated, service_role;
grant execute on function private.guardar_tarifas_lote_impl(jsonb, text, uuid)
  to authenticated, service_role;
grant execute on function private.importar_catalogo_impl(jsonb, jsonb, text, uuid)
  to authenticated, service_role;
grant execute on function private.retirar_tarifa_impl(text, uuid)
  to authenticated, service_role;
grant execute on function public.guardar_tarifas_lote(jsonb, text, uuid)
  to authenticated, service_role;
grant execute on function public.importar_catalogo(jsonb, jsonb, text, uuid)
  to authenticated, service_role;
grant execute on function public.retirar_tarifa(text, uuid)
  to authenticated, service_role;

-- ─── 8. Defensa ante componentes heredados ──────────────────────────────

create or replace function private.proteger_identidad_tarifa()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.id is distinct from old.id
     or new.negocio_id is distinct from old.negocio_id
     or new.area is distinct from old.area then
    raise exception using errcode = '22023', message = 'La identidad y el área de la tarifa son inmutables.';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function private.proteger_identidad_tarifa()
  from public, anon, authenticated, service_role;

drop trigger if exists proteger_identidad_tarifa_trigger on public.pc_tarifas;
create trigger proteger_identidad_tarifa_trigger
before update on public.pc_tarifas
for each row execute function private.proteger_identidad_tarifa();

revoke all on table public.pc_tarifas from anon;
revoke insert, update, delete on table public.pc_tarifas from authenticated;
grant select on table public.pc_tarifas to authenticated, service_role;
grant insert, update, delete on table public.pc_tarifas to service_role;

drop policy if exists tarifas_admin_inserta on public.pc_tarifas;
drop policy if exists tarifas_admin_actualiza on public.pc_tarifas;
drop policy if exists tarifas_admin_borra on public.pc_tarifas;
drop policy if exists tarifas_equipo_lee on public.pc_tarifas;

create policy tarifas_equipo_lee
  on public.pc_tarifas for select to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and activo = true
    and (select public.tiene_rol(array['admin','caja','veterinario','groomer']::text[]))
  );

comment on function public.guardar_tarifas_lote(jsonb, text, uuid) is
  'Crea o edita de 1 a 200 tarifas en una sola transacción, con validación e idempotencia.';
comment on function public.importar_catalogo(jsonb, jsonb, text, uuid) is
  'Importa servicios y productos en una sola transacción; solo administración y sin IDs del cliente.';
comment on function public.retirar_tarifa(text, uuid) is
  'Retira lógicamente una tarifa y conserva su identidad e historial.';

notify pgrst, 'reload schema';
