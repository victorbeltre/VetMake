-- VetMake · Gastos atómicos, idempotentes y auditables
--
-- Un gasto modifica reportes, cierres de caja y utilidad. Por eso no se crea,
-- corrige, anula ni importa directamente desde el Data API. Todas las
-- mutaciones pasan por RPC transaccionales que conservan la trazabilidad.

alter table public.pc_gastos
  add column if not exists estado text not null default 'activo',
  add column if not exists registrado_por uuid references auth.users(id) on delete set null,
  add column if not exists actualizado_en timestamptz not null default statement_timestamp(),
  add column if not exists actualizado_por uuid references auth.users(id) on delete set null,
  add column if not exists ultima_correccion_en timestamptz,
  add column if not exists ultima_correccion_por uuid references auth.users(id) on delete set null,
  add column if not exists motivo_correccion text,
  add column if not exists anulado_en timestamptz,
  add column if not exists anulado_por uuid references auth.users(id) on delete set null,
  add column if not exists motivo_anulacion text;

-- Las instalaciones anteriores pueden tener filas incompletas. Se conservan
-- como historial utilizable antes de exigir los invariantes de filas nuevas.
update public.pc_gastos
set fecha = case
      when btrim(coalesce(fecha, '')) ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
       and to_char(to_date(btrim(fecha), 'YYYY-MM-DD'), 'YYYY-MM-DD') = btrim(fecha)
        then btrim(fecha)
      else ((coalesce(created_at, statement_timestamp()) at time zone 'America/Santo_Domingo')::date)::text
    end,
    categoria = case lower(btrim(coalesce(categoria, '')))
      when 'alquiler' then 'alquiler'
      when 'renta' then 'alquiler'
      when 'insumo' then 'insumo'
      when 'insumos' then 'insumo'
      when 'compra' then 'insumo'
      when 'compras' then 'insumo'
      when 'nomina' then 'nomina'
      when 'nómina' then 'nomina'
      when 'equipo' then 'equipo'
      when 'herramienta' then 'equipo'
      when 'inversion' then 'inversion'
      when 'inversión' then 'inversion'
      when 'varios' then 'varios'
      when 'otros' then 'varios'
      else 'varios'
    end,
    descripcion = left(coalesce(nullif(btrim(descripcion), ''), 'Gasto histórico sin descripción'), 500),
    monto = round(greatest(coalesce(monto, 0), 0), 2),
    formapago = left(coalesce(nullif(lower(btrim(formapago)), ''), 'efectivo'), 50),
    proveedor = nullif(left(btrim(coalesce(proveedor, '')), 180), ''),
    notas = nullif(left(btrim(coalesce(notas, '')), 1000), ''),
    pagadopor = nullif(left(btrim(coalesce(pagadopor, '')), 180), ''),
    estado = case when estado = 'anulado' then 'anulado' else 'activo' end,
    actualizado_en = coalesce(actualizado_en, created_at, statement_timestamp()),
    anulado_en = case
      when estado = 'anulado' then coalesce(anulado_en, actualizado_en, created_at, statement_timestamp())
      else null
    end,
    motivo_anulacion = case
      when estado = 'anulado' then coalesce(nullif(left(btrim(coalesce(motivo_anulacion, '')), 500), ''), 'Anulación histórica sin motivo detallado.')
      else null
    end,
    anulado_por = case when estado = 'anulado' then anulado_por else null end,
    ultima_correccion_en = case when estado = 'anulado' then ultima_correccion_en else ultima_correccion_en end,
    ultima_correccion_por = case when estado = 'anulado' then ultima_correccion_por else ultima_correccion_por end,
    motivo_correccion = nullif(left(btrim(coalesce(motivo_correccion, '')), 500), '');

alter table public.pc_gastos
  alter column fecha set not null,
  alter column categoria set not null,
  alter column descripcion set not null,
  alter column monto set not null,
  alter column formapago set not null,
  alter column estado set not null,
  alter column actualizado_en set not null;

