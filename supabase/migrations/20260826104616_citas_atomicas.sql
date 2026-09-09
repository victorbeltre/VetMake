-- Agenda confirmada por servidor.
--
-- Las altas y ediciones reciben un UUID de idempotencia, asignan el ID en
-- PostgreSQL y validan todos los campos antes de tocar pc_citas. De esta forma
-- una respuesta de red perdida no duplica citas y el navegador nunca necesita
-- inventar IDs con Date.now().

create sequence if not exists private.pc_citas_id_seq as bigint;

select pg_catalog.setval(
  'private.pc_citas_id_seq',
  greatest(
    (extract(epoch from clock_timestamp()) * 1000)::bigint,
    coalesce((select max(id) + 1 from public.pc_citas), 1)
  ),
  false
);

revoke all on sequence private.pc_citas_id_seq from public, anon, authenticated;

create table if not exists private.vetmake_cita_operaciones (
  negocio_id uuid not null references public.negocios(id) on delete cascade,
  operacion_id uuid not null,
  usuario_id uuid references auth.users(id) on delete set null,
  accion text not null check (accion in ('guardar', 'eliminar')),
  cita_id bigint not null,
  resultado jsonb not null,
  creada_en timestamptz not null default now(),
  primary key (negocio_id, operacion_id)
);

create index if not exists vetmake_cita_operaciones_creada_idx
  on private.vetmake_cita_operaciones (creada_en);

revoke all on table private.vetmake_cita_operaciones from public, anon, authenticated;

