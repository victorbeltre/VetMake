-- VetMake · Nómina atómica, idempotente e inmutable
--
-- Los pagos a empleados son movimientos financieros. Se registran, importan
-- y anulan exclusivamente mediante RPC validadas; nunca se editan ni se
-- eliminan físicamente desde el Data API.

alter table public.pc_pagos
  add column if not exists estado text not null default 'pagado',
  add column if not exists registrado_por uuid references auth.users(id) on delete set null,
  add column if not exists anulado_en timestamptz,
  add column if not exists anulado_por uuid references auth.users(id) on delete set null,
  add column if not exists motivo_anulacion text;

-- Normaliza filas heredadas antes de activar las garantías nuevas. En el
-- proyecto de desarrollo la tabla está vacía, pero la migración también debe
-- poder ejecutarse sobre una clínica que conserve pagos anteriores.
update public.pc_pagos
set mensualidad = round(greatest(coalesce(mensualidad, 0), 0), 2),
    comisiones = round(greatest(coalesce(comisiones, 0), 0), 2),
    descuentos = round(least(
      greatest(coalesce(descuentos, 0), 0),
      greatest(coalesce(mensualidad, 0), 0) + greatest(coalesce(comisiones, 0), 0)
    ), 2),
    totalpagado = round(
      greatest(coalesce(mensualidad, 0), 0)
      + greatest(coalesce(comisiones, 0), 0)
      - least(
          greatest(coalesce(descuentos, 0), 0),
          greatest(coalesce(mensualidad, 0), 0) + greatest(coalesce(comisiones, 0), 0)
        ),
      2
    ),
    mes = case
      when coalesce(mes, '') ~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then mes
      else to_char(coalesce(created_at, statement_timestamp()) at time zone 'America/Santo_Domingo', 'YYYY-MM')
    end,
    fecha = case
      when coalesce(fecha, '') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then fecha
      else ((coalesce(created_at, statement_timestamp()) at time zone 'America/Santo_Domingo')::date)::text
    end,
    estado = case when estado = 'anulado' then 'anulado' else 'pagado' end;

update public.pc_pagos as pago
set empleadonombre = empleado.nombre
from public.pc_empleados as empleado
where pago.negocio_id = empleado.negocio_id
  and pago.empleadoid = empleado.id
  and nullif(btrim(coalesce(pago.empleadonombre, '')), '') is null;

alter table public.pc_pagos
  alter column mensualidad set default 0,
  alter column mensualidad set not null,
  alter column comisiones set default 0,
  alter column comisiones set not null,
  alter column descuentos set default 0,
  alter column descuentos set not null,
  alter column totalpagado set default 0,
  alter column totalpagado set not null,
  alter column estado set default 'pagado',
  alter column estado set not null;

