-- VetMake · Equipo y accesos atómicos
--
-- La ficha de un empleado, su membresía y su rol de acceso deben cambiar en
-- una sola transacción. Los usuarios del navegador conservan únicamente
-- lectura directa; las mutaciones pasan por RPC idempotentes.

alter table public.pc_empleados
  add column if not exists updated_at timestamptz,
  add column if not exists updated_by uuid references auth.users(id) on delete set null,
  add column if not exists retirado_en timestamptz,
  add column if not exists retirado_por uuid references auth.users(id) on delete set null,
  add column if not exists motivo_retiro text;

update public.pc_empleados
set nombre = coalesce(nullif(btrim(nombre), ''), 'Empleado ' || id),
    cargo = nullif(btrim(coalesce(cargo, '')), ''),
    mensualidad = round(greatest(coalesce(mensualidad, 0), 0), 2),
    email = lower(nullif(btrim(coalesce(email, '')), '')),
    telefono = nullif(btrim(coalesce(telefono, '')), ''),
    rol = case
      when rol in ('admin', 'veterinario', 'groomer', 'caja') then rol
      else null
    end,
    activo = coalesce(activo, true),
    comision_pct = round(least(greatest(coalesce(comision_pct, 0), 0), 100), 2),
    tipo_pago = case
      when tipo_pago in ('mensual', 'comision', 'mixto') then tipo_pago
      else 'mixto'
    end,
    updated_at = coalesce(updated_at, created_at, statement_timestamp()),
    retirado_en = case
      when coalesce(activo, true) then null
      else coalesce(retirado_en, updated_at, created_at, statement_timestamp())
    end,
    retirado_por = case when coalesce(activo, true) then null else retirado_por end,
    motivo_retiro = case
      when coalesce(activo, true) then null
      else coalesce(nullif(btrim(coalesce(motivo_retiro, '')), ''), 'Estado inactivo heredado.')
    end;

alter table public.pc_empleados
  alter column nombre set not null,
  alter column mensualidad set default 0,
  alter column mensualidad set not null,
  alter column comision_pct set default 0,
  alter column comision_pct set not null,
  alter column tipo_pago set default 'mixto',
  alter column tipo_pago set not null,
  alter column updated_at set default statement_timestamp(),
  alter column updated_at set not null;

alter table public.pc_empleados
  drop constraint if exists pc_empleados_nombre_check,
  add constraint pc_empleados_nombre_check
    check (char_length(btrim(nombre)) between 1 and 180),
  drop constraint if exists pc_empleados_cargo_check,
  add constraint pc_empleados_cargo_check
    check (cargo is null or char_length(cargo) <= 180),
  drop constraint if exists pc_empleados_mensualidad_check,
  add constraint pc_empleados_mensualidad_check
    check (mensualidad between 0 and 1000000000),
  drop constraint if exists pc_empleados_comision_pct_check,
  add constraint pc_empleados_comision_pct_check
    check (comision_pct between 0 and 100),
  drop constraint if exists pc_empleados_email_check,
  add constraint pc_empleados_email_check
    check (
      email is null
      or (
        char_length(email) <= 320
        and email ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
      )
    ),
  drop constraint if exists pc_empleados_telefono_check,
  add constraint pc_empleados_telefono_check
    check (telefono is null or char_length(telefono) <= 50),
  drop constraint if exists pc_empleados_rol_check,
  add constraint pc_empleados_rol_check
    check (rol is null or rol in ('admin', 'veterinario', 'groomer', 'caja')),
  drop constraint if exists pc_empleados_tipo_pago_check,
  add constraint pc_empleados_tipo_pago_check
    check (tipo_pago in ('mensual', 'comision', 'mixto')),
  drop constraint if exists pc_empleados_acceso_check,
  add constraint pc_empleados_acceso_check
    check (usuario_id is null or (email is not null and rol is not null)),
  drop constraint if exists pc_empleados_retiro_check,
  add constraint pc_empleados_retiro_check
    check (
      (
        activo = true
        and retirado_en is null
        and retirado_por is null
        and motivo_retiro is null
      )
      or
      (
        activo = false
        and retirado_en is not null
        and char_length(btrim(coalesce(motivo_retiro, ''))) between 5 and 500
      )
    );

