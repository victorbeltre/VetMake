-- VetMake · Facturación atómica por negocio
--
-- El navegador deja de ser la autoridad para numerar facturas. Una fila de
-- contador por clínica se bloquea y actualiza dentro de la misma transacción
-- que inserta la factura, evitando duplicados aunque dos cajas facturen a la vez.

create table if not exists public.pc_factura_contadores (
  negocio_id uuid primary key references public.negocios(id) on delete cascade,
  ultimo_numero bigint not null default 0 check (ultimo_numero >= 0),
  actualizado_en timestamptz not null default now()
);

alter table public.pc_factura_contadores enable row level security;
revoke all privileges on table public.pc_factura_contadores from public, anon, authenticated;

-- Inicializa el contador con el mayor número válido que ya exista por negocio.
insert into public.pc_factura_contadores (negocio_id, ultimo_numero)
select
  negocio.id,
  coalesce(max(factura.numero::bigint) filter (where factura.numero ~ '^[0-9]+$'), 0)
from public.negocios as negocio
left join public.pc_facturas as factura on factura.negocio_id = negocio.id
group by negocio.id
on conflict (negocio_id) do update
set ultimo_numero = greatest(
  public.pc_factura_contadores.ultimo_numero,
  excluded.ultimo_numero
);

-- La tabla estaba vacía en vetmake-dev. El USING también permite ejecutar la
-- migración sobre instalaciones con facturas antiguas serializadas como texto.
alter table public.pc_facturas
  alter column items drop default;

alter table public.pc_facturas
  alter column items type jsonb
  using case
    when items is null or btrim(items::text) in ('', 'null') then '[]'::jsonb
    else items::jsonb
  end;

alter table public.pc_facturas
  alter column items set default '[]'::jsonb,
  add column if not exists emitida_por uuid,
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists actualizada_at timestamptz not null default now();

create unique index if not exists pc_facturas_negocio_numero_uidx
  on public.pc_facturas (negocio_id, numero)
  where numero is not null;

create index if not exists pc_facturas_negocio_fecha_idx
  on public.pc_facturas (negocio_id, fecha desc);

create index if not exists pc_ventas_negocio_empleado_idx
  on public.pc_ventas (negocio_id, empleadoid);

