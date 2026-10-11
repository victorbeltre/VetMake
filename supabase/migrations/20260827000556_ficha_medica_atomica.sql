-- VetMake · ficha médica básica atómica
--
-- La edición de la ficha actualizaba primero el estado del navegador y hacía
-- un upsert en segundo plano. Además, el frontend usaba nombres que no
-- correspondían con las columnas reales (peso/pesoKg, dueño/propietario y
-- medicación/medicamentos). Esta RPC valida, autoriza y confirma el paciente
-- completo desde PostgreSQL sin sobrescribir vacunas, estudios ni fotos.

alter table public.pc_clientes
  add column if not exists telefono2 text,
  add column if not exists pesokg numeric,
  add column if not exists edad text,
  add column if not exists microchip text,
  add column if not exists vacunas jsonb not null default '[]'::jsonb,
  add column if not exists estudios jsonb not null default '[]'::jsonb,
  add column if not exists fotosmascota jsonb not null default '[]'::jsonb,
  add column if not exists banos2025 integer not null default 0;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'pc_clientes_pesokg_rango_chk'
      and conrelid = 'public.pc_clientes'::regclass
  ) then
    alter table public.pc_clientes
      add constraint pc_clientes_pesokg_rango_chk
      check (pesokg is null or (pesokg > 0 and pesokg <= 500))
      not valid;
  end if;
end
$$;

alter table private.vetmake_clinica_operaciones
  drop constraint if exists vetmake_clinica_operaciones_accion_chk;

alter table private.vetmake_clinica_operaciones
  add constraint vetmake_clinica_operaciones_accion_chk
  check (accion in ('guardar_ficha', 'guardar_ficha_medica'));