create unique index if not exists pc_empleados_negocio_email_uidx
  on public.pc_empleados (negocio_id, lower(btrim(email)))
  where email is not null;

create index if not exists pc_empleados_negocio_activo_idx
  on public.pc_empleados (negocio_id, activo);

create index if not exists pc_empleados_updated_by_idx
  on public.pc_empleados (updated_by);

create index if not exists pc_empleados_retirado_por_idx
  on public.pc_empleados (retirado_por);

create table if not exists private.vetmake_empleado_operaciones (
  negocio_id uuid not null references public.negocios(id) on delete cascade,
  operacion_id uuid not null,
  usuario_id uuid references auth.users(id) on delete set null,
  accion text not null check (accion in ('guardar', 'retirar', 'importar')),
  solicitud jsonb not null,
  resultado jsonb,
  creada_en timestamptz not null default statement_timestamp(),
  primary key (negocio_id, operacion_id)
);

alter table private.vetmake_empleado_operaciones enable row level security;
revoke all on table private.vetmake_empleado_operaciones
  from public, anon, authenticated, service_role;

drop policy if exists vetmake_empleado_operaciones_sin_acceso_cliente
  on private.vetmake_empleado_operaciones;
create policy vetmake_empleado_operaciones_sin_acceso_cliente
  on private.vetmake_empleado_operaciones
  for all
  to public
  using (false)
  with check (false);

create index if not exists vetmake_empleado_operaciones_usuario_idx
  on private.vetmake_empleado_operaciones (usuario_id, creada_en);