create or replace function private.guardar_cita_atomica_impl(
  p_cita jsonb,
  p_operacion_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  usuario uuid := auth.uid();
  negocio uuid;
  rol text;
  operacion_previa private.vetmake_cita_operaciones%rowtype;
  cita_previa public.pc_citas%rowtype;
  cita_guardada public.pc_citas%rowtype;
  cita_id bigint;
  cita_id_texto text;
  fecha_texto text;
  fecha_valida date;
  hora_texto text;
  duracion_valor integer;
  tipo_valor text;
  estado_valor text;
  cliente_id bigint;
  cliente_id_texto text;
  empleado_valor text;
  empleado_propio public.pc_empleados%rowtype;
  nombre_cliente text;
  nombre_mascota text;
  telefono_valor text;
  servicio_valor text;
  precio_valor numeric(14,2);
  notas_valor text;
  motivo_valor text;
  mensajes_valor jsonb;
  espera_solicitada boolean;
  conflicto boolean := false;
  inicio_nuevo integer;
  resultado jsonb;
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Debes iniciar sesión para gestionar citas.';
  end if;
  if p_operacion_id is null then
    raise exception using errcode = '22023', message = 'Falta el identificador idempotente de la operación.';
  end if;
  if p_cita is null or jsonb_typeof(p_cita) <> 'object' then
    raise exception using errcode = '22023', message = 'La cita no tiene un formato válido.';
  end if;

  negocio := public.mi_negocio();
  rol := public.mi_rol();
  if negocio is null or rol is null then
    raise exception using errcode = '42501', message = 'Tu sesión no pertenece a un negocio activo.';
  end if;
  if rol <> all (array['admin','caja','veterinario','groomer']::text[]) then
    raise exception using errcode = '42501', message = 'Tu rol no puede gestionar la agenda.';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(negocio::text || ':' || p_operacion_id::text, 0)
  );

  select operacion.*
  into operacion_previa
  from private.vetmake_cita_operaciones as operacion
  where operacion.negocio_id = negocio
    and operacion.operacion_id = p_operacion_id;
  if found then
    if operacion_previa.accion <> 'guardar' then
      raise exception using errcode = '22023', message = 'El identificador de operación ya se usó para otra acción.';
    end if;
    return operacion_previa.resultado;
  end if;

  fecha_texto := btrim(coalesce(p_cita ->> 'fecha', ''));
  if fecha_texto !~ '^\d{4}-\d{2}-\d{2}$' then
    raise exception using errcode = '22007', message = 'La fecha de la cita debe usar YYYY-MM-DD.';
  end if;
  begin
    fecha_valida := fecha_texto::date;
  exception when others then
    raise exception using errcode = '22007', message = 'La fecha de la cita no existe.';
  end;
  if fecha_valida::text <> fecha_texto then
    raise exception using errcode = '22007', message = 'La fecha de la cita no existe.';
  end if;

  hora_texto := btrim(coalesce(p_cita ->> 'hora', ''));
  if hora_texto !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    raise exception using errcode = '22007', message = 'La hora debe usar el formato HH:MM.';
  end if;

  if coalesce(p_cita ->> 'duracion', '') !~ '^\d{1,4}$' then
    raise exception using errcode = '22023', message = 'La duración debe ser un número entero de minutos.';
  end if;
  duracion_valor := (p_cita ->> 'duracion')::integer;
  if duracion_valor < 5 or duracion_valor > 720 then
    raise exception using errcode = '22023', message = 'La duración debe estar entre 5 y 720 minutos.';
  end if;

  tipo_valor := lower(btrim(coalesce(p_cita ->> 'tipo', 'grooming')));
  if tipo_valor <> all (array['grooming','consulta','veterinaria','recogida','seguimiento','otro']::text[]) then
    raise exception using errcode = '22023', message = 'El tipo de cita no es válido.';
  end if;

  estado_valor := lower(btrim(coalesce(p_cita ->> 'estado', 'pendiente')));
  if estado_valor <> all (array['pendiente','confirmada','completada','cancelada','noshow']::text[]) then
    raise exception using errcode = '22023', message = 'El estado de la cita no es válido.';
  end if;

  cita_id_texto := nullif(btrim(coalesce(p_cita ->> 'id', '')), '');
  if cita_id_texto is null or cita_id_texto = 'nuevo' then
    cita_id := nextval('private.pc_citas_id_seq');
  else
    if cita_id_texto !~ '^\d{1,19}$' then
      raise exception using errcode = '22023', message = 'El identificador de la cita no es válido.';
    end if;
    begin
      cita_id := cita_id_texto::bigint;
    exception when numeric_value_out_of_range then
      raise exception using errcode = '22003', message = 'El identificador de la cita está fuera de rango.';
    end;
    select cita.*
    into cita_previa
    from public.pc_citas as cita
    where cita.negocio_id = negocio
      and cita.id = cita_id
    for update;
    if not found then
      raise exception using errcode = 'P0002', message = 'La cita ya no existe o pertenece a otro negocio.';
    end if;
  end if;

  cliente_id_texto := nullif(btrim(coalesce(
    p_cita ->> 'clienteId',
    p_cita ->> 'clienteid',
    ''
  )), '');
  if cliente_id_texto is not null then
    if cliente_id_texto !~ '^\d{1,19}$' then
      raise exception using errcode = '22023', message = 'El cliente seleccionado no es válido.';
    end if;
    begin
      cliente_id := cliente_id_texto::bigint;
    exception when numeric_value_out_of_range then
      raise exception using errcode = '22003', message = 'El identificador del cliente está fuera de rango.';
    end;
    if not exists (
      select 1
      from public.pc_clientes as cliente
      where cliente.negocio_id = negocio
        and cliente.id = cliente_id
    ) then
      raise exception using errcode = '22023', message = 'El cliente seleccionado no pertenece a este negocio.';
    end if;
  end if;

  empleado_valor := left(btrim(coalesce(p_cita ->> 'empleado', '')), 180);
  if rol in ('veterinario', 'groomer') then
    select empleado.*
    into empleado_propio
    from public.pc_empleados as empleado
    where empleado.negocio_id = negocio
      and empleado.usuario_id = usuario
      and empleado.activo = true
    order by empleado.id
    limit 1;
    if not found then
      raise exception using errcode = '42501', message = 'Tu usuario no está vinculado a un empleado activo.';
    end if;
    if empleado_valor <> ''
       and lower(empleado_valor) <> lower(btrim(empleado_propio.nombre))
       and lower(empleado_valor) <> lower(split_part(btrim(empleado_propio.nombre), ' ', 1)) then
      raise exception using errcode = '42501', message = 'Solo puedes gestionar citas asignadas a tu usuario.';
    end if;
    empleado_valor := btrim(empleado_propio.nombre);
  end if;

  nombre_cliente := nullif(left(btrim(coalesce(
    p_cita ->> 'nombreCliente',
    p_cita ->> 'nombrecliente',
    ''
  )), 240), '');
  nombre_mascota := nullif(left(btrim(coalesce(
    p_cita ->> 'nombreMascota',
    p_cita ->> 'nombremascota',
    ''
  )), 180), '');
  if nombre_mascota is null then
    raise exception using errcode = '22023', message = 'El nombre de la mascota es obligatorio.';
  end if;

  telefono_valor := regexp_replace(coalesce(p_cita ->> 'telefono', ''), '[^0-9+]', '', 'g');
  if length(telefono_valor) > 24 then
    raise exception using errcode = '22023', message = 'El teléfono es demasiado largo.';
  end if;
  servicio_valor := nullif(left(btrim(coalesce(p_cita ->> 'servicio', '')), 500), '');

  if coalesce(p_cita ->> 'precio', '0') !~ '^\d{1,11}([.]\d{1,2})?$' then
    raise exception using errcode = '22023', message = 'El precio de la cita no es válido.';
  end if;
  precio_valor := (coalesce(p_cita ->> 'precio', '0'))::numeric(14,2);
  notas_valor := nullif(left(btrim(coalesce(p_cita ->> 'notas', '')), 4000), '');
  motivo_valor := nullif(left(btrim(coalesce(
    p_cita ->> 'motivoCancelacion',
    p_cita ->> 'motivocancelacion',
    ''
  )), 1000), '');

  mensajes_valor := coalesce(
    p_cita -> 'mensajesEnviados',
    p_cita -> 'mensajesenviados',
    '[]'::jsonb
  );
  if jsonb_typeof(mensajes_valor) <> 'array' then
    raise exception using errcode = '22023', message = 'El historial de mensajes no es válido.';
  end if;
  if jsonb_array_length(mensajes_valor) > 100 then
    raise exception using errcode = '22023', message = 'La cita excede el límite de 100 mensajes registrados.';
  end if;

  espera_solicitada := lower(coalesce(
    p_cita ->> 'enEspera',
    p_cita ->> 'enespera',
    'false'
  )) in ('true','1');
  inicio_nuevo := split_part(hora_texto, ':', 1)::integer * 60
    + split_part(hora_texto, ':', 2)::integer;

  if empleado_valor <> '' and estado_valor not in ('cancelada','noshow','completada') then
    select exists (
      select 1
      from public.pc_citas as otra
      where otra.negocio_id = negocio
        and otra.id <> cita_id
        and otra.fecha = fecha_texto
        and lower(btrim(coalesce(otra.empleado, ''))) = lower(empleado_valor)
        and coalesce(otra.estado, 'pendiente') not in ('cancelada','noshow','completada')
        and otra.hora ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
        and (
          split_part(otra.hora, ':', 1)::integer * 60
            + split_part(otra.hora, ':', 2)::integer
        ) < inicio_nuevo + duracion_valor
        and inicio_nuevo < (
          split_part(otra.hora, ':', 1)::integer * 60
            + split_part(otra.hora, ':', 2)::integer
            + greatest(5, least(coalesce(otra.duracion, 60), 720))
        )
    ) into conflicto;
  end if;

  if estado_valor in ('cancelada','noshow','completada') then
    espera_solicitada := false;
  else
    espera_solicitada := espera_solicitada or conflicto;
  end if;

  if cita_id_texto is null or cita_id_texto = 'nuevo' then
    insert into public.pc_citas (
      id, fecha, hora, duracion, tipo, empleado, estado, clienteid,
      nombrecliente, nombremascota, telefono, servicio, precio, notas,
      motivocancelacion, enespera, mensajesenviados, negocio_id, actualizado
    ) values (
      cita_id, fecha_texto, hora_texto, duracion_valor, tipo_valor,
      nullif(empleado_valor, ''), estado_valor, cliente_id,
      nombre_cliente, nombre_mascota, nullif(telefono_valor, ''),
      servicio_valor, precio_valor, notas_valor, motivo_valor,
      espera_solicitada, mensajes_valor::text, negocio, now()
    )
    returning * into cita_guardada;
  else
    update public.pc_citas
    set fecha = fecha_texto,
        hora = hora_texto,
        duracion = duracion_valor,
        tipo = tipo_valor,
        empleado = nullif(empleado_valor, ''),
        estado = estado_valor,
        clienteid = cliente_id,
        nombrecliente = nombre_cliente,
        nombremascota = nombre_mascota,
        telefono = nullif(telefono_valor, ''),
        servicio = servicio_valor,
        precio = precio_valor,
        notas = notas_valor,
        motivocancelacion = motivo_valor,
        enespera = espera_solicitada,
        mensajesenviados = mensajes_valor::text,
        actualizado = now()
    where negocio_id = negocio
      and id = cita_id
    returning * into cita_guardada;
  end if;

  resultado := jsonb_build_object(
    'operacionId', p_operacion_id,
    'cita', to_jsonb(cita_guardada),
    'conflicto', conflicto
  );

  insert into private.vetmake_cita_operaciones (
    negocio_id, operacion_id, usuario_id, accion, cita_id, resultado
  ) values (
    negocio, p_operacion_id, usuario, 'guardar', cita_id, resultado
  );

  return resultado;
