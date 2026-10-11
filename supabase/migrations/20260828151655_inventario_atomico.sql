-- VetMake · inventario atómico y sin DML directo
--
-- Centraliza altas, ediciones, importaciones y retiros de productos. Los IDs
-- se asignan en PostgreSQL, los lotes son transaccionales e idempotentes y el
-- Data API autenticado queda de solo lectura para esta tabla.

-- ─── 1. Archivo recuperable de la importación diagnóstica vacía ──────────

create table if not exists private.vetmake_inventario_archivo (
  negocio_id uuid not null references public.negocios(id) on delete cascade,
  producto_id text not null,
  fila jsonb not null,
  motivo text not null,
  archivado_en timestamptz not null default now(),
  primary key (negocio_id, producto_id)
);

alter table private.vetmake_inventario_archivo enable row level security;
revoke all on table private.vetmake_inventario_archivo
  from public, anon, authenticated;

with referencias as (
  select distinct ajuste ->> 'id' as producto_id
  from public.pc_ventas as venta
  cross join lateral jsonb_array_elements(
    coalesce(venta.ajustes_inventario, '[]'::jsonb)
  ) as ajuste
  where jsonb_typeof(ajuste) = 'object'
), candidatos as (
  select producto.*
  from public.pc_inventario as producto
  where producto.id ~ '^imp_inv_[0-9]+$'
    and nullif(btrim(producto.nombre), '') is null
    and coalesce(producto.stock, 0) = 0
    and coalesce(producto.stockmin, 0) = 0
    and coalesce(producto.preciocompra, 0) = 0
    and coalesce(producto.precioventa, 0) = 0
    and nullif(btrim(producto.proveedor), '') is null
    and nullif(btrim(producto.notas), '') is null
    and not exists (
      select 1
      from referencias
      where referencias.producto_id = producto.id
    )
)
insert into private.vetmake_inventario_archivo (
  negocio_id,
  producto_id,
  fila,
  motivo
)
select
  candidato.negocio_id,
  candidato.id,
  to_jsonb(candidato),
  'importacion_diagnostica_vacia_2026_08_25'
from candidatos as candidato
on conflict (negocio_id, producto_id) do nothing;

delete from public.pc_inventario as producto
where producto.id ~ '^imp_inv_[0-9]+$'
  and nullif(btrim(producto.nombre), '') is null
  and coalesce(producto.stock, 0) = 0
  and coalesce(producto.stockmin, 0) = 0
  and coalesce(producto.preciocompra, 0) = 0
  and coalesce(producto.precioventa, 0) = 0
  and nullif(btrim(producto.proveedor), '') is null
  and nullif(btrim(producto.notas), '') is null
  and exists (
    select 1
    from private.vetmake_inventario_archivo as archivo
    where archivo.negocio_id = producto.negocio_id
      and archivo.producto_id = producto.id
      and archivo.motivo = 'importacion_diagnostica_vacia_2026_08_25'
  );

-- ─── 2. Esquema canónico e identificadores de servidor ──────────────────

alter table public.pc_inventario
  add column if not exists activo boolean not null default true;

update public.pc_inventario
set categoria = coalesce(nullif(btrim(categoria), ''), 'otro'),
    stock = coalesce(stock, 0),
    stockmin = coalesce(stockmin, 0),
    preciocompra = coalesce(preciocompra, 0),
    precioventa = coalesce(precioventa, 0),
    stockinicial = coalesce(stockinicial, stock, 0),
    activo = coalesce(activo, true);

alter table public.pc_inventario
  alter column nombre set not null,
  alter column categoria set not null,
  alter column stock set not null,
  alter column stockmin set not null,
  alter column preciocompra set not null,
  alter column precioventa set not null,
  alter column stockinicial set not null;

alter table public.pc_inventario
  drop constraint if exists pc_inventario_nombre_chk,
  drop constraint if exists pc_inventario_categoria_chk,
  drop constraint if exists pc_inventario_stock_chk,
  drop constraint if exists pc_inventario_precios_chk,
  drop constraint if exists pc_inventario_fechaentrada_chk;