create or replace function private.normalizar_datos_empleado(p_datos jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  nombre text;
  cargo text;
  mensualidad numeric;
  email text;
  telefono text;
  rol text;
  activo_texto text;
  activo boolean;
  comision numeric;
  tipo_pago text;
begin
  if p_datos is null or jsonb_typeof(p_datos) <> 'object'
     or pg_column_size(p_datos) > 32768 then
    raise exception using errcode = '22023', message = 'Los datos del empleado no son válidos.';
  end if;

  nombre := nullif(btrim(coalesce(p_datos ->> 'nombre', '')), '');
  cargo := nullif(btrim(coalesce(p_datos ->> 'cargo', '')), '');
  email := lower(nullif(btrim(coalesce(p_datos ->> 'email', '')), ''));
  telefono := nullif(btrim(coalesce(p_datos ->> 'telefono', '')), '');
  rol := lower(nullif(btrim(coalesce(p_datos ->> 'rol', '')), ''));
  tipo_pago := lower(nullif(btrim(coalesce(
    p_datos ->> 'tipoPago', p_datos ->> 'tipo_pago', 'mixto'
  )), ''));

  mensualidad := round(coalesce(nullif(p_datos ->> 'mensualidad', '')::numeric, 0), 2);
  comision := round(coalesce(nullif(coalesce(
    p_datos ->> 'comisionPct', p_datos ->> 'comision_pct'
  ), '')::numeric, 0), 2);

  activo_texto := lower(btrim(coalesce(p_datos ->> 'activo', 'true')));
  if activo_texto in ('true', 't', '1', 'si', 'sí', 'yes') then
    activo := true;
  elsif activo_texto in ('false', 'f', '0', 'no') then
    activo := false;
  else
    raise exception using errcode = '22023', message = 'El estado activo del empleado no es válido.';
  end if;

  if nombre is null or char_length(nombre) > 180 then
    raise exception using errcode = '22023', message = 'El nombre del empleado es obligatorio y no puede superar 180 caracteres.';
  end if;
  if cargo is not null and char_length(cargo) > 180 then
    raise exception using errcode = '22023', message = 'El cargo no puede superar 180 caracteres.';
  end if;
  if mensualidad < 0 or mensualidad > 1000000000 then
    raise exception using errcode = '22023', message = 'La mensualidad está fuera de rango.';
  end if;
  if email is not null and (
    char_length(email) > 320
    or email !~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
  ) then
    raise exception using errcode = '22023', message = 'El correo del empleado no es válido.';
  end if;
  if telefono is not null and char_length(telefono) > 50 then
    raise exception using errcode = '22023', message = 'El teléfono no puede superar 50 caracteres.';
  end if;
  if rol is not null and rol not in ('admin', 'veterinario', 'groomer', 'caja') then
    raise exception using errcode = '22023', message = 'El rol del empleado no es válido.';
  end if;
  if comision < 0 or comision > 100 then
    raise exception using errcode = '22023', message = 'La comisión debe estar entre 0 y 100 por ciento.';
  end if;
  if tipo_pago not in ('mensual', 'comision', 'mixto') then
    raise exception using errcode = '22023', message = 'El tipo de pago no es válido.';
  end if;

  return jsonb_build_object(
    'nombre', nombre,
    'cargo', cargo,
    'mensualidad', mensualidad,
    'email', email,
    'telefono', telefono,
    'rol', rol,
    'activo', activo,
    'comisionPct', comision,
    'tipoPago', tipo_pago
  );
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception using errcode = '22023', message = 'La mensualidad o la comisión no son válidas.';
end;
$$;

create or replace function private.guardar_empleado_impl(
  p_empleado_id text,
  p_datos jsonb,
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
  rol_solicitante text;
  empleado_id text := nullif(btrim(coalesce(p_empleado_id, '')), '');
  datos jsonb;
  operacion private.vetmake_empleado_operaciones%rowtype;
  solicitud_actual jsonb;
  empleado public.pc_empleados%rowtype;
  membresia public.usuarios_negocio%rowtype;
  membresia_encontrada boolean := false;
  correo_auth text;
  respuesta jsonb;
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Debes iniciar sesión para gestionar empleados.';
  end if;
  if p_operacion_id is null then
    raise exception using errcode = '22023', message = 'Falta el identificador idempotente del empleado.';
  end if;

  datos := private.normalizar_datos_empleado(p_datos);

  select membresia_actual.negocio_id, membresia_actual.rol
  into negocio, rol_solicitante
  from public.usuarios_negocio as membresia_actual
  join public.negocios as clinica on clinica.id = membresia_actual.negocio_id
  where membresia_actual.usuario_id = usuario
    and membresia_actual.activo = true
    and clinica.activo = true;

  if negocio is null or rol_solicitante <> 'admin' then
    raise exception using errcode = '42501', message = 'Solo administración puede gestionar empleados.';
  end if;

  perform 1 from public.negocios where id = negocio for update;

  solicitud_actual := jsonb_build_object('empleadoId', empleado_id, 'datos', datos);
  insert into private.vetmake_empleado_operaciones (
    negocio_id, operacion_id, usuario_id, accion, solicitud
  ) values (
    negocio, p_operacion_id, usuario, 'guardar', solicitud_actual
  )
  on conflict (negocio_id, operacion_id) do nothing;

  select registro.*
  into operacion
  from private.vetmake_empleado_operaciones as registro
  where registro.negocio_id = negocio
    and registro.operacion_id = p_operacion_id
  for update;

  if not found or operacion.usuario_id is distinct from usuario then
    raise exception using errcode = '42501', message = 'La operación del empleado pertenece a otro usuario.';
  end if;
  if operacion.accion <> 'guardar' or operacion.solicitud is distinct from solicitud_actual then
    raise exception using errcode = '22023', message = 'El identificador del empleado ya fue usado con otros datos.';
  end if;
  if operacion.resultado is not null then
    return operacion.resultado;
  end if;

  if empleado_id is null then
    if not (datos ->> 'activo')::boolean then
      raise exception using errcode = '22023', message = 'Un empleado nuevo debe crearse activo.';
    end if;

    empleado_id := 'emp_' || replace(gen_random_uuid()::text, '-', '');
    insert into public.pc_empleados (
      id, nombre, cargo, mensualidad, negocio_id, usuario_id, email,
      telefono, rol, activo, comision_pct, tipo_pago, updated_at, updated_by
    ) values (
      empleado_id,
      datos ->> 'nombre',
      datos ->> 'cargo',
      (datos ->> 'mensualidad')::numeric,
      negocio,
      null,
      datos ->> 'email',
      datos ->> 'telefono',
      datos ->> 'rol',
      true,
      (datos ->> 'comisionPct')::numeric,
      datos ->> 'tipoPago',
      statement_timestamp(),
      usuario
    )
    returning * into empleado;
  else
    select fila.*
    into empleado
    from public.pc_empleados as fila
    where fila.negocio_id = negocio
      and fila.id = empleado_id
    for update;

    if not found then
      raise exception using errcode = 'P0002', message = 'El empleado no existe en esta clínica.';
    end if;

    if empleado.activo = true and not (datos ->> 'activo')::boolean then
      raise exception using errcode = '22023', message = 'Usa la opción Retirar para desactivar un empleado activo.';
    end if;

    if empleado.usuario_id is not null then
      select lower(btrim(cuenta.email))
      into correo_auth
      from auth.users as cuenta
      where cuenta.id = empleado.usuario_id;

      if correo_auth is null then
        raise exception using errcode = 'P0002', message = 'La cuenta Auth vinculada ya no existe.';
      end if;
      if (datos ->> 'email') is distinct from correo_auth then
        raise exception using errcode = '22023', message = 'El correo de un empleado vinculado debe cambiarse desde Supabase Auth.';
      end if;
      if nullif(datos ->> 'rol', '') is null then
        raise exception using errcode = '22023', message = 'Un empleado con acceso debe conservar un rol válido.';
      end if;
      if empleado.usuario_id = usuario
         and ((datos ->> 'rol') <> 'admin' or not (datos ->> 'activo')::boolean) then
        raise exception using errcode = '42501', message = 'No puedes retirar ni degradar tu propio acceso administrativo.';
      end if;

      select fila.*
      into membresia
      from public.usuarios_negocio as fila
      where fila.usuario_id = empleado.usuario_id
      for update;
      membresia_encontrada := found;

      if membresia_encontrada and membresia.negocio_id <> negocio then
        raise exception using errcode = '23505', message = 'La cuenta vinculada pertenece a otra clínica.';
      end if;

      if membresia_encontrada and membresia.activo = true and membresia.rol = 'admin'
         and ((datos ->> 'rol') <> 'admin' or not (datos ->> 'activo')::boolean)
         and not exists (
           select 1
           from public.usuarios_negocio as otro_admin
           where otro_admin.negocio_id = negocio
             and otro_admin.usuario_id <> empleado.usuario_id
             and otro_admin.rol = 'admin'
             and otro_admin.activo = true
         ) then
        raise exception using errcode = '42501', message = 'La clínica debe conservar al menos un administrador activo.';
      end if;

      if not membresia_encontrada then
        insert into public.usuarios_negocio (usuario_id, negocio_id, rol, activo)
        values (
          empleado.usuario_id,
          negocio,
          datos ->> 'rol',
          (datos ->> 'activo')::boolean
        )
        returning * into membresia;
      else
        update public.usuarios_negocio
        set rol = datos ->> 'rol',
            activo = (datos ->> 'activo')::boolean
        where usuario_id = empleado.usuario_id
          and negocio_id = negocio
        returning * into membresia;
      end if;
    end if;

    update public.pc_empleados
    set nombre = datos ->> 'nombre',
        cargo = datos ->> 'cargo',
        mensualidad = (datos ->> 'mensualidad')::numeric,
        email = case when empleado.usuario_id is null then datos ->> 'email' else correo_auth end,
        telefono = datos ->> 'telefono',
        rol = datos ->> 'rol',
        activo = (datos ->> 'activo')::boolean,
        comision_pct = (datos ->> 'comisionPct')::numeric,
        tipo_pago = datos ->> 'tipoPago',
        updated_at = statement_timestamp(),
        updated_by = usuario,
        retirado_en = case when (datos ->> 'activo')::boolean then null else retirado_en end,
        retirado_por = case when (datos ->> 'activo')::boolean then null else retirado_por end,
        motivo_retiro = case when (datos ->> 'activo')::boolean then null else motivo_retiro end
    where negocio_id = negocio
      and id = empleado_id
    returning * into empleado;
  end if;

  respuesta := jsonb_build_object(
    'operacionId', p_operacion_id,
    'empleado', to_jsonb(empleado)
  );

  update private.vetmake_empleado_operaciones
  set resultado = respuesta
  where negocio_id = negocio
    and operacion_id = p_operacion_id;

  return respuesta;
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception using errcode = '22023', message = 'Los datos numéricos del empleado no son válidos.';
end;
$$;

create or replace function private.retirar_empleado_impl(
  p_empleado_id text,
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
  rol_solicitante text;
  empleado_id text := nullif(btrim(coalesce(p_empleado_id, '')), '');
  motivo text := btrim(coalesce(p_motivo, ''));
  operacion private.vetmake_empleado_operaciones%rowtype;
  solicitud_actual jsonb;
  empleado public.pc_empleados%rowtype;
  membresia public.usuarios_negocio%rowtype;
  respuesta jsonb;
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Debes iniciar sesión para retirar empleados.';
  end if;
  if p_operacion_id is null or empleado_id is null then
    raise exception using errcode = '22023', message = 'Faltan datos para retirar el empleado.';
  end if;
  if char_length(motivo) < 5 or char_length(motivo) > 500 then
    raise exception using errcode = '22023', message = 'Indica un motivo de retiro de 5 a 500 caracteres.';
  end if;

  select membresia_actual.negocio_id, membresia_actual.rol
  into negocio, rol_solicitante
  from public.usuarios_negocio as membresia_actual
  join public.negocios as clinica on clinica.id = membresia_actual.negocio_id
  where membresia_actual.usuario_id = usuario
    and membresia_actual.activo = true
    and clinica.activo = true;

  if negocio is null or rol_solicitante <> 'admin' then
    raise exception using errcode = '42501', message = 'Solo administración puede retirar empleados.';
  end if;

  perform 1 from public.negocios where id = negocio for update;

  solicitud_actual := jsonb_build_object('empleadoId', empleado_id, 'motivo', motivo);
  insert into private.vetmake_empleado_operaciones (
    negocio_id, operacion_id, usuario_id, accion, solicitud
  ) values (
    negocio, p_operacion_id, usuario, 'retirar', solicitud_actual
  )
  on conflict (negocio_id, operacion_id) do nothing;

  select registro.*
  into operacion
  from private.vetmake_empleado_operaciones as registro
  where registro.negocio_id = negocio
    and registro.operacion_id = p_operacion_id
  for update;

  if not found or operacion.usuario_id is distinct from usuario then
    raise exception using errcode = '42501', message = 'La operación de retiro pertenece a otro usuario.';
  end if;
  if operacion.accion <> 'retirar' or operacion.solicitud is distinct from solicitud_actual then
    raise exception using errcode = '22023', message = 'El identificador de retiro ya fue usado con otros datos.';
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
  if empleado.activo = false then
    raise exception using errcode = '22023', message = 'El empleado ya está retirado.';
  end if;
  if empleado.usuario_id = usuario then
    raise exception using errcode = '42501', message = 'No puedes retirar tu propio acceso administrativo.';
  end if;

  if empleado.usuario_id is not null then
    select fila.*
    into membresia
    from public.usuarios_negocio as fila
    where fila.usuario_id = empleado.usuario_id
    for update;

    if found and membresia.negocio_id <> negocio then
      raise exception using errcode = '23505', message = 'La cuenta vinculada pertenece a otra clínica.';
    end if;
    if found and membresia.activo = true and membresia.rol = 'admin'
       and not exists (
         select 1
         from public.usuarios_negocio as otro_admin
         where otro_admin.negocio_id = negocio
           and otro_admin.usuario_id <> empleado.usuario_id
           and otro_admin.rol = 'admin'
           and otro_admin.activo = true
       ) then
      raise exception using errcode = '42501', message = 'La clínica debe conservar al menos un administrador activo.';
    end if;

    update public.usuarios_negocio
    set activo = false
    where usuario_id = empleado.usuario_id
      and negocio_id = negocio;
  end if;

  update public.pc_empleados
  set activo = false,
      updated_at = statement_timestamp(),
      updated_by = usuario,
      retirado_en = statement_timestamp(),
      retirado_por = usuario,
      motivo_retiro = motivo
  where negocio_id = negocio
    and id = empleado_id
  returning * into empleado;

  respuesta := jsonb_build_object(
    'operacionId', p_operacion_id,
    'empleado', to_jsonb(empleado)
  );

  update private.vetmake_empleado_operaciones
  set resultado = respuesta
  where negocio_id = negocio
    and operacion_id = p_operacion_id;

  return respuesta;
end;
$$;

create or replace function private.importar_empleados_impl(
  p_empleados jsonb,
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
  rol_solicitante text;
  fuente text := btrim(coalesce(p_fuente, ''));
  solicitud_actual jsonb;
  operacion private.vetmake_empleado_operaciones%rowtype;
  elemento record;
  datos jsonb;
  empleado public.pc_empleados%rowtype;
  resultados jsonb := '[]'::jsonb;
  respuesta jsonb;
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Debes iniciar sesión para importar empleados.';
  end if;
  if p_operacion_id is null then
    raise exception using errcode = '22023', message = 'Falta el identificador idempotente de la importación.';
  end if;
  if p_empleados is null or jsonb_typeof(p_empleados) <> 'array'
     or jsonb_array_length(p_empleados) < 1 or jsonb_array_length(p_empleados) > 200
     or pg_column_size(p_empleados) > 1048576 then
    raise exception using errcode = '22023', message = 'Cada lote debe contener entre 1 y 200 empleados válidos.';
  end if;
  if char_length(fuente) < 1 or char_length(fuente) > 500 then
    raise exception using errcode = '22023', message = 'La fuente de importación no es válida.';
  end if;

  select membresia_actual.negocio_id, membresia_actual.rol
  into negocio, rol_solicitante
  from public.usuarios_negocio as membresia_actual
  join public.negocios as clinica on clinica.id = membresia_actual.negocio_id
  where membresia_actual.usuario_id = usuario
    and membresia_actual.activo = true
    and clinica.activo = true;

  if negocio is null or rol_solicitante <> 'admin' then
    raise exception using errcode = '42501', message = 'Solo administración puede importar empleados.';
  end if;

  perform 1 from public.negocios where id = negocio for update;

  solicitud_actual := jsonb_build_object('empleados', p_empleados, 'fuente', fuente);
  insert into private.vetmake_empleado_operaciones (
    negocio_id, operacion_id, usuario_id, accion, solicitud
  ) values (
    negocio, p_operacion_id, usuario, 'importar', solicitud_actual
  )
  on conflict (negocio_id, operacion_id) do nothing;

  select registro.*
  into operacion
  from private.vetmake_empleado_operaciones as registro
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
    from jsonb_array_elements(p_empleados) with ordinality as entrada(valor, ordinalidad)
  loop
    begin
      datos := private.normalizar_datos_empleado(elemento.valor);

      insert into public.pc_empleados (
        id, nombre, cargo, mensualidad, negocio_id, usuario_id, email,
        telefono, rol, activo, comision_pct, tipo_pago, updated_at, updated_by,
        retirado_en, retirado_por, motivo_retiro
      ) values (
        'emp_' || replace(gen_random_uuid()::text, '-', ''),
        datos ->> 'nombre',
        datos ->> 'cargo',
        (datos ->> 'mensualidad')::numeric,
        negocio,
        null,
        datos ->> 'email',
        datos ->> 'telefono',
        datos ->> 'rol',
        (datos ->> 'activo')::boolean,
        (datos ->> 'comisionPct')::numeric,
        datos ->> 'tipoPago',
        statement_timestamp(),
        usuario,
        case when (datos ->> 'activo')::boolean then null else statement_timestamp() end,
        case when (datos ->> 'activo')::boolean then null else usuario end,
        case when (datos ->> 'activo')::boolean then null else 'Importado como empleado inactivo.' end
      )
      returning * into empleado;

      resultados := resultados || jsonb_build_array(to_jsonb(empleado));
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
    'empleados', resultados
  );

  update private.vetmake_empleado_operaciones
  set resultado = respuesta
  where negocio_id = negocio
    and operacion_id = p_operacion_id;

  return respuesta;
end;
$$;

create or replace function private.vincular_empleado_impl(
  p_solicitante uuid,
  p_empleado_id text,
  p_usuario_id uuid,
  p_email text,
  p_rol text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  negocio uuid;
  empleado public.pc_empleados%rowtype;
  membresia public.usuarios_negocio%rowtype;
  membresia_encontrada boolean := false;
  empleado_vinculado text;
  correo text := lower(nullif(btrim(coalesce(p_email, '')), ''));
  correo_auth text;
begin
  if p_solicitante is null or p_usuario_id is null
     or nullif(btrim(coalesce(p_empleado_id, '')), '') is null then
    raise exception using errcode = '22023', message = 'Faltan datos para vincular el acceso.';
  end if;
  if p_rol not in ('admin', 'caja', 'veterinario', 'groomer') then
    raise exception using errcode = '22023', message = 'El rol solicitado no es válido.';
  end if;
  if correo is null or correo !~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
    raise exception using errcode = '22023', message = 'El correo solicitado no es válido.';
  end if;

  select membresia_actual.negocio_id
  into negocio
  from public.usuarios_negocio as membresia_actual
  join public.negocios as clinica on clinica.id = membresia_actual.negocio_id
  where membresia_actual.usuario_id = p_solicitante
    and membresia_actual.rol = 'admin'
    and membresia_actual.activo = true
    and clinica.activo = true;

  if negocio is null then
    raise exception using errcode = '42501', message = 'Solo un administrador activo puede vincular personal.';
  end if;

  perform 1 from public.negocios where id = negocio for update;

  select lower(btrim(cuenta.email))
  into correo_auth
  from auth.users as cuenta
  where cuenta.id = p_usuario_id;

  if correo_auth is null or correo_auth <> correo then
    raise exception using errcode = '22023', message = 'El correo no coincide con la cuenta de Supabase Auth.';
  end if;

  select fila.*
  into empleado
  from public.pc_empleados as fila
  where fila.id = p_empleado_id
    and fila.negocio_id = negocio
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'El empleado no pertenece a este negocio.';
  end if;
  if empleado.activo = false then
    raise exception using errcode = '22023', message = 'Activa el empleado antes de darle acceso.';
  end if;
  if empleado.usuario_id is not null and empleado.usuario_id <> p_usuario_id then
    raise exception using errcode = '23505', message = 'Este empleado ya está vinculado a otro usuario.';
  end if;
  if exists (
    select 1
    from public.pc_empleados as otro_correo
    where otro_correo.negocio_id = negocio
      and otro_correo.id <> empleado.id
      and lower(btrim(coalesce(otro_correo.email, ''))) = correo
  ) then
    raise exception using errcode = '23505', message = 'Ese correo ya pertenece a otro empleado de la clínica.';
  end if;

  select fila.*
  into membresia
  from public.usuarios_negocio as fila
  where fila.usuario_id = p_usuario_id
  for update;
  membresia_encontrada := found;

  if membresia_encontrada and membresia.negocio_id <> negocio then
    raise exception using errcode = '23505', message = 'Ese usuario ya pertenece a otra clínica.';
  end if;

  select otro.id
  into empleado_vinculado
  from public.pc_empleados as otro
  where otro.negocio_id = negocio
    and otro.usuario_id = p_usuario_id
    and otro.id <> empleado.id
  limit 1
  for update;

  if empleado_vinculado is not null then
    raise exception using errcode = '23505', message = 'Ese usuario ya está vinculado a otro empleado de esta clínica.';
  end if;

  if not membresia_encontrada then
    insert into public.usuarios_negocio (usuario_id, negocio_id, rol, activo)
    values (p_usuario_id, negocio, p_rol, true)
    returning * into membresia;
  else
    update public.usuarios_negocio
    set rol = p_rol,
        activo = true
    where usuario_id = p_usuario_id
      and negocio_id = negocio
    returning * into membresia;
  end if;

  update public.pc_empleados
  set usuario_id = p_usuario_id,
      email = correo,
      rol = p_rol,
      activo = true,
      updated_at = statement_timestamp(),
      updated_by = p_solicitante,
      retirado_en = null,
      retirado_por = null,
      motivo_retiro = null
  where id = empleado.id
    and negocio_id = negocio
  returning * into empleado;

  return to_jsonb(empleado);
end;
$$;

create or replace function public.guardar_empleado(
  p_empleado_id text,
  p_datos jsonb,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.guardar_empleado_impl(p_empleado_id, p_datos, p_operacion_id);
$$;

create or replace function public.retirar_empleado(
  p_empleado_id text,
  p_motivo text,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.retirar_empleado_impl(p_empleado_id, p_motivo, p_operacion_id);
$$;

create or replace function public.importar_empleados(
  p_empleados jsonb,
  p_fuente text,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.importar_empleados_impl(p_empleados, p_fuente, p_operacion_id);
$$;

create or replace function public.vetmake_vincular_empleado(
  p_solicitante uuid,
  p_empleado_id text,
  p_usuario_id uuid,
  p_email text,
  p_rol text
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.vincular_empleado_impl(
    p_solicitante, p_empleado_id, p_usuario_id, p_email, p_rol
  );
$$;

revoke all on function private.normalizar_datos_empleado(jsonb)
  from public, anon, authenticated, service_role;
revoke all on function private.guardar_empleado_impl(text, jsonb, uuid)
  from public, anon, authenticated, service_role;
revoke all on function private.retirar_empleado_impl(text, text, uuid)
  from public, anon, authenticated, service_role;
revoke all on function private.importar_empleados_impl(jsonb, text, uuid)
  from public, anon, authenticated, service_role;
revoke all on function private.vincular_empleado_impl(uuid, text, uuid, text, text)
  from public, anon, authenticated, service_role;

revoke all on function public.guardar_empleado(text, jsonb, uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.retirar_empleado(text, text, uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.importar_empleados(jsonb, text, uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.vetmake_vincular_empleado(uuid, text, uuid, text, text)
  from public, anon, authenticated, service_role;

grant usage on schema private to authenticated, service_role;
grant execute on function private.guardar_empleado_impl(text, jsonb, uuid)
  to authenticated, service_role;
grant execute on function private.retirar_empleado_impl(text, text, uuid)
  to authenticated, service_role;
grant execute on function private.importar_empleados_impl(jsonb, text, uuid)
  to authenticated, service_role;
grant execute on function private.vincular_empleado_impl(uuid, text, uuid, text, text)
  to service_role;

grant execute on function public.guardar_empleado(text, jsonb, uuid)
  to authenticated;
grant execute on function public.retirar_empleado(text, text, uuid)
  to authenticated;
grant execute on function public.importar_empleados(jsonb, text, uuid)
  to authenticated;
grant execute on function public.vetmake_vincular_empleado(uuid, text, uuid, text, text)
  to service_role;

drop policy if exists empleados_admin_inserta on public.pc_empleados;
drop policy if exists empleados_admin_actualiza on public.pc_empleados;
drop policy if exists empleados_admin_borra on public.pc_empleados;
drop policy if exists negocio_escribe_sus_empleados on public.pc_empleados;
drop policy if exists negocio_actualiza_sus_empleados on public.pc_empleados;
drop policy if exists negocio_borra_sus_empleados on public.pc_empleados;

revoke insert, update, delete on table public.pc_empleados from authenticated;
grant select on table public.pc_empleados to authenticated;

comment on table private.vetmake_empleado_operaciones is
  'Idempotencia privada para altas, ediciones, retiros e importaciones de empleados.';
comment on function public.guardar_empleado(text, jsonb, uuid) is
  'Crea o actualiza una ficha y sincroniza su membresía vinculada en una transacción.';
comment on function public.retirar_empleado(text, text, uuid) is
  'Retira lógicamente un empleado y desactiva su membresía sin borrar historial ni Auth.';
comment on function public.importar_empleados(jsonb, text, uuid) is
  'Importa hasta 200 fichas de empleados en un lote atómico e idempotente.';

notify pgrst, 'reload schema';