alter table public.pc_gastos
  drop constraint if exists pc_gastos_fecha_check,
  add constraint pc_gastos_fecha_check
    check (
      fecha ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
      and to_char(to_date(fecha, 'YYYY-MM-DD'), 'YYYY-MM-DD') = fecha
    ),
  drop constraint if exists pc_gastos_categoria_check,
  add constraint pc_gastos_categoria_check
    check (categoria in ('alquiler', 'insumo', 'nomina', 'equipo', 'inversion', 'varios')),
  drop constraint if exists pc_gastos_descripcion_check,
  add constraint pc_gastos_descripcion_check
    check (char_length(btrim(descripcion)) between 1 and 500),
  drop constraint if exists pc_gastos_monto_check,
  add constraint pc_gastos_monto_check
    check (monto between 0 and 1000000000 and monto = round(monto, 2)),
  drop constraint if exists pc_gastos_formapago_check,
  add constraint pc_gastos_formapago_check
    check (char_length(btrim(formapago)) between 1 and 50),
  drop constraint if exists pc_gastos_proveedor_check,
  add constraint pc_gastos_proveedor_check
    check (proveedor is null or char_length(proveedor) <= 180),
  drop constraint if exists pc_gastos_notas_check,
  add constraint pc_gastos_notas_check
    check (notas is null or char_length(notas) <= 1000),
  drop constraint if exists pc_gastos_estado_check,
  add constraint pc_gastos_estado_check
    check (estado in ('activo', 'anulado')),
  drop constraint if exists pc_gastos_correccion_check,
  add constraint pc_gastos_correccion_check
    check (
      ultima_correccion_en is null
      or char_length(btrim(coalesce(motivo_correccion, ''))) between 5 and 500
    ),
  drop constraint if exists pc_gastos_anulacion_check,
  add constraint pc_gastos_anulacion_check
    check (
      (estado = 'activo' and anulado_en is null and anulado_por is null and motivo_anulacion is null)
      or
      (estado = 'anulado' and anulado_en is not null and char_length(btrim(coalesce(motivo_anulacion, ''))) between 5 and 500)
    );

create index if not exists pc_gastos_negocio_fecha_estado_idx
  on public.pc_gastos (negocio_id, fecha desc, estado);
create index if not exists pc_gastos_registrado_por_idx
  on public.pc_gastos (registrado_por);
create index if not exists pc_gastos_actualizado_por_idx
  on public.pc_gastos (actualizado_por);
create index if not exists pc_gastos_anulado_por_idx
  on public.pc_gastos (anulado_por);

create table if not exists private.vetmake_gasto_operaciones (
  negocio_id uuid not null references public.negocios(id) on delete cascade,
  operacion_id uuid not null,
  usuario_id uuid references auth.users(id) on delete set null,
  accion text not null check (accion in ('guardar', 'anular', 'importar')),
  solicitud jsonb not null,
  resultado jsonb,
  creada_en timestamptz not null default statement_timestamp(),
  primary key (negocio_id, operacion_id)
);

alter table private.vetmake_gasto_operaciones enable row level security;
revoke all on table private.vetmake_gasto_operaciones
  from public, anon, authenticated, service_role;

drop policy if exists vetmake_gasto_operaciones_sin_acceso_cliente
  on private.vetmake_gasto_operaciones;
create policy vetmake_gasto_operaciones_sin_acceso_cliente
  on private.vetmake_gasto_operaciones
  for all
  to public
  using (false)
  with check (false);

create index if not exists vetmake_gasto_operaciones_usuario_idx
  on private.vetmake_gasto_operaciones (usuario_id, creada_en);