alter table public.pc_inventario
  add constraint pc_inventario_nombre_chk
    check (nullif(btrim(nombre), '') is not null),
  add constraint pc_inventario_categoria_chk
    check (categoria in ('farmaco', 'alimento', 'accesorio', 'insumo', 'papeleria', 'otro')),
  add constraint pc_inventario_stock_chk
    check (
      stock between 0 and 1000000000
      and stockmin between 0 and 1000000000
      and stockinicial between 0 and 1000000000
    ),
  add constraint pc_inventario_precios_chk
    check (
      preciocompra between 0 and 1000000000000
      and precioventa between 0 and 1000000000000
    ),
  add constraint pc_inventario_fechaentrada_chk
    check (
      fechaentrada is null
      or (
        fechaentrada ~ '^\d{4}-\d{2}-\d{2}$'
        and to_char(to_date(fechaentrada, 'YYYY-MM-DD'), 'YYYY-MM-DD') = fechaentrada
      )
    );

create unique index if not exists pc_inventario_negocio_nombre_uidx
  on public.pc_inventario (negocio_id, lower(btrim(nombre)));

create sequence if not exists private.pc_inventario_id_seq as bigint start with 1;
revoke all on sequence private.pc_inventario_id_seq
  from public, anon, authenticated;

do $$
declare
  maximo bigint;
  actual bigint;
begin
  select coalesce(max(substring(id from '^inv_([0-9]+)$')::bigint), 0)
    into maximo
  from public.pc_inventario
  where id ~ '^inv_[0-9]+$';

  select last_value into actual from private.pc_inventario_id_seq;
  if maximo = 0 and coalesce(actual, 1) = 1 then
    perform setval('private.pc_inventario_id_seq'::regclass, 1, false);
  else
    perform setval(
      'private.pc_inventario_id_seq'::regclass,
      greatest(coalesce(actual, 1), maximo, 1),
      true
    );
  end if;
end
$$;

-- ─── 3. Idempotencia privada ─────────────────────────────────────────────

create table if not exists private.vetmake_inventario_operaciones (
  negocio_id uuid not null references public.negocios(id) on delete cascade,
  usuario_id uuid not null,
  operacion_id uuid not null,
  accion text not null check (
    accion in ('guardar_inventario', 'importar_inventario', 'eliminar_inventario')
  ),
  resultado jsonb not null,
  created_at timestamptz not null default now(),
  primary key (negocio_id, operacion_id)
);

alter table private.vetmake_inventario_operaciones enable row level security;
revoke all on table private.vetmake_inventario_operaciones
  from public, anon, authenticated;

-- ─── 4. Validación y escritura interna de una fila ──────────────────────

create or replace function private.inventario_numero(
  p_valor jsonb,
  p_etiqueta text,
  p_predeterminado numeric,
  p_maximo numeric,
  p_decimales integer
)
returns numeric
language plpgsql
security invoker
set search_path = ''
as $$
declare
  texto text;
  numero numeric;