alter table public.pc_pagos
  drop constraint if exists pc_pagos_estado_check,
  add constraint pc_pagos_estado_check
    check (estado in ('pagado', 'anulado')),
  drop constraint if exists pc_pagos_mes_check,
  add constraint pc_pagos_mes_check
    check (mes is null or mes ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  drop constraint if exists pc_pagos_fecha_check,
  add constraint pc_pagos_fecha_check
    check (fecha is null or fecha ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'),
  drop constraint if exists pc_pagos_montos_check,
  add constraint pc_pagos_montos_check
    check (
      mensualidad between 0 and 1000000000
      and comisiones between 0 and 1000000000
      and descuentos between 0 and 1000000000
      and totalpagado between 0 and 1000000000
      and totalpagado = round(mensualidad + comisiones - descuentos, 2)
    ),
  drop constraint if exists pc_pagos_notas_check,
  add constraint pc_pagos_notas_check
    check (notas is null or char_length(notas) <= 1000),
  drop constraint if exists pc_pagos_anulacion_check,
  add constraint pc_pagos_anulacion_check
    check (
      (estado = 'pagado' and anulado_en is null and anulado_por is null and motivo_anulacion is null)
      or
      (estado = 'anulado' and anulado_en is not null and char_length(btrim(coalesce(motivo_anulacion, ''))) between 5 and 500)
    );

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'pc_pagos_empleado_negocio_fkey'
      and conrelid = 'public.pc_pagos'::regclass
  ) then
    alter table public.pc_pagos
      add constraint pc_pagos_empleado_negocio_fkey
      foreign key (negocio_id, empleadoid)
      references public.pc_empleados (negocio_id, id)
      on update cascade on delete restrict
      not valid;
  end if;

  if not exists (
    select 1
    from public.pc_pagos as pago
    left join public.pc_empleados as empleado
      on empleado.negocio_id = pago.negocio_id
     and empleado.id = pago.empleadoid
    where pago.empleadoid is not null
      and empleado.id is null
  ) then
    alter table public.pc_pagos
      validate constraint pc_pagos_empleado_negocio_fkey;
  end if;
end
$$;

create unique index if not exists pc_pagos_un_pago_activo_mes_uidx
  on public.pc_pagos (negocio_id, empleadoid, mes)
  where estado = 'pagado' and empleadoid is not null and mes is not null;

create index if not exists pc_pagos_negocio_mes_estado_idx
  on public.pc_pagos (negocio_id, mes, estado);

create table if not exists private.vetmake_nomina_operaciones (
  negocio_id uuid not null references public.negocios(id) on delete cascade,
  operacion_id uuid not null,
  usuario_id uuid references auth.users(id) on delete set null,
  accion text not null check (accion in ('registrar', 'anular', 'importar')),
  solicitud jsonb not null,
  resultado jsonb,
  creada_en timestamptz not null default statement_timestamp(),
  primary key (negocio_id, operacion_id)
);

alter table private.vetmake_nomina_operaciones enable row level security;
revoke all on table private.vetmake_nomina_operaciones
  from public, anon, authenticated, service_role;

create index if not exists vetmake_nomina_operaciones_usuario_idx
  on private.vetmake_nomina_operaciones (usuario_id, creada_en);

create or replace function private.registrar_pago_nomina_impl(
  p_empleado_id text,
  p_mes text,
  p_comisiones_adicionales numeric,
  p_descuentos numeric,
  p_notas text,
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
  empleado public.pc_empleados%rowtype;
  operacion private.vetmake_nomina_operaciones%rowtype;
  empleado_id text := nullif(btrim(coalesce(p_empleado_id, '')), '');
  periodo text := btrim(coalesce(p_mes, ''));
  adicionales numeric := round(coalesce(p_comisiones_adicionales, 0), 2);
  descuentos_valor numeric := round(coalesce(p_descuentos, 0), 2);
  notas_valor text := nullif(btrim(coalesce(p_notas, '')), '');
  comisiones_automaticas numeric := 0;
  comisiones_total numeric;
  mensualidad_valor numeric;
  total_valor numeric;
  fecha_pago text;
  pago public.pc_pagos%rowtype;
  solicitud_actual jsonb;
  respuesta jsonb;
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Debes iniciar sesión para registrar nómina.';
  end if;
  if p_operacion_id is null then
    raise exception using errcode = '22023', message = 'Falta el identificador idempotente del pago.';
  end if;
  if empleado_id is null then
    raise exception using errcode = '22023', message = 'Falta identificar al empleado.';
  end if;
  if periodo !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
    raise exception using errcode = '22007', message = 'El período de nómina debe usar YYYY-MM.';
  end if;
  if adicionales < 0 or adicionales > 1000000000
     or descuentos_valor < 0 or descuentos_valor > 1000000000 then
    raise exception using errcode = '22023', message = 'Las comisiones adicionales o descuentos están fuera de rango.';
  end if;
  if notas_valor is not null and char_length(notas_valor) > 1000 then
    raise exception using errcode = '22023', message = 'La nota no puede superar 1,000 caracteres.';
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
    raise exception using errcode = '42501', message = 'Solo administración puede registrar nómina.';
  end if;

  solicitud_actual := jsonb_build_object(
    'empleadoId', empleado_id,
    'mes', periodo,
    'comisionesAdicionales', adicionales,
    'descuentos', descuentos_valor,
    'notas', notas_valor
  );

  insert into private.vetmake_nomina_operaciones (
    negocio_id, operacion_id, usuario_id, accion, solicitud
  ) values (
    negocio, p_operacion_id, usuario, 'registrar', solicitud_actual
  )
  on conflict (negocio_id, operacion_id) do nothing;

  select registro.*
  into operacion
  from private.vetmake_nomina_operaciones as registro
  where registro.negocio_id = negocio
    and registro.operacion_id = p_operacion_id
  for update;

  if not found or operacion.usuario_id is distinct from usuario then
    raise exception using errcode = '42501', message = 'La operación de nómina pertenece a otro usuario.';
  end if;
  if operacion.accion <> 'registrar' or operacion.solicitud is distinct from solicitud_actual then
    raise exception using errcode = '22023', message = 'El identificador de pago ya fue usado con otros datos.';
  end if;
  if operacion.resultado is not null then
    return operacion.resultado;
  end if;

  select fila.*
  into empleado
  from public.pc_empleados as fila
  where fila.negocio_id = negocio
    and fila.id = empleado_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'El empleado no existe en esta clínica.';
  end if;

  if exists (
    select 1
    from public.pc_pagos as existente
    where existente.negocio_id = negocio
      and existente.empleadoid = empleado.id
      and existente.mes = periodo
      and existente.estado = 'pagado'
  ) then
    raise exception using errcode = '23505', message = 'Ese empleado ya tiene un pago activo para el período seleccionado.';
  end if;

  select round(coalesce(sum(coalesce(venta.comision, 0)), 0), 2)
  into comisiones_automaticas
  from public.pc_ventas as venta
  where venta.negocio_id = negocio
    and coalesce(venta.estado, 'activa') <> 'anulada'
    and left(coalesce(venta.fecha, ''), 7) = periodo
    and (
      venta.empleadoid = empleado.id
      or (
        venta.empleadoid is null
        and nullif(btrim(coalesce(venta.recibidopor, '')), '') is not null
        and lower(btrim(venta.recibidopor)) = lower(btrim(coalesce(empleado.nombre, '')))
      )
    );

  mensualidad_valor := round(greatest(coalesce(empleado.mensualidad, 0), 0), 2);
  comisiones_total := round(comisiones_automaticas + adicionales, 2);
  total_valor := round(mensualidad_valor + comisiones_total - descuentos_valor, 2);
  if total_valor < 0 or total_valor > 1000000000 then
    raise exception using errcode = '22023', message = 'Los descuentos no pueden superar el salario y las comisiones del período.';
  end if;

  fecha_pago := ((statement_timestamp() at time zone zona)::date)::text;

  insert into public.pc_pagos (
    id, mes, empleadoid, empleadonombre, mensualidad, comisiones,
    descuentos, totalpagado, fecha, notas, negocio_id, estado,
    registrado_por
  ) values (
    'pag_' || replace(gen_random_uuid()::text, '-', ''),
    periodo,
    empleado.id,
    left(coalesce(nullif(btrim(empleado.nombre), ''), empleado.id), 180),
    mensualidad_valor,
    comisiones_total,
    descuentos_valor,
    total_valor,
    fecha_pago,
    notas_valor,
    negocio,
    'pagado',
    usuario
  )
  returning * into pago;

  respuesta := jsonb_build_object(
    'operacionId', p_operacion_id,
    'pago', to_jsonb(pago),
    'comisionesAutomaticas', comisiones_automaticas,
    'comisionesAdicionales', adicionales
  );

  update private.vetmake_nomina_operaciones
  set resultado = respuesta
  where negocio_id = negocio
    and operacion_id = p_operacion_id;

  return respuesta;
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception using errcode = '22023', message = 'Los montos de nómina no son válidos.';
end;
$$;

create or replace function private.anular_pago_nomina_impl(
  p_pago_id text,
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
  pago_id text := nullif(btrim(coalesce(p_pago_id, '')), '');
  motivo text := btrim(coalesce(p_motivo, ''));
  operacion private.vetmake_nomina_operaciones%rowtype;
  solicitud_actual jsonb;
  pago public.pc_pagos%rowtype;
  respuesta jsonb;
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Debes iniciar sesión para anular nómina.';
  end if;
  if p_operacion_id is null or pago_id is null then
    raise exception using errcode = '22023', message = 'Faltan datos para anular el pago.';
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
    raise exception using errcode = '42501', message = 'Solo administración puede anular nómina.';
  end if;

  solicitud_actual := jsonb_build_object('pagoId', pago_id, 'motivo', motivo);
  insert into private.vetmake_nomina_operaciones (
    negocio_id, operacion_id, usuario_id, accion, solicitud
  ) values (
    negocio, p_operacion_id, usuario, 'anular', solicitud_actual
  )
  on conflict (negocio_id, operacion_id) do nothing;

  select registro.*
  into operacion
  from private.vetmake_nomina_operaciones as registro
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
  into pago
  from public.pc_pagos as fila
  where fila.negocio_id = negocio
    and fila.id = pago_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'El pago no existe en esta clínica.';
  end if;
  if pago.estado = 'anulado' then
    raise exception using errcode = '22023', message = 'El pago ya está anulado.';
  end if;

  update public.pc_pagos
  set estado = 'anulado',
      anulado_en = statement_timestamp(),
      anulado_por = usuario,
      motivo_anulacion = motivo
  where negocio_id = negocio
    and id = pago_id
  returning * into pago;

  respuesta := jsonb_build_object(
    'operacionId', p_operacion_id,
    'pago', to_jsonb(pago)
  );

  update private.vetmake_nomina_operaciones
  set resultado = respuesta
  where negocio_id = negocio
    and operacion_id = p_operacion_id;

  return respuesta;
end;
$$;

create or replace function private.importar_pagos_nomina_impl(
  p_pagos jsonb,
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
  solicitud_actual jsonb;
  operacion private.vetmake_nomina_operaciones%rowtype;
  elemento record;
  fila jsonb;
  empleado public.pc_empleados%rowtype;
  empleado_token text;
  empleado_nombre text;
  coincidencias integer;
  periodo text;
  fecha_valor text;
  mensualidad_valor numeric;
  comisiones_valor numeric;
  descuentos_valor numeric;
  total_valor numeric;
  notas_valor text;
  pago public.pc_pagos%rowtype;
  resultados jsonb := '[]'::jsonb;
  respuesta jsonb;
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Debes iniciar sesión para importar nómina.';
  end if;
  if p_operacion_id is null then
    raise exception using errcode = '22023', message = 'Falta el identificador idempotente de la importación.';
  end if;
  if p_pagos is null or jsonb_typeof(p_pagos) <> 'array'
     or jsonb_array_length(p_pagos) < 1 or jsonb_array_length(p_pagos) > 200
     or pg_column_size(p_pagos) > 1048576 then
    raise exception using errcode = '22023', message = 'Cada lote debe contener entre 1 y 200 pagos válidos.';
  end if;
  if char_length(fuente) < 1 or char_length(fuente) > 500 then
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
    raise exception using errcode = '42501', message = 'Solo administración puede importar nómina.';
  end if;

  solicitud_actual := jsonb_build_object('pagos', p_pagos, 'fuente', fuente);
  insert into private.vetmake_nomina_operaciones (
    negocio_id, operacion_id, usuario_id, accion, solicitud
  ) values (
    negocio, p_operacion_id, usuario, 'importar', solicitud_actual
  )
  on conflict (negocio_id, operacion_id) do nothing;

  select registro.*
  into operacion
  from private.vetmake_nomina_operaciones as registro
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
    from jsonb_array_elements(p_pagos) with ordinality as entrada(valor, ordinalidad)
  loop
    begin
      fila := elemento.valor;
      if jsonb_typeof(fila) <> 'object' then
        raise exception using errcode = '22023', message = 'El pago debe ser un objeto.';
      end if;

      empleado_token := nullif(btrim(coalesce(
        fila ->> 'empleadoId', fila ->> 'empleadoid', fila ->> 'idEmpleado', ''
      )), '');
      empleado_nombre := nullif(btrim(coalesce(
        fila ->> 'empleadoNombre', fila ->> 'empleadonombre', fila ->> 'empleado', ''
      )), '');

      empleado := null;
      if empleado_token is not null then
        select registro.*
        into empleado
        from public.pc_empleados as registro
        where registro.negocio_id = negocio
          and registro.id = empleado_token
        for update;
      end if;

      if empleado.id is null and empleado_nombre is not null then
        select count(*)
        into coincidencias
        from public.pc_empleados as registro
        where registro.negocio_id = negocio
          and lower(btrim(coalesce(registro.nombre, ''))) = lower(empleado_nombre);

        if coincidencias <> 1 then
          raise exception using errcode = '22023', message = 'El nombre del empleado no identifica una sola ficha.';
        end if;

        select registro.*
        into empleado
        from public.pc_empleados as registro
        where registro.negocio_id = negocio
          and lower(btrim(coalesce(registro.nombre, ''))) = lower(empleado_nombre)
        for update;
      end if;

      if empleado.id is null then
        raise exception using errcode = 'P0002', message = 'No se encontró el empleado del pago.';
      end if;

      periodo := btrim(coalesce(fila ->> 'mes', fila ->> 'periodo', ''));
      if periodo !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
        raise exception using errcode = '22007', message = 'El período debe usar YYYY-MM.';
      end if;

      mensualidad_valor := round(coalesce(nullif(fila ->> 'mensualidad', '')::numeric, 0), 2);
      comisiones_valor := round(coalesce(nullif(fila ->> 'comisiones', '')::numeric, 0), 2);
      descuentos_valor := round(coalesce(nullif(fila ->> 'descuentos', '')::numeric, 0), 2);
      total_valor := round(mensualidad_valor + comisiones_valor - descuentos_valor, 2);
      if mensualidad_valor < 0 or mensualidad_valor > 1000000000
         or comisiones_valor < 0 or comisiones_valor > 1000000000
         or descuentos_valor < 0 or descuentos_valor > 1000000000
         or total_valor < 0 or total_valor > 1000000000 then
        raise exception using errcode = '22023', message = 'Los montos del pago están fuera de rango.';
      end if;

      fecha_valor := nullif(btrim(coalesce(fila ->> 'fecha', '')), '');
      if fecha_valor is not null then
        if fecha_valor !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
           or fecha_valor::date::text <> fecha_valor then
          raise exception using errcode = '22007', message = 'La fecha del pago no es válida.';
        end if;
      end if;

      notas_valor := nullif(btrim(coalesce(fila ->> 'notas', fila ->> 'nota', '')), '');
      if notas_valor is not null and char_length(notas_valor) > 1000 then
        raise exception using errcode = '22023', message = 'La nota no puede superar 1,000 caracteres.';
      end if;

      if exists (
        select 1
        from public.pc_pagos as existente
        where existente.negocio_id = negocio
          and existente.empleadoid = empleado.id
          and existente.mes = periodo
          and existente.estado = 'pagado'
      ) then
        raise exception using errcode = '23505', message = 'Ya existe un pago activo para ese empleado y período.';
      end if;

      insert into public.pc_pagos (
        id, mes, empleadoid, empleadonombre, mensualidad, comisiones,
        descuentos, totalpagado, fecha, notas, negocio_id, estado,
        registrado_por
      ) values (
        'pag_' || replace(gen_random_uuid()::text, '-', ''),
        periodo,
        empleado.id,
        left(coalesce(nullif(btrim(empleado.nombre), ''), empleado.id), 180),
        mensualidad_valor,
        comisiones_valor,
        descuentos_valor,
        total_valor,
        fecha_valor,
        notas_valor,
        negocio,
        'pagado',
        usuario
      )
      returning * into pago;

      resultados := resultados || jsonb_build_array(to_jsonb(pago));
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
    'pagos', resultados
  );

  update private.vetmake_nomina_operaciones
  set resultado = respuesta
  where negocio_id = negocio
    and operacion_id = p_operacion_id;

  return respuesta;
end;
$$;

create or replace function public.registrar_pago_nomina(
  p_empleado_id text,
  p_mes text,
  p_comisiones_adicionales numeric,
  p_descuentos numeric,
  p_notas text,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.registrar_pago_nomina_impl(
    p_empleado_id, p_mes, p_comisiones_adicionales,
    p_descuentos, p_notas, p_operacion_id
  );
$$;

create or replace function public.anular_pago_nomina(
  p_pago_id text,
  p_motivo text,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.anular_pago_nomina_impl(p_pago_id, p_motivo, p_operacion_id);
$$;

create or replace function public.importar_pagos_nomina(
  p_pagos jsonb,
  p_fuente text,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.importar_pagos_nomina_impl(p_pagos, p_fuente, p_operacion_id);
$$;

revoke all on function private.registrar_pago_nomina_impl(text, text, numeric, numeric, text, uuid)
  from public, anon, authenticated, service_role;
revoke all on function private.anular_pago_nomina_impl(text, text, uuid)
  from public, anon, authenticated, service_role;
revoke all on function private.importar_pagos_nomina_impl(jsonb, text, uuid)
  from public, anon, authenticated, service_role;

revoke all on function public.registrar_pago_nomina(text, text, numeric, numeric, text, uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.anular_pago_nomina(text, text, uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.importar_pagos_nomina(jsonb, text, uuid)
  from public, anon, authenticated, service_role;

grant usage on schema private to authenticated, service_role;
grant execute on function private.registrar_pago_nomina_impl(text, text, numeric, numeric, text, uuid)
  to authenticated, service_role;
grant execute on function private.anular_pago_nomina_impl(text, text, uuid)
  to authenticated, service_role;
grant execute on function private.importar_pagos_nomina_impl(jsonb, text, uuid)
  to authenticated, service_role;

grant execute on function public.registrar_pago_nomina(text, text, numeric, numeric, text, uuid)
  to authenticated;
grant execute on function public.anular_pago_nomina(text, text, uuid)
  to authenticated;
grant execute on function public.importar_pagos_nomina(jsonb, text, uuid)
  to authenticated;

drop policy if exists pagos_admin_inserta on public.pc_pagos;
drop policy if exists pagos_admin_actualiza on public.pc_pagos;
drop policy if exists pagos_admin_borra on public.pc_pagos;

revoke insert, update, delete on table public.pc_pagos from authenticated;
grant select on table public.pc_pagos to authenticated;

comment on table private.vetmake_nomina_operaciones is
  'Registro privado de idempotencia para pagos, anulaciones e importaciones de nómina.';
comment on function public.registrar_pago_nomina(text, text, numeric, numeric, text, uuid) is
  'Registra un pago único por empleado y período; calcula salario y comisiones en PostgreSQL.';
comment on function public.anular_pago_nomina(text, text, uuid) is
  'Anula un pago de nómina con motivo y auditoría, sin eliminar el documento financiero.';
comment on function public.importar_pagos_nomina(jsonb, text, uuid) is
  'Importa hasta 200 pagos históricos en una transacción idempotente y validada.';

notify pgrst, 'reload schema';
