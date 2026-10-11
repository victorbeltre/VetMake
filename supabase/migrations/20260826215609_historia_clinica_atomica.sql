-- VetMake · guardado atómico de la historia clínica inicial
--
-- El portal clínico podía mostrar una ficha como guardada antes de que
-- Supabase la confirmara. Cuando el paciente todavía no existía en el CRM,
-- cliente y ficha se insertaban además en dos peticiones independientes.
-- Esta operación crea (si hace falta) el paciente y su ficha en una sola
-- transacción, con autorización clínica e idempotencia por solicitud.

create table if not exists private.vetmake_clinica_operaciones (
  negocio_id uuid not null references public.negocios(id) on delete cascade,
  usuario_id uuid not null,
  operacion_id uuid not null,
  accion text not null,
  resultado jsonb not null,
  created_at timestamptz not null default now(),
  primary key (negocio_id, operacion_id),
  constraint vetmake_clinica_operaciones_accion_chk
    check (accion in ('guardar_ficha'))
);

create index if not exists vetmake_clinica_operaciones_usuario_idx
  on private.vetmake_clinica_operaciones (usuario_id, created_at desc);

alter table private.vetmake_clinica_operaciones enable row level security;
revoke all on table private.vetmake_clinica_operaciones
  from public, anon, authenticated;