begin
  if p_valor is null or jsonb_typeof(p_valor) = 'null' then
    if p_predeterminado is null then
      raise exception using errcode = '22023', message = p_etiqueta || ' es obligatorio.';
    end if;
    return p_predeterminado;
  end if;

  texto := replace(btrim(coalesce(p_valor #>> '{}', '')), ',', '.');
  if texto = '' then
    if p_predeterminado is null then
      raise exception using errcode = '22023', message = p_etiqueta || ' es obligatorio.';
    end if;
    return p_predeterminado;
  end if;
  if char_length(texto) > 40 or texto !~ '^[0-9]+([.][0-9]{1,6})?$' then
    raise exception using errcode = '22023', message = p_etiqueta || ' debe ser un número válido y no negativo.';
  end if;

  numero := texto::numeric;
  if numero > p_maximo then
    raise exception using errcode = '22023', message = p_etiqueta || ' excede el máximo permitido.';
  end if;
  return round(numero, p_decimales);
exception
  when numeric_value_out_of_range then
    raise exception using errcode = '22023', message = p_etiqueta || ' no tiene un valor válido.';
end;
$$;

create or replace function private.guardar_producto_inventario_fila(
  p_negocio uuid,
  p_producto jsonb
)
returns public.pc_inventario
language plpgsql
security invoker
set search_path = ''
as $$
declare
  datos jsonb := coalesce(p_producto, '{}'::jsonb);
  producto_id text;
  producto_actual public.pc_inventario%rowtype;
  producto_guardado public.pc_inventario%rowtype;
  nombre_limpio text;
  categoria_limpia text;
  proveedor_limpio text;
  notas_limpias text;
  fecha_entrada text;
  fecha_local text;
  zona text;
  stock_valor numeric;
  stock_minimo numeric;
  costo_valor numeric;
  venta_valor numeric;
  stock_inicial numeric;
  intento integer := 0;
  restriccion text;
begin
  if p_negocio is null then
    raise exception using errcode = '42501', message = 'La clínica no es válida.';
  end if;
  if jsonb_typeof(datos) <> 'object' then
    raise exception using errcode = '22023', message = 'El producto no tiene un formato válido.';
  end if;
  if octet_length(datos::text) > 65536 then
    raise exception using errcode = '22023', message = 'El producto excede el tamaño permitido.';
  end if;

  producto_id := nullif(left(btrim(coalesce(datos ->> 'id', '')), 160), '');
  if producto_id is not null and producto_id !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$' then
    raise exception using errcode = '22023', message = 'El producto no tiene un identificador válido.';
  end if;

  if producto_id is not null then
    select producto.*
      into producto_actual
    from public.pc_inventario as producto
    where producto.negocio_id = p_negocio
      and producto.id = producto_id
    for update;

    if not found then
      raise exception using errcode = 'P0002', message = 'El producto no existe o pertenece a otra clínica.';
    end if;
    if producto_actual.activo = false then
      raise exception using errcode = 'P0002', message = 'El producto está retirado. Créalo nuevamente para reactivarlo.';
    end if;
  end if;

  if datos ? 'nombre' then
    nombre_limpio := nullif(
      left(btrim(regexp_replace(coalesce(datos ->> 'nombre', ''), '[<>]', '', 'g')), 200),
      ''
    );
  elsif producto_id is not null then
    nombre_limpio := producto_actual.nombre;
  end if;
  if nombre_limpio is null then
    raise exception using errcode = '22023', message = 'El nombre del producto es obligatorio.';
  end if;

  if datos ? 'categoria' then
    categoria_limpia := lower(left(btrim(regexp_replace(coalesce(datos ->> 'categoria', ''), '[<>]', '', 'g')), 40));
  elsif producto_id is not null then
    categoria_limpia := producto_actual.categoria;
  else
    categoria_limpia := 'otro';
  end if;
  if categoria_limpia not in ('farmaco', 'alimento', 'accesorio', 'insumo', 'papeleria', 'otro') then
    raise exception using errcode = '22023', message = 'La categoría del producto no es válida.';
  end if;

  if datos ? 'stock' then
    stock_valor := private.inventario_numero(datos -> 'stock', 'El stock', null, 1000000000, 3);
  elsif producto_id is not null then
    stock_valor := producto_actual.stock;
  else
    stock_valor := 0;
  end if;

  if datos ? 'stockMin' then
    stock_minimo := private.inventario_numero(datos -> 'stockMin', 'El stock mínimo', null, 1000000000, 3);
  elsif producto_id is not null then
    stock_minimo := producto_actual.stockmin;
  else
    stock_minimo := 0;
  end if;

  if datos ? 'costo' then
    costo_valor := private.inventario_numero(datos -> 'costo', 'El precio de compra', null, 1000000000000, 2);
  elsif producto_id is not null then
    costo_valor := producto_actual.preciocompra;
  else
    costo_valor := 0;
  end if;

  if datos ? 'pventa' then
    venta_valor := private.inventario_numero(datos -> 'pventa', 'El precio de venta', null, 1000000000000, 2);
  elsif producto_id is not null then
    venta_valor := producto_actual.precioventa;
  else
    venta_valor := 0;
  end if;

  if datos ? 'stockInicial' then
    stock_inicial := private.inventario_numero(datos -> 'stockInicial', 'El stock inicial', null, 1000000000, 3);
  elsif producto_id is not null then
    stock_inicial := producto_actual.stockinicial;
  else
    stock_inicial := stock_valor;
  end if;

  if datos ? 'proveedor' then
    proveedor_limpio := nullif(
      left(btrim(regexp_replace(coalesce(datos ->> 'proveedor', ''), '[<>]', '', 'g')), 240),
      ''
    );
  elsif producto_id is not null then
    proveedor_limpio := producto_actual.proveedor;
  end if;

  if datos ? 'notas' then
    notas_limpias := nullif(
      left(btrim(regexp_replace(coalesce(datos ->> 'notas', ''), '[<>]', '', 'g')), 4000),
      ''
    );
  elsif producto_id is not null then
    notas_limpias := producto_actual.notas;
  end if;

  select coalesce(nullif(negocio.zona_horaria, ''), 'America/Santo_Domingo')
    into zona
  from public.negocios as negocio
  where negocio.id = p_negocio;
  fecha_local := ((statement_timestamp() at time zone coalesce(zona, 'America/Santo_Domingo'))::date)::text;

  if datos ? 'fechaEntrada' then
    fecha_entrada := nullif(
      left(btrim(regexp_replace(coalesce(datos ->> 'fechaEntrada', ''), '[<>]', '', 'g')), 10),
      ''
    );
  elsif producto_id is not null then
    fecha_entrada := producto_actual.fechaentrada;
  else
    fecha_entrada := fecha_local;
  end if;
  if fecha_entrada is not null and (
    fecha_entrada !~ '^\d{4}-\d{2}-\d{2}$'
    or to_char(to_date(fecha_entrada, 'YYYY-MM-DD'), 'YYYY-MM-DD') <> fecha_entrada
    or fecha_entrada > fecha_local
  ) then
    raise exception using errcode = '22023', message = 'La fecha de entrada no es válida.';
  end if;

  if producto_id is not null then
    begin
      update public.pc_inventario as producto
      set nombre = nombre_limpio,
          categoria = categoria_limpia,
          stock = stock_valor,
          stockmin = stock_minimo,
          preciocompra = costo_valor,
          precioventa = venta_valor,
          proveedor = proveedor_limpio,
          notas = notas_limpias,
          fechaentrada = fecha_entrada,
          stockinicial = stock_inicial
      where producto.negocio_id = p_negocio
        and producto.id = producto_id
      returning producto.* into producto_guardado;
    exception
      when unique_violation then
        raise exception using errcode = '23505', message = 'Ya existe otro producto con ese nombre en la clínica.';
    end;
    return producto_guardado;
  end if;

  select producto.*
    into producto_actual
  from public.pc_inventario as producto
  where producto.negocio_id = p_negocio
    and lower(btrim(producto.nombre)) = lower(btrim(nombre_limpio))
  for update;

  if found then
    if producto_actual.activo then
      raise exception using errcode = '23505', message = 'Ya existe un producto con ese nombre en la clínica.';
    end if;
    update public.pc_inventario as producto
    set nombre = nombre_limpio,
        categoria = categoria_limpia,
        stock = stock_valor,
        stockmin = stock_minimo,
        preciocompra = costo_valor,
        precioventa = venta_valor,
        proveedor = proveedor_limpio,
        notas = notas_limpias,
        fechaentrada = fecha_entrada,
        stockinicial = stock_inicial,
        activo = true
    where producto.negocio_id = p_negocio
      and producto.id = producto_actual.id
    returning producto.* into producto_guardado;
    return producto_guardado;
  end if;

  loop
    intento := intento + 1;
    producto_id := 'inv_' || nextval('private.pc_inventario_id_seq'::regclass)::text;
    begin
      insert into public.pc_inventario (
        id,
        negocio_id,
        nombre,
        categoria,
        stock,
        stockmin,
        preciocompra,
        precioventa,
        proveedor,
        notas,
        fechaentrada,
        stockinicial,
        activo
      )
      values (
        producto_id,
        p_negocio,
        nombre_limpio,
        categoria_limpia,
        stock_valor,
        stock_minimo,
        costo_valor,
        venta_valor,
        proveedor_limpio,
        notas_limpias,
        fecha_entrada,
        stock_inicial,
        true
      )
      returning * into producto_guardado;
      return producto_guardado;
    exception
      when unique_violation then
        get stacked diagnostics restriccion = constraint_name;
        if restriccion = 'pc_inventario_pkey' and intento < 5 then
          continue;
        end if;
        raise exception using errcode = '23505', message = 'Ya existe un producto con ese nombre en la clínica.';
    end;
  end loop;
end;
$$;

create or replace function private.procesar_inventario_lote(
  p_negocio uuid,
  p_productos jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  producto jsonb;
  posicion bigint;
  fila public.pc_inventario%rowtype;
  productos_resultado jsonb := '[]'::jsonb;
  error_estado text;
  error_mensaje text;
begin
  for producto, posicion in
    select elemento.value, elemento.ordinality
    from jsonb_array_elements(p_productos) with ordinality as elemento(value, ordinality)
    order by elemento.ordinality
  loop
    if jsonb_typeof(producto) <> 'object' then
      raise exception using
        errcode = '22023',
        message = format('Fila %s: el producto no tiene un formato válido.', posicion);
    end if;
    begin
      fila := private.guardar_producto_inventario_fila(p_negocio, producto);
    exception
      when others then
        get stacked diagnostics
          error_estado = returned_sqlstate,
          error_mensaje = message_text;
        raise exception using
          errcode = error_estado,
          message = format('Fila %s: %s', posicion, error_mensaje);
    end;
    productos_resultado := productos_resultado || jsonb_build_array(to_jsonb(fila) - 'negocio_id');
  end loop;
  return productos_resultado;
end;
$$;

revoke all on function private.inventario_numero(jsonb, text, numeric, numeric, integer)
  from public, anon, authenticated, service_role;
revoke all on function private.guardar_producto_inventario_fila(uuid, jsonb)
  from public, anon, authenticated, service_role;
revoke all on function private.procesar_inventario_lote(uuid, jsonb)
  from public, anon, authenticated, service_role;

-- ─── 5. Lote interactivo: Administración y Caja ─────────────────────────

create or replace function private.guardar_inventario_lote_impl(
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
  cantidad integer;
  accion_previa text;
  resultado_previo jsonb;
  productos_resultado jsonb;
  resultado jsonb;
begin
  usuario := auth.uid();
  negocio := public.mi_negocio();
  if usuario is null or negocio is null then
    raise exception using errcode = '42501', message = 'Sesión o clínica no válida.';
  end if;
  if not public.tiene_rol(array['admin', 'caja']::text[]) then
    raise exception using errcode = '42501', message = 'Tu rol no puede modificar el inventario.';
  end if;
  if p_operacion_id is null then
    raise exception using errcode = '22023', message = 'La operación requiere un identificador idempotente.';
  end if;
  if p_productos is null or jsonb_typeof(p_productos) <> 'array' then
    raise exception using errcode = '22023', message = 'El lote de inventario no tiene un formato válido.';
  end if;
  cantidad := jsonb_array_length(p_productos);
  if cantidad < 1 or cantidad > 200 then
    raise exception using errcode = '22023', message = 'Cada lote debe contener entre 1 y 200 productos.';
  end if;
  if octet_length(p_productos::text) > 4194304 then
    raise exception using errcode = '22023', message = 'El lote de inventario excede el tamaño permitido.';
  end if;
  fuente_limpia := nullif(
    left(btrim(regexp_replace(coalesce(p_fuente, ''), '[<>]', '', 'g')), 500),
    ''
  );
  if fuente_limpia is null then
    raise exception using errcode = '22023', message = 'La operación requiere una fuente identificable.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    negocio::text || ':guardar-inventario:' || p_operacion_id::text,
    0
  ));

  select operacion.accion, operacion.resultado
    into accion_previa, resultado_previo
  from private.vetmake_inventario_operaciones as operacion
  where operacion.negocio_id = negocio
    and operacion.operacion_id = p_operacion_id;

  if found then
    if accion_previa <> 'guardar_inventario' then
      raise exception using errcode = '22023', message = 'El identificador ya pertenece a otra operación.';
    end if;
    return resultado_previo;
  end if;

  productos_resultado := private.procesar_inventario_lote(negocio, p_productos);
  resultado := jsonb_build_object(
    'productos', productos_resultado,
    'cantidad', cantidad,
    'fuente', fuente_limpia,
    'operacionId', p_operacion_id
  );

  insert into private.vetmake_inventario_operaciones (
    negocio_id, usuario_id, operacion_id, accion, resultado
  ) values (
    negocio, usuario, p_operacion_id, 'guardar_inventario', resultado
  );
  return resultado;
end;
$$;

-- ─── 6. Importación: solo Administración ────────────────────────────────

create or replace function private.importar_inventario_impl(
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
  cantidad integer;
  accion_previa text;
  resultado_previo jsonb;
  productos_resultado jsonb;
  resultado jsonb;
begin
  usuario := auth.uid();
  negocio := public.mi_negocio();
  if usuario is null or negocio is null then
    raise exception using errcode = '42501', message = 'Sesión o clínica no válida.';
  end if;
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception using errcode = '42501', message = 'Solo administración puede importar inventario.';
  end if;
  if p_operacion_id is null then
    raise exception using errcode = '22023', message = 'La importación requiere un identificador idempotente.';
  end if;
  if p_productos is null or jsonb_typeof(p_productos) <> 'array' then
    raise exception using errcode = '22023', message = 'El lote de inventario no tiene un formato válido.';
  end if;
  cantidad := jsonb_array_length(p_productos);
  if cantidad < 1 or cantidad > 200 then
    raise exception using errcode = '22023', message = 'Cada lote debe contener entre 1 y 200 productos.';
  end if;
  if octet_length(p_productos::text) > 4194304 then
    raise exception using errcode = '22023', message = 'El lote de inventario excede el tamaño permitido.';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(p_productos) as elemento(producto)
    where elemento.producto ? 'id'
      and nullif(btrim(coalesce(elemento.producto ->> 'id', '')), '') is not null
  ) then
    raise exception using errcode = '22023', message = 'Una importación nueva no puede elegir identificadores de productos.';
  end if;
  fuente_limpia := nullif(
    left(btrim(regexp_replace(coalesce(p_fuente, ''), '[<>]', '', 'g')), 500),
    ''
  );
  if fuente_limpia is null then
    raise exception using errcode = '22023', message = 'La importación requiere una fuente identificable.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    negocio::text || ':importar-inventario:' || p_operacion_id::text,
    0
  ));

  select operacion.accion, operacion.resultado
    into accion_previa, resultado_previo
  from private.vetmake_inventario_operaciones as operacion
  where operacion.negocio_id = negocio
    and operacion.operacion_id = p_operacion_id;

  if found then
    if accion_previa <> 'importar_inventario' then
      raise exception using errcode = '22023', message = 'El identificador ya pertenece a otra operación.';
    end if;
    return resultado_previo;
  end if;

  productos_resultado := private.procesar_inventario_lote(negocio, p_productos);
  resultado := jsonb_build_object(
    'productos', productos_resultado,
    'cantidad', cantidad,
    'fuente', fuente_limpia,
    'operacionId', p_operacion_id
  );

  insert into private.vetmake_inventario_operaciones (
    negocio_id, usuario_id, operacion_id, accion, resultado
  ) values (
    negocio, usuario, p_operacion_id, 'importar_inventario', resultado
  );
  return resultado;
end;
$$;

-- ─── 7. Retiro lógico: solo Administración ──────────────────────────────

create or replace function private.eliminar_producto_inventario_impl(
  p_producto_id text,
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
  producto_id text;
  producto public.pc_inventario%rowtype;
  accion_previa text;
  resultado_previo jsonb;
  resultado jsonb;
begin
  usuario := auth.uid();
  negocio := public.mi_negocio();
  if usuario is null or negocio is null then
    raise exception using errcode = '42501', message = 'Sesión o clínica no válida.';
  end if;
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception using errcode = '42501', message = 'Solo administración puede retirar productos.';
  end if;
  if p_operacion_id is null then
    raise exception using errcode = '22023', message = 'La operación requiere un identificador idempotente.';
  end if;
  producto_id := nullif(left(btrim(coalesce(p_producto_id, '')), 160), '');
  if producto_id is null or producto_id !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$' then
    raise exception using errcode = '22023', message = 'El producto no tiene un identificador válido.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    negocio::text || ':eliminar-inventario:' || p_operacion_id::text,
    0
  ));

  select operacion.accion, operacion.resultado
    into accion_previa, resultado_previo
  from private.vetmake_inventario_operaciones as operacion
  where operacion.negocio_id = negocio
    and operacion.operacion_id = p_operacion_id;

  if found then
    if accion_previa <> 'eliminar_inventario' then
      raise exception using errcode = '22023', message = 'El identificador ya pertenece a otra operación.';
    end if;
    return resultado_previo;
  end if;

  select fila.*
    into producto
  from public.pc_inventario as fila
  where fila.negocio_id = negocio
    and fila.id = producto_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'El producto no existe o pertenece a otra clínica.';
  end if;
  if producto.activo and producto.stock <> 0 then
    raise exception using errcode = '22023', message = 'Ajusta el stock a cero antes de retirar el producto.';
  end if;

  if producto.activo then
    update public.pc_inventario as fila
    set activo = false
    where fila.negocio_id = negocio
      and fila.id = producto_id
    returning fila.* into producto;
  end if;

  resultado := jsonb_build_object(
    'producto', to_jsonb(producto) - 'negocio_id',
    'operacionId', p_operacion_id
  );
  insert into private.vetmake_inventario_operaciones (
    negocio_id, usuario_id, operacion_id, accion, resultado
  ) values (
    negocio, usuario, p_operacion_id, 'eliminar_inventario', resultado
  );
  return resultado;