create or replace function private.normalizar_datos_gasto(
  p_datos jsonb,
  p_requiere_responsable boolean default true
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  fecha_valor text;
  categoria_valor text;
  descripcion_valor text;
  monto_valor numeric;
  forma_pago_valor text;
  proveedor_valor text;
  notas_valor text;
  pagado_por_valor text;
begin
  if p_datos is null or jsonb_typeof(p_datos) <> 'object' or pg_column_size(p_datos) > 65536 then
    raise exception using errcode = '22023', message = 'El gasto no tiene un formato válido.';
  end if;

  fecha_valor := btrim(coalesce(p_datos ->> 'fecha', ''));
  if fecha_valor !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
     or to_char(to_date(fecha_valor, 'YYYY-MM-DD'), 'YYYY-MM-DD') <> fecha_valor then
    raise exception using errcode = '22007', message = 'La fecha del gasto debe usar YYYY-MM-DD y ser válida.';
  end if;

  categoria_valor := lower(btrim(coalesce(p_datos ->> 'categoria', '')));
  categoria_valor := case categoria_valor
    when 'renta' then 'alquiler'
    when 'insumos' then 'insumo'
    when 'compra' then 'insumo'
    when 'compras' then 'insumo'
    when 'nómina' then 'nomina'
    when 'herramienta' then 'equipo'
    when 'inversión' then 'inversion'
    when 'otros' then 'varios'
    else categoria_valor
  end;
  if categoria_valor not in ('alquiler', 'insumo', 'nomina', 'equipo', 'inversion', 'varios') then
    raise exception using errcode = '22023', message = 'La categoría del gasto no es válida.';
  end if;

  descripcion_valor := nullif(btrim(coalesce(p_datos ->> 'descripcion', '')), '');
  if descripcion_valor is null or char_length(descripcion_valor) > 500 then
    raise exception using errcode = '22023', message = 'La descripción del gasto es obligatoria y no puede superar 500 caracteres.';
  end if;

  monto_valor := round(nullif(btrim(coalesce(p_datos ->> 'monto', '')), '')::numeric, 2);
  if monto_valor is null or monto_valor <= 0 or monto_valor > 1000000000 then
    raise exception using errcode = '22023', message = 'El monto del gasto debe ser mayor que cero y estar dentro del rango permitido.';
  end if;

  forma_pago_valor := lower(nullif(btrim(coalesce(
    p_datos ->> 'formaPago', p_datos ->> 'formapago', p_datos ->> 'metodo', ''
  )), ''));
  if forma_pago_valor is null or char_length(forma_pago_valor) > 50 then
    raise exception using errcode = '22023', message = 'La forma de pago es obligatoria y no puede superar 50 caracteres.';
  end if;

  proveedor_valor := nullif(btrim(coalesce(p_datos ->> 'proveedor', '')), '');
  if proveedor_valor is not null and char_length(proveedor_valor) > 180 then
    raise exception using errcode = '22023', message = 'El proveedor no puede superar 180 caracteres.';
  end if;

  notas_valor := nullif(btrim(coalesce(p_datos ->> 'notas', '')), '');
  if notas_valor is not null and char_length(notas_valor) > 1000 then
    raise exception using errcode = '22023', message = 'Las notas no pueden superar 1,000 caracteres.';
  end if;

  pagado_por_valor := nullif(btrim(coalesce(
    p_datos ->> 'pagadoPor', p_datos ->> 'pagadopor', p_datos ->> 'responsable', ''
  )), '');
  if pagado_por_valor is not null and char_length(pagado_por_valor) > 180 then
    raise exception using errcode = '22023', message = 'El responsable no puede superar 180 caracteres.';
  end if;
  if p_requiere_responsable and pagado_por_valor is null then
    raise exception using errcode = '22023', message = 'Indica quién realizó el pago.';
  end if;

  return jsonb_build_object(
    'fecha', fecha_valor,
    'categoria', categoria_valor,
    'descripcion', descripcion_valor,
    'monto', monto_valor,
    'formaPago', forma_pago_valor,
    'proveedor', proveedor_valor,
    'notas', notas_valor,
    'pagadoPor', pagado_por_valor
  );
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception using errcode = '22023', message = 'El monto del gasto no es válido.';
end;
$$;

create or replace function private.guardar_gasto_impl(
  p_gasto_id text,
  p_gasto jsonb,
  p_motivo_correccion text,
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
  gasto_id text := nullif(btrim(coalesce(p_gasto_id, '')), '');
  motivo text := nullif(btrim(coalesce(p_motivo_correccion, '')), '');
  datos jsonb;
  operacion private.vetmake_gasto_operaciones%rowtype;
  solicitud_actual jsonb;
  gasto public.pc_gastos%rowtype;
  respuesta jsonb;
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Debes iniciar sesión para registrar gastos.';
  end if;
  if p_operacion_id is null then
    raise exception using errcode = '22023', message = 'Falta el identificador idempotente del gasto.';
  end if;

  datos := private.normalizar_datos_gasto(p_gasto, true);
  if gasto_id is not null and (motivo is null or char_length(motivo) not between 5 and 500) then
    raise exception using errcode = '22023', message = 'Indica un motivo de corrección de 5 a 500 caracteres.';
  end if;

  select membresia.negocio_id, membresia.rol
  into negocio, rol
  from public.usuarios_negocio as membresia
  join public.negocios as clinica on clinica.id = membresia.negocio_id
  where membresia.usuario_id = usuario
    and membresia.activo = true
    and clinica.activo = true;

  if negocio is null or rol not in ('admin', 'caja') then
    raise exception using errcode = '42501', message = 'Solo Administración o Caja pueden registrar y corregir gastos.';
  end if;

  solicitud_actual := jsonb_build_object(
    'gastoId', gasto_id,
    'datos', datos,
    'motivoCorreccion', motivo
  );
  insert into private.vetmake_gasto_operaciones (
    negocio_id, operacion_id, usuario_id, accion, solicitud
  ) values (
    negocio, p_operacion_id, usuario, 'guardar', solicitud_actual
  )
  on conflict (negocio_id, operacion_id) do nothing;

  select registro.*
  into operacion
  from private.vetmake_gasto_operaciones as registro
  where registro.negocio_id = negocio
    and registro.operacion_id = p_operacion_id
  for update;

  if not found or operacion.usuario_id is distinct from usuario then
    raise exception using errcode = '42501', message = 'La operación de gasto pertenece a otro usuario.';
  end if;
  if operacion.accion <> 'guardar' or operacion.solicitud is distinct from solicitud_actual then
    raise exception using errcode = '22023', message = 'El identificador del gasto ya fue usado con otros datos.';
  end if;
  if operacion.resultado is not null then
    return operacion.resultado;
  end if;

  if gasto_id is null then
    insert into public.pc_gastos (
      id, fecha, categoria, descripcion, monto, formapago, proveedor, notas,
      pagadopor, negocio_id, estado, registrado_por, actualizado_en, actualizado_por
    ) values (
      'gas_' || replace(gen_random_uuid()::text, '-', ''),
      datos ->> 'fecha',
      datos ->> 'categoria',
      datos ->> 'descripcion',
      (datos ->> 'monto')::numeric,
      datos ->> 'formaPago',
      datos ->> 'proveedor',
      datos ->> 'notas',
      datos ->> 'pagadoPor',
      negocio,
      'activo',
      usuario,
      statement_timestamp(),
      usuario
    )
    returning * into gasto;
  else
    select fila.*
    into gasto
    from public.pc_gastos as fila
    where fila.negocio_id = negocio
      and fila.id = gasto_id
    for update;

    if not found then
      raise exception using errcode = 'P0002', message = 'El gasto no existe en esta clínica.';
    end if;
    if gasto.estado = 'anulado' then
      raise exception using errcode = '22023', message = 'Un gasto anulado no puede corregirse.';
    end if;

    update public.pc_gastos
    set fecha = datos ->> 'fecha',
        categoria = datos ->> 'categoria',
        descripcion = datos ->> 'descripcion',
        monto = (datos ->> 'monto')::numeric,
        formapago = datos ->> 'formaPago',
        proveedor = datos ->> 'proveedor',
        notas = datos ->> 'notas',
        pagadopor = datos ->> 'pagadoPor',
        actualizado_en = statement_timestamp(),
        actualizado_por = usuario,
        ultima_correccion_en = statement_timestamp(),
        ultima_correccion_por = usuario,
        motivo_correccion = motivo
    where negocio_id = negocio
      and id = gasto_id
    returning * into gasto;
  end if;

  respuesta := jsonb_build_object(
    'operacionId', p_operacion_id,
    'gasto', to_jsonb(gasto)
  );
  update private.vetmake_gasto_operaciones
  set resultado = respuesta
  where negocio_id = negocio
    and operacion_id = p_operacion_id;

  return respuesta;
end;
$$;

create or replace function private.anular_gasto_impl(
  p_gasto_id text,
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
  gasto_id text := nullif(btrim(coalesce(p_gasto_id, '')), '');
  motivo text := btrim(coalesce(p_motivo, ''));
  operacion private.vetmake_gasto_operaciones%rowtype;
  solicitud_actual jsonb;
  gasto public.pc_gastos%rowtype;
  respuesta jsonb;
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Debes iniciar sesión para anular gastos.';
  end if;
  if p_operacion_id is null or gasto_id is null then
    raise exception using errcode = '22023', message = 'Faltan datos para anular el gasto.';
  end if;
  if char_length(motivo) not between 5 and 500 then
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
    raise exception using errcode = '42501', message = 'Solo Administración puede anular gastos.';
  end if;

  solicitud_actual := jsonb_build_object('gastoId', gasto_id, 'motivo', motivo);
  insert into private.vetmake_gasto_operaciones (
    negocio_id, operacion_id, usuario_id, accion, solicitud
  ) values (
    negocio, p_operacion_id, usuario, 'anular', solicitud_actual
  )
  on conflict (negocio_id, operacion_id) do nothing;

  select registro.*
  into operacion
  from private.vetmake_gasto_operaciones as registro
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

  select fila.*
  into gasto
  from public.pc_gastos as fila
  where fila.negocio_id = negocio
    and fila.id = gasto_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'El gasto no existe en esta clínica.';
  end if;
  if gasto.estado = 'anulado' then
    raise exception using errcode = '22023', message = 'El gasto ya está anulado.';
  end if;

  update public.pc_gastos
  set estado = 'anulado',
      actualizado_en = statement_timestamp(),
      actualizado_por = usuario,
      anulado_en = statement_timestamp(),
      anulado_por = usuario,
      motivo_anulacion = motivo
  where negocio_id = negocio
    and id = gasto_id
  returning * into gasto;

  respuesta := jsonb_build_object(
    'operacionId', p_operacion_id,
    'gasto', to_jsonb(gasto)
  );
  update private.vetmake_gasto_operaciones
  set resultado = respuesta
  where negocio_id = negocio
    and operacion_id = p_operacion_id;

  return respuesta;
end;
$$;

create or replace function private.importar_gastos_impl(
  p_gastos jsonb,
  p_fuente text,
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
  fuente text := btrim(coalesce(p_fuente, ''));
  operacion private.vetmake_gasto_operaciones%rowtype;
  solicitud_actual jsonb;
  elemento record;
  datos jsonb;
  gasto public.pc_gastos%rowtype;
  resultados jsonb := '[]'::jsonb;
  respuesta jsonb;
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Debes iniciar sesión para importar gastos.';
  end if;
  if p_operacion_id is null then
    raise exception using errcode = '22023', message = 'Falta el identificador idempotente de la importación.';
  end if;
  if p_gastos is null or jsonb_typeof(p_gastos) <> 'array'
     or jsonb_array_length(p_gastos) < 1 or jsonb_array_length(p_gastos) > 200
     or pg_column_size(p_gastos) > 1048576 then
    raise exception using errcode = '22023', message = 'Cada lote debe contener entre 1 y 200 gastos válidos.';
  end if;
  if char_length(fuente) not between 1 and 500 then
    raise exception using errcode = '22023', message = 'La fuente de importación no es válida.';
  end if;

  select membresia.negocio_id, membresia.rol
  into negocio, rol
  from public.usuarios_negocio as membresia
  join public.negocios as clinica on clinica.id = membresia.negocio_id
  where membresia.usuario_id = usuario
    and membresia.activo = true
    and clinica.activo = true;

  if negocio is null or rol <> 'admin' then
    raise exception using errcode = '42501', message = 'Solo Administración puede importar gastos.';
  end if;

  solicitud_actual := jsonb_build_object('gastos', p_gastos, 'fuente', fuente);
  insert into private.vetmake_gasto_operaciones (
    negocio_id, operacion_id, usuario_id, accion, solicitud
  ) values (
    negocio, p_operacion_id, usuario, 'importar', solicitud_actual
  )
  on conflict (negocio_id, operacion_id) do nothing;

  select registro.*
  into operacion
  from private.vetmake_gasto_operaciones as registro
  where registro.negocio_id = negocio
    and registro.operacion_id = p_operacion_id
  for update;

  if not found or operacion.usuario_id is distinct from usuario then
    raise exception using errcode = '42501', message = 'La importación pertenece a otro usuario.';
  end if;
  if operacion.accion <> 'importar' or operacion.solicitud is distinct from solicitud_actual then
    raise exception using errcode = '22023', message = 'El identificador de importación ya fue usado con otros datos.';
  end if;
  if operacion.resultado is not null then
    return operacion.resultado;
  end if;

  for elemento in
    select valor, ordinalidad
    from jsonb_array_elements(p_gastos) with ordinality as entrada(valor, ordinalidad)
  loop
    begin
      datos := private.normalizar_datos_gasto(elemento.valor, false);
      insert into public.pc_gastos (
        id, fecha, categoria, descripcion, monto, formapago, proveedor, notas,
        pagadopor, negocio_id, estado, registrado_por, actualizado_en, actualizado_por
      ) values (
        'gas_' || replace(gen_random_uuid()::text, '-', ''),
        datos ->> 'fecha',
        datos ->> 'categoria',
        datos ->> 'descripcion',
        (datos ->> 'monto')::numeric,
        datos ->> 'formaPago',
        datos ->> 'proveedor',
        datos ->> 'notas',
        datos ->> 'pagadoPor',
        negocio,
        'activo',
        usuario,
        statement_timestamp(),
        usuario
      )
      returning * into gasto;
      resultados := resultados || jsonb_build_array(to_jsonb(gasto));
    exception
      when others then
        raise exception using
          errcode = sqlstate,
          message = format('Fila %s: %s', elemento.ordinalidad, sqlerrm);
    end;
  end loop;

  respuesta := jsonb_build_object(
    'operacionId', p_operacion_id,
    'fuente', fuente,
    'cantidad', jsonb_array_length(resultados),
    'gastos', resultados
  );
  update private.vetmake_gasto_operaciones
  set resultado = respuesta
  where negocio_id = negocio
    and operacion_id = p_operacion_id;

  return respuesta;
end;
$$;

create or replace function public.guardar_gasto(
  p_gasto_id text,
  p_gasto jsonb,
  p_motivo_correccion text,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.guardar_gasto_impl(p_gasto_id, p_gasto, p_motivo_correccion, p_operacion_id);
$$;

create or replace function public.anular_gasto(
  p_gasto_id text,
  p_motivo text,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.anular_gasto_impl(p_gasto_id, p_motivo, p_operacion_id);
$$;

create or replace function public.importar_gastos(
  p_gastos jsonb,
  p_fuente text,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.importar_gastos_impl(p_gastos, p_fuente, p_operacion_id);
$$;

revoke all on function private.normalizar_datos_gasto(jsonb, boolean)
  from public, anon, authenticated, service_role;
revoke all on function private.guardar_gasto_impl(text, jsonb, text, uuid)
  from public, anon, authenticated, service_role;
revoke all on function private.anular_gasto_impl(text, text, uuid)
  from public, anon, authenticated, service_role;
revoke all on function private.importar_gastos_impl(jsonb, text, uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.guardar_gasto(text, jsonb, text, uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.anular_gasto(text, text, uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.importar_gastos(jsonb, text, uuid)
  from public, anon, authenticated, service_role;

grant usage on schema private to authenticated, service_role;
grant execute on function private.guardar_gasto_impl(text, jsonb, text, uuid)
  to authenticated, service_role;
grant execute on function private.anular_gasto_impl(text, text, uuid)
  to authenticated, service_role;
grant execute on function private.importar_gastos_impl(jsonb, text, uuid)
  to authenticated, service_role;
grant execute on function public.guardar_gasto(text, jsonb, text, uuid)
  to authenticated;
grant execute on function public.anular_gasto(text, text, uuid)
  to authenticated;
grant execute on function public.importar_gastos(jsonb, text, uuid)
  to authenticated;

drop policy if exists gastos_administracion_inserta on public.pc_gastos;
drop policy if exists gastos_administracion_actualiza on public.pc_gastos;
drop policy if exists gastos_admin_borra on public.pc_gastos;

revoke insert, update, delete on table public.pc_gastos from authenticated;
grant select on table public.pc_gastos to authenticated;

comment on table private.vetmake_gasto_operaciones is
  'Registro privado de idempotencia para altas, correcciones, anulaciones e importaciones de gastos.';
comment on function public.guardar_gasto(text, jsonb, text, uuid) is
  'Registra o corrige un gasto confirmado; las correcciones quedan auditadas y requieren motivo.';
comment on function public.anular_gasto(text, text, uuid) is
  'Anula un gasto sin borrarlo físicamente y conserva el motivo financiero.';
comment on function public.importar_gastos(jsonb, text, uuid) is
  'Importa hasta 200 gastos en una sola transacción idempotente.';

notify pgrst, 'reload schema';