end;
$$;

create or replace function public.guardar_cita_atomica(
  p_cita jsonb,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.guardar_cita_atomica_impl(p_cita, p_operacion_id);
$$;

create or replace function private.eliminar_cita_segura_impl(
  p_cita_id bigint,
  p_operacion_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  usuario uuid := auth.uid();
  negocio uuid;
  rol text;
  operacion_previa private.vetmake_cita_operaciones%rowtype;
  cita_previa public.pc_citas%rowtype;
  empleado_propio public.pc_empleados%rowtype;
  resultado jsonb;
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Debes iniciar sesión para eliminar citas.';
  end if;
  if p_cita_id is null or p_operacion_id is null then
    raise exception using errcode = '22023', message = 'Faltan datos para eliminar la cita.';
  end if;

  negocio := public.mi_negocio();
  rol := public.mi_rol();
  if negocio is null or rol is null
     or rol <> all (array['admin','caja','veterinario','groomer']::text[]) then
    raise exception using errcode = '42501', message = 'Tu rol no puede eliminar citas.';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(negocio::text || ':' || p_operacion_id::text, 0)
  );
  select operacion.*
  into operacion_previa
  from private.vetmake_cita_operaciones as operacion
  where operacion.negocio_id = negocio
    and operacion.operacion_id = p_operacion_id;
  if found then
    if operacion_previa.accion <> 'eliminar' then
      raise exception using errcode = '22023', message = 'El identificador de operación ya se usó para otra acción.';
    end if;
    return operacion_previa.resultado;
  end if;

  select cita.*
  into cita_previa
  from public.pc_citas as cita
  where cita.negocio_id = negocio
    and cita.id = p_cita_id
  for update;

  if not found then
    resultado := jsonb_build_object(
      'operacionId', p_operacion_id,
      'citaId', p_cita_id,
      'eliminada', false
    );
  else
    if rol in ('veterinario', 'groomer') then
      select empleado.*
      into empleado_propio
      from public.pc_empleados as empleado
      where empleado.negocio_id = negocio
        and empleado.usuario_id = usuario
        and empleado.activo = true
      order by empleado.id
      limit 1;
      if not found
         or (
           lower(btrim(coalesce(cita_previa.empleado, ''))) <> lower(btrim(empleado_propio.nombre))
           and lower(btrim(coalesce(cita_previa.empleado, ''))) <> lower(split_part(btrim(empleado_propio.nombre), ' ', 1))
         ) then
        raise exception using errcode = '42501', message = 'Solo puedes eliminar citas asignadas a tu usuario.';
      end if;
    end if;

    delete from public.pc_citas
    where negocio_id = negocio
      and id = p_cita_id;
    resultado := jsonb_build_object(
      'operacionId', p_operacion_id,
      'citaId', p_cita_id,
      'eliminada', true
    );
  end if;

  insert into private.vetmake_cita_operaciones (
    negocio_id, operacion_id, usuario_id, accion, cita_id, resultado
  ) values (
    negocio, p_operacion_id, usuario, 'eliminar', p_cita_id, resultado
  );
  return resultado;
end;
$$;

create or replace function public.eliminar_cita_segura(
  p_cita_id bigint,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.eliminar_cita_segura_impl(p_cita_id, p_operacion_id);
$$;

revoke all on function private.guardar_cita_atomica_impl(jsonb, uuid) from public, anon, authenticated;
revoke all on function private.eliminar_cita_segura_impl(bigint, uuid) from public, anon, authenticated;
revoke all on function public.guardar_cita_atomica(jsonb, uuid) from public, anon;
revoke all on function public.eliminar_cita_segura(bigint, uuid) from public, anon;
grant usage on schema private to authenticated, service_role;
grant execute on function private.guardar_cita_atomica_impl(jsonb, uuid) to authenticated, service_role;
grant execute on function private.eliminar_cita_segura_impl(bigint, uuid) to authenticated, service_role;
grant execute on function public.guardar_cita_atomica(jsonb, uuid) to authenticated;
grant execute on function public.eliminar_cita_segura(bigint, uuid) to authenticated;