end;
$$;

-- ─── 8. Wrappers públicos sin privilegios elevados ─────────────────────

create or replace function public.guardar_inventario_lote(
  p_productos jsonb,
  p_fuente text,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.guardar_inventario_lote_impl(p_productos, p_fuente, p_operacion_id);
$$;

create or replace function public.importar_inventario(
  p_productos jsonb,
  p_fuente text,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.importar_inventario_impl(p_productos, p_fuente, p_operacion_id);
$$;

create or replace function public.eliminar_producto_inventario(
  p_producto_id text,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.eliminar_producto_inventario_impl(p_producto_id, p_operacion_id);
$$;

revoke all on function private.guardar_inventario_lote_impl(jsonb, text, uuid)
  from public, anon;
revoke all on function private.importar_inventario_impl(jsonb, text, uuid)
  from public, anon;
revoke all on function private.eliminar_producto_inventario_impl(text, uuid)
  from public, anon;
revoke all on function public.guardar_inventario_lote(jsonb, text, uuid)
  from public, anon;
revoke all on function public.importar_inventario(jsonb, text, uuid)
  from public, anon;
revoke all on function public.eliminar_producto_inventario(text, uuid)
  from public, anon;

grant usage on schema private to authenticated, service_role;
grant execute on function private.guardar_inventario_lote_impl(jsonb, text, uuid)
  to authenticated, service_role;
grant execute on function private.importar_inventario_impl(jsonb, text, uuid)
  to authenticated, service_role;
grant execute on function private.eliminar_producto_inventario_impl(text, uuid)
  to authenticated, service_role;
grant execute on function public.guardar_inventario_lote(jsonb, text, uuid)
  to authenticated, service_role;
grant execute on function public.importar_inventario(jsonb, text, uuid)
  to authenticated, service_role;
grant execute on function public.eliminar_producto_inventario(text, uuid)
  to authenticated, service_role;

-- ─── 9. Defensa ante componentes heredados y productos retirados ───────

create or replace function private.proteger_identidad_inventario()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.id is distinct from old.id or new.negocio_id is distinct from old.negocio_id then
    raise exception using errcode = '22023', message = 'La identidad del producto es inmutable.';
  end if;
  if old.activo = false and new.stock < old.stock then
    raise exception using errcode = '22023', message = 'Un producto retirado no puede consumirse en una venta.';
  end if;
  return new;
end;
$$;

revoke all on function private.proteger_identidad_inventario()
  from public, anon, authenticated, service_role;

drop trigger if exists proteger_identidad_inventario_trigger on public.pc_inventario;
create trigger proteger_identidad_inventario_trigger
before update on public.pc_inventario
for each row execute function private.proteger_identidad_inventario();

revoke all on table public.pc_inventario from anon;
revoke insert, update, delete on table public.pc_inventario from authenticated;
grant select on table public.pc_inventario to authenticated, service_role;
grant insert, update, delete on table public.pc_inventario to service_role;

drop policy if exists inventario_caja_inserta on public.pc_inventario;
drop policy if exists inventario_caja_actualiza on public.pc_inventario;
drop policy if exists inventario_admin_borra on public.pc_inventario;

comment on function public.guardar_inventario_lote(jsonb, text, uuid) is
  'Crea o edita de 1 a 200 productos en una sola transacción, con validación e idempotencia.';
comment on function public.importar_inventario(jsonb, text, uuid) is
  'Importa de 1 a 200 productos nuevos; solo administración y sin IDs elegidos por el cliente.';
comment on function public.eliminar_producto_inventario(text, uuid) is
  'Retira lógicamente un producto con stock cero, conservando su trazabilidad histórica.';

notify pgrst, 'reload schema';
