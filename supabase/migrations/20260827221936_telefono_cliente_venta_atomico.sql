-- VetMake · teléfono del cliente confirmado durante una venta
--
-- La caja podía crear un cliente con Date.now() o actualizarlo mediante un
-- upsert genérico antes de registrar la venta. Esta operación limita el cambio
-- al teléfono, asigna los IDs nuevos en PostgreSQL y permite reintentos sin
-- duplicar clientes cuando se pierde la respuesta del servidor.

alter table private.vetmake_clinica_operaciones
  drop constraint if exists vetmake_clinica_operaciones_accion_chk;

alter table private.vetmake_clinica_operaciones
  add constraint vetmake_clinica_operaciones_accion_chk
  check (accion in (
    'guardar_ficha',
    'guardar_ficha_medica',
    'guardar_telefono_venta'
  ));

create or replace function private.guardar_telefono_cliente_venta_impl(
  p_cliente_id numeric,
  p_nombre_mascota text,
  p_telefono text,
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
  zona text;
  fecha_local text;
  cliente_id numeric;
  cliente_nuevo boolean := false;
  cliente_fila public.pc_clientes%rowtype;
  resultado_previo jsonb;
  accion_previa text;
  resultado jsonb;
  mascota text;
  telefono_normalizado text;
  intento integer := 0;
begin
  usuario := auth.uid();
  negocio := public.mi_negocio();

  if usuario is null or negocio is null then
    raise exception using errcode = '42501', message = 'Sesión o clínica no válida.';
  end if;
  if not public.tiene_rol(array['admin','caja','veterinario','groomer']::text[]) then
    raise exception using errcode = '42501', message = 'Tu rol no puede registrar teléfonos durante una venta.';
  end if;
  if p_operacion_id is null then
    raise exception using errcode = '22023', message = 'La operación requiere un identificador idempotente.';
  end if;

  mascota := nullif(left(btrim(regexp_replace(
    coalesce(p_nombre_mascota, ''),
    '[<>]',
    '',
    'g'
  )), 160), '');
  telefono_normalizado := regexp_replace(coalesce(p_telefono, ''), '[^0-9]', '', 'g');

  if mascota is null then
    raise exception using errcode = '22023', message = 'El nombre del paciente es obligatorio.';
  end if;
  if char_length(telefono_normalizado) < 10 or char_length(telefono_normalizado) > 15 then
    raise exception using errcode = '22023', message = 'El teléfono debe contener entre 10 y 15 dígitos.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    negocio::text || ':guardar-telefono-venta:' || p_operacion_id::text,
    0
  ));

  select operacion.accion, operacion.resultado
    into accion_previa, resultado_previo
  from private.vetmake_clinica_operaciones as operacion
  where operacion.negocio_id = negocio
    and operacion.operacion_id = p_operacion_id;

  if found then
    if accion_previa <> 'guardar_telefono_venta' then
      raise exception using errcode = '22023', message = 'El identificador ya pertenece a otra operación.';
    end if;
    return resultado_previo;
  end if;

  if p_cliente_id is not null then
    if p_cliente_id <= 0
       or trunc(p_cliente_id) <> p_cliente_id
       or p_cliente_id > 9223372036854775807::numeric then
      raise exception using errcode = '22023', message = 'El paciente no tiene un identificador válido.';
    end if;

    select cliente.*
      into cliente_fila
    from public.pc_clientes as cliente
    where cliente.negocio_id = negocio
      and cliente.id = p_cliente_id
    for update;

    if not found then
      raise exception using errcode = 'P0002', message = 'El paciente no existe o pertenece a otra clínica.';
    end if;

    update public.pc_clientes as cliente
    set telefono = telefono_normalizado
    where cliente.negocio_id = negocio
      and cliente.id = p_cliente_id
    returning cliente.* into cliente_fila;
  else
    select coalesce(nullif(clinica.zona_horaria, ''), 'America/Santo_Domingo')
      into zona
    from public.negocios as clinica
    where clinica.id = negocio;
    fecha_local := ((statement_timestamp() at time zone coalesce(zona, 'America/Santo_Domingo'))::date)::text;

    loop
      intento := intento + 1;
      cliente_id := nextval('private.pc_clientes_admision_id_seq'::regclass);
      begin
        insert into public.pc_clientes (
          id,
          negocio_id,
          nombremascota,
          telefono,
          notas,
          fecharegistro
        )
        values (
          cliente_id,
          negocio,
          mascota,
          telefono_normalizado,
          'Registrado durante una venta',
          fecha_local
        )
        returning * into cliente_fila;
        exit;
      exception
        when unique_violation then
          if intento >= 5 then
            raise exception using errcode = '23505', message = 'No se pudo asignar un identificador único al paciente.';
          end if;
      end;
    end loop;
    cliente_nuevo := true;
  end if;

  resultado := jsonb_build_object(
    'cliente', to_jsonb(cliente_fila) - 'negocio_id',
    'clienteNuevo', cliente_nuevo,
    'operacionId', p_operacion_id
  );

  insert into private.vetmake_clinica_operaciones (
    negocio_id,
    usuario_id,
    operacion_id,
    accion,
    resultado
  )
  values (
    negocio,
    usuario,
    p_operacion_id,
    'guardar_telefono_venta',
    resultado
  );

  return resultado;
exception
  when numeric_value_out_of_range then
    raise exception using errcode = '22023', message = 'El identificador del paciente no es válido.';
end;
$$;

create or replace function public.guardar_telefono_cliente_venta(
  p_cliente_id numeric,
  p_nombre_mascota text,
  p_telefono text,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.guardar_telefono_cliente_venta_impl(
    p_cliente_id,
    p_nombre_mascota,
    p_telefono,
    p_operacion_id
  );
$$;

revoke all on function private.guardar_telefono_cliente_venta_impl(numeric, text, text, uuid)
  from public, anon;
revoke all on function public.guardar_telefono_cliente_venta(numeric, text, text, uuid)
  from public, anon;

grant usage on schema private to authenticated, service_role;
grant execute on function private.guardar_telefono_cliente_venta_impl(numeric, text, text, uuid)
  to authenticated, service_role;
grant execute on function public.guardar_telefono_cliente_venta(numeric, text, text, uuid)
  to authenticated, service_role;

comment on function public.guardar_telefono_cliente_venta(numeric, text, text, uuid) is
  'Crea el cliente mínimo o actualiza únicamente su teléfono durante una venta, con autorización e idempotencia.';

notify pgrst, 'reload schema';