create or replace function public.siguiente_numero_factura(negocio uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  siguiente bigint;
begin
  if negocio is null then
    raise exception using errcode = '22023', message = 'La factura requiere un negocio.';
  end if;

  insert into public.pc_factura_contadores (negocio_id, ultimo_numero)
  values (negocio, 0)
  on conflict (negocio_id) do nothing;

  update public.pc_factura_contadores
  set ultimo_numero = ultimo_numero + 1,
      actualizado_en = statement_timestamp()
  where negocio_id = negocio
  returning ultimo_numero into siguiente;

  if siguiente is null then
    raise exception using errcode = 'P0001', message = 'No se pudo reservar el número de factura.';
  end if;

  return lpad(siguiente::text, 4, '0');
end;
$$;

revoke all on function public.siguiente_numero_factura(uuid) from public, anon, authenticated;

create or replace function public.proteger_numero_factura()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  numero_existente text;
begin
  if tg_op = 'UPDATE' then
    new.numero := old.numero;
    new.actualizada_at := statement_timestamp();
    return new;
  end if;

  -- Conserva el número durante un UPSERT de clientes antiguos. Para una fila
  -- realmente nueva siempre ignora el número enviado por el navegador.
  select factura.numero
  into numero_existente
  from public.pc_facturas as factura
  where factura.id = new.id
  limit 1;

  if numero_existente is not null then
    new.numero := numero_existente;
  else
    new.numero := public.siguiente_numero_factura(new.negocio_id);
  end if;

  new.emitida_por := coalesce(new.emitida_por, (select auth.uid()));
  new.created_at := coalesce(new.created_at, statement_timestamp());
  new.actualizada_at := statement_timestamp();
  return new;
end;
$$;

revoke all on function public.proteger_numero_factura() from public, anon, authenticated;

drop trigger if exists vetmake_protege_numero_factura on public.pc_facturas;
create trigger vetmake_protege_numero_factura
before insert or update on public.pc_facturas
for each row execute function public.proteger_numero_factura();

create or replace function public.crear_factura(factura jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  usuario uuid := (select auth.uid());
  negocio uuid;
  rol text;
  lineas jsonb := coalesce(factura -> 'items', '[]'::jsonb);
  fecha_factura text := coalesce(nullif(btrim(factura ->> 'fecha'), ''), current_date::text);
  usa_itbis boolean := coalesce((factura ->> 'itbis')::boolean, false);
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
    id,
    negocio_id,
    numero,
    fecha,
    mascota,
    propietario,
    telefono,
    items,
    metodopago,
    estado,
    itbis,
    subtotal,
    itbisamt,
    total,
    notas,
    clienteid,
    autogenerada,
    emitida_por
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
    usuario
  )
  returning * into fila;

  return to_jsonb(fila);
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception using errcode = '22023', message = 'La factura contiene cantidades o precios inválidos.';
end;
$$;

create or replace function public.actualizar_factura(factura jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  usuario uuid := (select auth.uid());
  negocio uuid;
  rol text;
  factura_id text;
  lineas jsonb;
  fecha_factura text;
  usa_itbis boolean;
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
      clienteid = nullif(left(coalesce(factura ->> 'clienteId', ''), 120), '')
  where id = factura_id
    and negocio_id = negocio
  returning * into fila;

  return to_jsonb(fila);
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception using errcode = '22023', message = 'La factura contiene cantidades o precios inválidos.';
end;
$$;

create or replace function public.anular_factura(factura_id text, motivo text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  usuario uuid := (select auth.uid());
  negocio uuid;
  rol text;
  motivo_limpio text := btrim(coalesce(motivo, ''));
  fila public.pc_facturas%rowtype;
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Se requiere una sesión autenticada.';
  end if;

  if nullif(btrim(coalesce(factura_id, '')), '') is null then
    raise exception using errcode = '22023', message = 'Falta identificar la factura.';
  end if;

  if char_length(motivo_limpio) < 5 or char_length(motivo_limpio) > 500 then
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
    raise exception using errcode = '42501', message = 'Solo un administrador puede anular facturas.';
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
    return to_jsonb(fila);
  end if;

  update public.pc_facturas
  set estado = 'anulada',
      notas = left(concat_ws(E'\n', nullif(notas, ''), '[ANULADA ' || current_date::text || '] ' || motivo_limpio), 2000)
  where id = factura_id
    and negocio_id = negocio
  returning * into fila;

  return to_jsonb(fila);
end;
$$;

revoke all on function public.crear_factura(jsonb) from public, anon;
grant execute on function public.crear_factura(jsonb) to authenticated;
revoke all on function public.actualizar_factura(jsonb) from public, anon;
grant execute on function public.actualizar_factura(jsonb) to authenticated;
revoke all on function public.anular_factura(text, text) from public, anon;
grant execute on function public.anular_factura(text, text) to authenticated;

-- Las facturas oficiales nunca se insertan, cambian ni borran directamente
-- desde el Data API. Los RPC anteriores validan el rol, recalculan los totales
-- y dejan el evento en la auditoría transaccional.
drop policy if exists facturas_operacion_inserta on public.pc_facturas;
drop policy if exists facturas_caja_actualiza on public.pc_facturas;
drop policy if exists facturas_admin_borra on public.pc_facturas;
revoke insert, update, delete on table public.pc_facturas from authenticated;

comment on table public.pc_factura_contadores is
  'Contador transaccional por clínica. No se expone al Data API de usuarios.';
comment on function public.crear_factura(jsonb) is
  'Valida, calcula e inserta una factura con número único reservado en el servidor.';
comment on function public.actualizar_factura(jsonb) is
  'Corrige una factura como administrador, recalculando importes y conservando su número.';
comment on function public.anular_factura(text, text) is
  'Anula una factura como administrador sin borrar ni reutilizar su número.';