create or replace function private.guardar_ficha_medica_atomica_impl(
  p_cliente_id numeric,
  p_cliente jsonb,
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
  datos jsonb := coalesce(p_cliente, '{}'::jsonb);
  resultado_previo jsonb;
  accion_previa text;
  resultado jsonb;
  mascota text;
  especie_paciente text;
  raza_paciente text;
  color_pelaje text;
  sexo_paciente text;
  edad_paciente text;
  microchip_paciente text;
  propietario text;
  telefono_principal text;
  telefono_secundario text;
  alergias_paciente text;
  condiciones_paciente text;
  medicamentos_paciente text;
  notas_paciente text;
  esterilizado_paciente boolean;
  esterilizado_texto text;
  peso_presente boolean;
  peso_texto text;
  peso_paciente numeric;
  intento integer := 0;
begin
  usuario := auth.uid();
  negocio := public.mi_negocio();

  if usuario is null or negocio is null then
    raise exception using errcode = '42501', message = 'Sesión o clínica no válida.';
  end if;
  if not public.tiene_rol(array['admin','veterinario']::text[]) then
    raise exception using errcode = '42501', message = 'Tu rol no puede modificar fichas médicas.';
  end if;
  if p_operacion_id is null then
    raise exception using errcode = '22023', message = 'La operación requiere un identificador idempotente.';
  end if;
  if jsonb_typeof(datos) <> 'object' then
    raise exception using errcode = '22023', message = 'Los datos de la ficha médica no tienen un formato válido.';
  end if;
  if octet_length(datos::text) > 65536 then
    raise exception using errcode = '22023', message = 'La ficha médica excede el tamaño permitido.';
  end if;

  -- Un mismo UUID nunca puede ejecutar dos veces la operación, incluso si
  -- llegan dos solicitudes simultáneas por un reintento de red.
  perform pg_advisory_xact_lock(hashtextextended(
    negocio::text || ':guardar-ficha-medica:' || p_operacion_id::text,
    0
  ));

  select operacion.accion, operacion.resultado
    into accion_previa, resultado_previo
  from private.vetmake_clinica_operaciones as operacion
  where operacion.negocio_id = negocio
    and operacion.operacion_id = p_operacion_id;

  if found then
    if accion_previa <> 'guardar_ficha_medica' then
      raise exception using errcode = '22023', message = 'El identificador ya pertenece a otra operación.';
    end if;
    return resultado_previo;
  end if;

  mascota := nullif(left(btrim(regexp_replace(coalesce(
    datos ->> 'nombreMascota',
    datos ->> 'nombremascota',
    datos ->> 'nombre',
    ''
  ), '[<>]', '', 'g')), 160), '');
  especie_paciente := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'especie', ''), '[<>]', '', 'g')), 80), '');
  raza_paciente := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'raza', ''), '[<>]', '', 'g')), 120), '');
  color_pelaje := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'color', ''), '[<>]', '', 'g')), 120), '');
  sexo_paciente := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'sexo', ''), '[<>]', '', 'g')), 40), '');
  edad_paciente := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'edad', ''), '[<>]', '', 'g')), 80), '');
  microchip_paciente := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'microchip', ''), '[<>]', '', 'g')), 120), '');
  propietario := nullif(left(btrim(regexp_replace(coalesce(
    datos ->> 'nombrePropietario',
    datos ->> 'nombrepropietario',
    datos ->> 'dueno',
    ''
  ), '[<>]', '', 'g')), 180), '');
  telefono_principal := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'telefono', ''), '[<>]', '', 'g')), 80), '');
  telefono_secundario := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'telefono2', ''), '[<>]', '', 'g')), 80), '');
  alergias_paciente := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'alergias', ''), '[<>]', '', 'g')), 4000), '');
  condiciones_paciente := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'condiciones', ''), '[<>]', '', 'g')), 4000), '');
  medicamentos_paciente := nullif(left(btrim(regexp_replace(coalesce(
    datos ->> 'medicamentos',
    datos ->> 'medicacion',
    ''
  ), '[<>]', '', 'g')), 4000), '');
  notas_paciente := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'notas', ''), '[<>]', '', 'g')), 8000), '');

  if datos ? 'esterilizado' then
    esterilizado_texto := lower(btrim(coalesce(datos ->> 'esterilizado', '')));
    if esterilizado_texto = '' then
      esterilizado_paciente := null;
    elsif esterilizado_texto in ('true', '1', 'si', 'sí', 'yes') then
      esterilizado_paciente := true;
    elsif esterilizado_texto in ('false', '0', 'no') then
      esterilizado_paciente := false;
    else
      raise exception using errcode = '22023', message = 'El estado de esterilización no es válido.';
    end if;
  end if;

  peso_presente := datos ? 'pesoKg' or datos ? 'pesokg' or datos ? 'peso';
  if peso_presente then
    peso_texto := replace(btrim(coalesce(
      datos ->> 'pesoKg',
      datos ->> 'pesokg',
      datos ->> 'peso',
      ''
    )), ',', '.');
    if peso_texto = '' then
      peso_paciente := null;
    else
      if char_length(peso_texto) > 32
         or peso_texto !~ '^[0-9]+([.][0-9]{1,3})?$' then
        raise exception using errcode = '22023', message = 'El peso debe ser un número válido en kilogramos.';
      end if;
      peso_paciente := peso_texto::numeric;
      if peso_paciente <= 0 or peso_paciente > 500 then
        raise exception using errcode = '22023', message = 'El peso debe ser mayor que 0 y no superar 500 kg.';
      end if;
    end if;
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

    update public.pc_clientes as cliente
    set especie = case when datos ? 'especie' then especie_paciente else cliente.especie end,
        raza = case when datos ? 'raza' then raza_paciente else cliente.raza end,
        color = case when datos ? 'color' then color_pelaje else cliente.color end,
        sexo = case when datos ? 'sexo' then sexo_paciente else cliente.sexo end,
        edad = case when datos ? 'edad' then edad_paciente else cliente.edad end,
        pesokg = case when peso_presente then peso_paciente else cliente.pesokg end,
        microchip = case when datos ? 'microchip' then microchip_paciente else cliente.microchip end,
        esterilizado = case when datos ? 'esterilizado' then esterilizado_paciente else cliente.esterilizado end,
        nombrepropietario = case
          when datos ? 'nombrePropietario' or datos ? 'nombrepropietario' or datos ? 'dueno'
            then propietario
          else cliente.nombrepropietario
        end,
        telefono = case when datos ? 'telefono' then telefono_principal else cliente.telefono end,
        telefono2 = case when datos ? 'telefono2' then telefono_secundario else cliente.telefono2 end,
        alergias = case when datos ? 'alergias' then alergias_paciente else cliente.alergias end,
        condiciones = case when datos ? 'condiciones' then condiciones_paciente else cliente.condiciones end,
        medicamentos = case
          when datos ? 'medicamentos' or datos ? 'medicacion' then medicamentos_paciente
          else cliente.medicamentos
        end,
        notas = case when datos ? 'notas' then notas_paciente else cliente.notas end
    where cliente.negocio_id = negocio
      and cliente.id = cliente_id
    returning cliente.* into cliente_fila;
  else
    if mascota is null then
      raise exception using errcode = '22023', message = 'El nombre del paciente es obligatorio.';
    end if;

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
          especie,
          raza,
          color,
          sexo,
          edad,
          pesokg,
          microchip,
          esterilizado,
          nombrepropietario,
          telefono,
          telefono2,
          alergias,
          condiciones,
          medicamentos,
          notas,
          fecharegistro
        )
        values (
          cliente_id,
          negocio,
          mascota,
          especie_paciente,
          raza_paciente,
          color_pelaje,
          sexo_paciente,
          edad_paciente,
          peso_paciente,
          microchip_paciente,
          esterilizado_paciente,
          propietario,
          telefono_principal,
          telefono_secundario,
          alergias_paciente,
          condiciones_paciente,
          medicamentos_paciente,
          notas_paciente,
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
    'guardar_ficha_medica',
    resultado
  );

  return resultado;
exception
  when numeric_value_out_of_range then
    raise exception using errcode = '22023', message = 'La ficha médica contiene un valor numérico inválido.';
end;
$$;

create or replace function public.guardar_ficha_medica_atomica(
  p_cliente_id numeric,
  p_cliente jsonb,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.guardar_ficha_medica_atomica_impl(
    p_cliente_id,
    p_cliente,
    p_operacion_id
  );
$$;

revoke all on function private.guardar_ficha_medica_atomica_impl(numeric, jsonb, uuid)
  from public, anon;
revoke all on function public.guardar_ficha_medica_atomica(numeric, jsonb, uuid)
  from public, anon;

grant usage on schema private to authenticated, service_role;
grant execute on function private.guardar_ficha_medica_atomica_impl(numeric, jsonb, uuid)
  to authenticated, service_role;
grant execute on function public.guardar_ficha_medica_atomica(numeric, jsonb, uuid)
  to authenticated, service_role;

comment on function public.guardar_ficha_medica_atomica(numeric, jsonb, uuid) is
  'Crea o actualiza la ficha médica básica del paciente en una transacción autorizada e idempotente.';

notify pgrst, 'reload schema';