create or replace function private.guardar_ficha_clinica_atomica_impl(
  p_cliente_id numeric,
  p_cliente jsonb,
  p_ficha jsonb,
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
  cliente_id numeric;
  cliente_nuevo boolean := false;
  cliente_fila public.pc_clientes%rowtype;
  ficha_fila public.pc_fichas_clinicas%rowtype;
  resultado_previo jsonb;
  resultado jsonb;
  datos_cliente jsonb := coalesce(p_cliente, '{}'::jsonb);
  datos_ficha jsonb;
  mascota text;
  propietario text;
  telefono text;
  especie text;
  raza text;
  sexo text;
  fecha_nacimiento text;
  tipo_ficha text;
  fecha_local text;
  intento integer := 0;
begin
  usuario := auth.uid();
  negocio := public.mi_negocio();

  if usuario is null or negocio is null then
    raise exception using errcode = '42501', message = 'Sesión o clínica no válida.';
  end if;
  if not public.tiene_rol(array['admin','veterinario']::text[]) then
    raise exception using errcode = '42501', message = 'Tu rol no puede guardar historias clínicas.';
  end if;
  if p_operacion_id is null then
    raise exception using errcode = '22023', message = 'La operación requiere un identificador idempotente.';
  end if;
  if jsonb_typeof(coalesce(p_ficha, '{}'::jsonb)) <> 'object' then
    raise exception using errcode = '22023', message = 'La ficha clínica no tiene un formato válido.';
  end if;
  if octet_length(coalesce(p_ficha, '{}'::jsonb)::text) > 131072 then
    raise exception using errcode = '22023', message = 'La ficha clínica excede el tamaño permitido.';
  end if;

  select operacion.resultado
    into resultado_previo
  from private.vetmake_clinica_operaciones as operacion
  where operacion.negocio_id = negocio
    and operacion.operacion_id = p_operacion_id;

  if found then
    return resultado_previo;
  end if;

  select coalesce(nullif(clinica.zona_horaria, ''), 'America/Santo_Domingo')
    into zona
  from public.negocios as clinica
  where clinica.id = negocio;
  fecha_local := ((statement_timestamp() at time zone coalesce(zona, 'America/Santo_Domingo'))::date)::text;

  tipo_ficha := lower(btrim(coalesce(
    p_ficha ->> 'tipo',
    p_ficha -> 'datos' ->> 'tipo',
    'general'
  )));
  if tipo_ficha not in ('general', 'derma') then
    raise exception using errcode = '22023', message = 'El tipo de historia clínica no es válido.';
  end if;

  datos_ficha := coalesce(p_ficha -> 'datos', '{}'::jsonb);
  if jsonb_typeof(datos_ficha) <> 'object' then
    raise exception using errcode = '22023', message = 'Los datos de la historia clínica no son válidos.';
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
    cliente_id := cliente_fila.id;
  else
    if jsonb_typeof(datos_cliente) <> 'object' then
      raise exception using errcode = '22023', message = 'Los datos del paciente no son válidos.';
    end if;
    if octet_length(datos_cliente::text) > 32768 then
      raise exception using errcode = '22023', message = 'Los datos del paciente exceden el tamaño permitido.';
    end if;

    mascota := nullif(left(btrim(regexp_replace(coalesce(
      datos_cliente ->> 'nombreMascota',
      datos_cliente ->> 'nombremascota',
      datos_cliente ->> 'nombre',
      datos_ficha ->> 'mascota',
      ''
    ), '[<>]', '', 'g')), 160), '');
    if mascota is null then
      raise exception using errcode = '22023', message = 'El nombre del paciente es obligatorio.';
    end if;

    propietario := nullif(left(btrim(regexp_replace(coalesce(
      datos_cliente ->> 'nombrePropietario',
      datos_cliente ->> 'nombrepropietario',
      datos_cliente ->> 'dueno',
      datos_ficha ->> 'propietario',
      ''
    ), '[<>]', '', 'g')), 180), '');
    telefono := nullif(left(btrim(regexp_replace(coalesce(
      datos_cliente ->> 'telefono',
      datos_ficha ->> 'telefono',
      ''
    ), '[<>]', '', 'g')), 80), '');
    especie := nullif(left(btrim(regexp_replace(coalesce(
      datos_cliente ->> 'especie',
      datos_ficha ->> 'especie',
      ''
    ), '[<>]', '', 'g')), 80), '');
    raza := nullif(left(btrim(regexp_replace(coalesce(
      datos_cliente ->> 'raza',
      datos_ficha ->> 'raza',
      ''
    ), '[<>]', '', 'g')), 120), '');
    sexo := nullif(left(btrim(regexp_replace(coalesce(
      datos_cliente ->> 'sexo',
      datos_ficha ->> 'sexo',
      ''
    ), '[<>]', '', 'g')), 40), '');
    fecha_nacimiento := nullif(left(btrim(coalesce(
      datos_cliente ->> 'fechaNacimiento',
      datos_cliente ->> 'fechanacimiento',
      datos_ficha ->> 'fechaNacimiento',
      ''
    )), 40), '');

    if fecha_nacimiento is not null then
      if fecha_nacimiento !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        raise exception using errcode = '22007', message = 'La fecha de nacimiento no es válida.';
      end if;
      perform fecha_nacimiento::date;
    end if;

    -- Serializa altas simultáneas del mismo paciente dentro de la clínica.
    perform pg_advisory_xact_lock(hashtextextended(
      negocio::text || ':ficha-clinica:' || lower(mascota) || ':' ||
      lower(coalesce(propietario, '')) || ':' || regexp_replace(coalesce(telefono, ''), '[^0-9]', '', 'g'),
      0
    ));

    loop
      intento := intento + 1;
      cliente_id := nextval('private.pc_clientes_admision_id_seq'::regclass);
      begin
        insert into public.pc_clientes (
          id, negocio_id, nombremascota, especie, raza, sexo,
          fechanacimiento, nombrepropietario, telefono, fecharegistro
        )
        values (
          cliente_id, negocio, mascota, especie, raza, sexo,
          fecha_nacimiento, propietario, telefono, fecha_local
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

  insert into public.pc_fichas_clinicas (
    id,
    negocio_id,
    clienteid,
    tipo,
    datos,
    creadoen
  )
  values (
    gen_random_uuid()::text,
    negocio,
    cliente_id::text,
    tipo_ficha,
    datos_ficha || jsonb_build_object(
      'tipo', tipo_ficha,
      'mascota', coalesce(nullif(datos_ficha ->> 'mascota', ''), cliente_fila.nombremascota),
      'veterinario', coalesce(nullif(datos_ficha ->> 'veterinario', ''), '')
    ),
    fecha_local
  )
  returning * into ficha_fila;

  resultado := jsonb_build_object(
    'cliente', to_jsonb(cliente_fila) - 'negocio_id',
    'clienteNuevo', cliente_nuevo,
    'ficha', to_jsonb(ficha_fila) - 'negocio_id',
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
    'guardar_ficha',
    resultado
  );

  return resultado;
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception using errcode = '22023', message = 'La historia clínica contiene datos inválidos.';
end;
$$;

create or replace function public.guardar_ficha_clinica_atomica(
  p_cliente_id numeric,
  p_cliente jsonb,
  p_ficha jsonb,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.guardar_ficha_clinica_atomica_impl(
    p_cliente_id,
    p_cliente,
    p_ficha,
    p_operacion_id
  );
$$;

revoke all on function private.guardar_ficha_clinica_atomica_impl(numeric, jsonb, jsonb, uuid)
  from public, anon;
revoke all on function public.guardar_ficha_clinica_atomica(numeric, jsonb, jsonb, uuid)
  from public, anon;

grant usage on schema private to authenticated, service_role;
grant execute on function private.guardar_ficha_clinica_atomica_impl(numeric, jsonb, jsonb, uuid)
  to authenticated, service_role;
grant execute on function public.guardar_ficha_clinica_atomica(numeric, jsonb, jsonb, uuid)
  to authenticated, service_role;

comment on function public.guardar_ficha_clinica_atomica(numeric, jsonb, jsonb, uuid) is
  'Crea de forma atómica una ficha clínica y, cuando hace falta, también el paciente de la clínica autenticada.';
