-- VetMake · alta y edición atómica de clientes desde el CRM
--
-- El CRM heredado asignaba Date.now() como identificador y reflejaba el cambio
-- antes de que Supabase confirmara el upsert. Esta RPC asigna los IDs en
-- PostgreSQL, valida el expediente completo, respeta el negocio autenticado y
-- permite reintentar una respuesta perdida sin crear dos clientes.

alter table private.vetmake_clinica_operaciones
  drop constraint if exists vetmake_clinica_operaciones_accion_chk;

alter table private.vetmake_clinica_operaciones
  add constraint vetmake_clinica_operaciones_accion_chk
  check (accion in (
    'guardar_ficha',
    'guardar_ficha_medica',
    'guardar_telefono_venta',
    'guardar_cliente_crm'
  ));

create or replace function private.guardar_cliente_crm_atomico_impl(
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
  datos jsonb := coalesce(p_cliente, '{}'::jsonb);
  cliente_id numeric;
  cliente_nuevo boolean := false;
  cliente_fila public.pc_clientes%rowtype;
  resultado_previo jsonb;
  accion_previa text;
  resultado jsonb;
  intento integer := 0;

  mascota text;
  especie_paciente text;
  raza_paciente text;
  sexo_paciente text;
  fecha_nacimiento text;
  color_pelaje text;
  tamano_paciente text;
  propietario text;
  telefono_principal text;
  telefono_secundario text;
  email_propietario text;
  direccion_propietario text;
  instagram_propietario text;
  cedula_propietario text;
  alergias_paciente text;
  medicamentos_paciente text;
  condiciones_paciente text;
  alerta_medica text;
  veterinario_externo text;
  edad_paciente text;
  microchip_paciente text;
  notas_paciente text;
  fecha_registro text;
  ultima_visita text;
  esterilizado_paciente boolean;
  peso_paciente numeric;
  peso_texto text;
  banos_2025 integer;
  banos_texto text;
  vacunas_paciente jsonb;
  estudios_paciente jsonb;
  fotos_paciente jsonb;
begin
  usuario := auth.uid();
  negocio := public.mi_negocio();

  if usuario is null or negocio is null then
    raise exception using errcode = '42501', message = 'Sesión o clínica no válida.';
  end if;
  if not public.tiene_rol(array['admin','caja']::text[]) then
    raise exception using errcode = '42501', message = 'Tu rol no puede crear ni editar clientes del CRM.';
  end if;
  if p_operacion_id is null then
    raise exception using errcode = '22023', message = 'La operación requiere un identificador idempotente.';
  end if;
  if jsonb_typeof(datos) <> 'object' then
    raise exception using errcode = '22023', message = 'Los datos del cliente no tienen un formato válido.';
  end if;
  if octet_length(datos::text) > 8388608 then
    raise exception using errcode = '22023', message = 'El expediente del cliente excede el tamaño permitido.';
  end if;

  select coalesce(nullif(clinica.zona_horaria, ''), 'America/Santo_Domingo')
    into zona
  from public.negocios as clinica
  where clinica.id = negocio;
  fecha_local := ((statement_timestamp() at time zone coalesce(zona, 'America/Santo_Domingo'))::date)::text;

  -- El bloqueo dura solo esta transacción y serializa clics dobles o reintentos
  -- que compartan el mismo UUID.
  perform pg_advisory_xact_lock(hashtextextended(
    negocio::text || ':guardar-cliente-crm:' || p_operacion_id::text,
    0
  ));

  select operacion.accion, operacion.resultado
    into accion_previa, resultado_previo
  from private.vetmake_clinica_operaciones as operacion
  where operacion.negocio_id = negocio
    and operacion.operacion_id = p_operacion_id;

  if found then
    if accion_previa <> 'guardar_cliente_crm' then
      raise exception using errcode = '22023', message = 'El identificador ya pertenece a otra operación.';
    end if;
    return resultado_previo;
  end if;

  mascota := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'nombreMascota', ''), '[<>]', '', 'g')), 160), '');
  especie_paciente := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'especie', ''), '[<>]', '', 'g')), 80), '');
  raza_paciente := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'raza', ''), '[<>]', '', 'g')), 120), '');
  sexo_paciente := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'sexo', ''), '[<>]', '', 'g')), 40), '');
  fecha_nacimiento := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'fechaNacimiento', ''), '[<>]', '', 'g')), 10), '');
  color_pelaje := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'color', ''), '[<>]', '', 'g')), 120), '');
  tamano_paciente := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'tamano', ''), '[<>]', '', 'g')), 80), '');
  propietario := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'nombrePropietario', ''), '[<>]', '', 'g')), 180), '');
  telefono_principal := nullif(regexp_replace(coalesce(datos ->> 'telefono', ''), '[^0-9]', '', 'g'), '');
  telefono_secundario := nullif(regexp_replace(coalesce(datos ->> 'telefono2', ''), '[^0-9]', '', 'g'), '');
  email_propietario := nullif(left(lower(btrim(regexp_replace(coalesce(datos ->> 'email', ''), '[<>]', '', 'g'))), 254), '');
  direccion_propietario := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'direccion', ''), '[<>]', '', 'g')), 500), '');
  instagram_propietario := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'instagram', ''), '[<>]', '', 'g')), 120), '');
  cedula_propietario := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'cedula', ''), '[<>]', '', 'g')), 80), '');
  alergias_paciente := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'alergias', ''), '[<>]', '', 'g')), 4000), '');
  medicamentos_paciente := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'medicamentos', ''), '[<>]', '', 'g')), 4000), '');
  condiciones_paciente := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'condiciones', ''), '[<>]', '', 'g')), 4000), '');
  alerta_medica := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'alertaMedica', ''), '[<>]', '', 'g')), 1000), '');
  veterinario_externo := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'veterinarioExterno', ''), '[<>]', '', 'g')), 240), '');
  edad_paciente := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'edad', ''), '[<>]', '', 'g')), 80), '');
  microchip_paciente := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'microchip', ''), '[<>]', '', 'g')), 120), '');
  notas_paciente := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'notas', ''), '[<>]', '', 'g')), 8000), '');
  fecha_registro := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'fechaRegistro', ''), '[<>]', '', 'g')), 10), '');
  ultima_visita := nullif(left(btrim(regexp_replace(coalesce(datos ->> 'ultimaVisita2025', ''), '[<>]', '', 'g')), 10), '');

  if (datos ? 'nombreMascota') and mascota is null then
    raise exception using errcode = '22023', message = 'El nombre de la mascota es obligatorio.';
  end if;
  if (datos ? 'nombrePropietario') and propietario is null then
    raise exception using errcode = '22023', message = 'El nombre del propietario es obligatorio.';
  end if;
  if datos ? 'telefono' then
    if telefono_principal is null
       or char_length(telefono_principal) < 10
       or char_length(telefono_principal) > 15 then
      raise exception using errcode = '22023', message = 'El teléfono principal debe contener entre 10 y 15 dígitos.';
    end if;
  end if;
  if telefono_secundario is not null
     and (char_length(telefono_secundario) < 10 or char_length(telefono_secundario) > 15) then
    raise exception using errcode = '22023', message = 'El teléfono alternativo debe contener entre 10 y 15 dígitos.';
  end if;
  if email_propietario is not null
     and email_propietario !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
    raise exception using errcode = '22023', message = 'El correo electrónico no tiene un formato válido.';
  end if;

  if fecha_nacimiento is not null then
    if fecha_nacimiento !~ '^\d{4}-\d{2}-\d{2}$'
       or to_char(to_date(fecha_nacimiento, 'YYYY-MM-DD'), 'YYYY-MM-DD') <> fecha_nacimiento
       or fecha_nacimiento > fecha_local then
      raise exception using errcode = '22023', message = 'La fecha de nacimiento no es válida.';
    end if;
  end if;
  if fecha_registro is not null
     and (
       fecha_registro !~ '^\d{4}-\d{2}-\d{2}$'
       or to_char(to_date(fecha_registro, 'YYYY-MM-DD'), 'YYYY-MM-DD') <> fecha_registro
     ) then
    raise exception using errcode = '22023', message = 'La fecha de registro no es válida.';
  end if;
  if ultima_visita is not null
     and (
       ultima_visita !~ '^\d{4}-\d{2}-\d{2}$'
       or to_char(to_date(ultima_visita, 'YYYY-MM-DD'), 'YYYY-MM-DD') <> ultima_visita
     ) then
    raise exception using errcode = '22023', message = 'La fecha de última visita no es válida.';
  end if;

  if datos ? 'esterilizado' then
    if jsonb_typeof(datos -> 'esterilizado') <> 'boolean' then
      raise exception using errcode = '22023', message = 'El estado de esterilización no es válido.';
    end if;
    esterilizado_paciente := (datos ->> 'esterilizado')::boolean;
  end if;

  if datos ? 'pesoKg' then
    peso_texto := replace(btrim(coalesce(datos ->> 'pesoKg', '')), ',', '.');
    if peso_texto = '' then
      peso_paciente := null;
    elsif char_length(peso_texto) > 32 or peso_texto !~ '^[0-9]+([.][0-9]{1,3})?$' then
      raise exception using errcode = '22023', message = 'El peso debe ser un número válido en kilogramos.';
    else
      peso_paciente := peso_texto::numeric;
      if peso_paciente <= 0 or peso_paciente > 500 then
        raise exception using errcode = '22023', message = 'El peso debe ser mayor que 0 y no superar 500 kg.';
      end if;
    end if;
  end if;

  if datos ? 'banos2025' then
    banos_texto := btrim(coalesce(datos ->> 'banos2025', ''));
    if banos_texto = '' then
      banos_2025 := 0;
    elsif banos_texto !~ '^\d{1,6}$' then
      raise exception using errcode = '22023', message = 'La cantidad histórica de baños no es válida.';
    else
      banos_2025 := banos_texto::integer;
      if banos_2025 > 100000 then
        raise exception using errcode = '22023', message = 'La cantidad histórica de baños excede el máximo permitido.';
      end if;
    end if;
  end if;

  if datos ? 'vacunas' then
    if jsonb_typeof(datos -> 'vacunas') <> 'array' or jsonb_array_length(datos -> 'vacunas') > 200 then
      raise exception using errcode = '22023', message = 'El registro de vacunas no tiene un formato válido.';
    end if;
    vacunas_paciente := datos -> 'vacunas';
  end if;
  if datos ? 'estudios' then
    if jsonb_typeof(datos -> 'estudios') <> 'array' or jsonb_array_length(datos -> 'estudios') > 200 then
      raise exception using errcode = '22023', message = 'El registro de estudios no tiene un formato válido.';
    end if;
    estudios_paciente := datos -> 'estudios';
  end if;
  if datos ? 'fotosMascota' then
    if jsonb_typeof(datos -> 'fotosMascota') <> 'array' or jsonb_array_length(datos -> 'fotosMascota') > 100 then
      raise exception using errcode = '22023', message = 'El registro de fotos no tiene un formato válido.';
    end if;
    fotos_paciente := datos -> 'fotosMascota';
  end if;

  if p_cliente_id is not null then
    if p_cliente_id <= 0
       or trunc(p_cliente_id) <> p_cliente_id
       or p_cliente_id > 9223372036854775807::numeric then
      raise exception using errcode = '22023', message = 'El cliente no tiene un identificador válido.';
    end if;

    select cliente.*
      into cliente_fila
    from public.pc_clientes as cliente
    where cliente.negocio_id = negocio
      and cliente.id = p_cliente_id
    for update;

    if not found then
      raise exception using errcode = 'P0002', message = 'El cliente no existe o pertenece a otra clínica.';
    end if;
    cliente_id := cliente_fila.id;

    update public.pc_clientes as cliente
    set nombremascota = case when datos ? 'nombreMascota' then mascota else cliente.nombremascota end,
        especie = case when datos ? 'especie' then especie_paciente else cliente.especie end,
        raza = case when datos ? 'raza' then raza_paciente else cliente.raza end,
        sexo = case when datos ? 'sexo' then sexo_paciente else cliente.sexo end,
        fechanacimiento = case when datos ? 'fechaNacimiento' then fecha_nacimiento else cliente.fechanacimiento end,
        color = case when datos ? 'color' then color_pelaje else cliente.color end,
        tamano = case when datos ? 'tamano' then tamano_paciente else cliente.tamano end,
        esterilizado = case when datos ? 'esterilizado' then esterilizado_paciente else cliente.esterilizado end,
        nombrepropietario = case when datos ? 'nombrePropietario' then propietario else cliente.nombrepropietario end,
        telefono = case when datos ? 'telefono' then telefono_principal else cliente.telefono end,
        telefono2 = case when datos ? 'telefono2' then telefono_secundario else cliente.telefono2 end,
        email = case when datos ? 'email' then email_propietario else cliente.email end,
        direccion = case when datos ? 'direccion' then direccion_propietario else cliente.direccion end,
        instagram = case when datos ? 'instagram' then instagram_propietario else cliente.instagram end,
        cedula = case when datos ? 'cedula' then cedula_propietario else cliente.cedula end,
        alergias = case when datos ? 'alergias' then alergias_paciente else cliente.alergias end,
        medicamentos = case when datos ? 'medicamentos' then medicamentos_paciente else cliente.medicamentos end,
        condiciones = case when datos ? 'condiciones' then condiciones_paciente else cliente.condiciones end,
        alertamedica = case when datos ? 'alertaMedica' then alerta_medica else cliente.alertamedica end,
        veterinarioexterno = case when datos ? 'veterinarioExterno' then veterinario_externo else cliente.veterinarioexterno end,
        pesokg = case when datos ? 'pesoKg' then peso_paciente else cliente.pesokg end,
        edad = case when datos ? 'edad' then edad_paciente else cliente.edad end,
        microchip = case when datos ? 'microchip' then microchip_paciente else cliente.microchip end,
        vacunas = case when datos ? 'vacunas' then vacunas_paciente else cliente.vacunas end,
        estudios = case when datos ? 'estudios' then estudios_paciente else cliente.estudios end,
        fotosmascota = case when datos ? 'fotosMascota' then fotos_paciente else cliente.fotosmascota end,
        banos2025 = case when datos ? 'banos2025' then banos_2025 else cliente.banos2025 end,
        notas = case when datos ? 'notas' then notas_paciente else cliente.notas end,
        fecharegistro = case when datos ? 'fechaRegistro' then fecha_registro else cliente.fecharegistro end,
        ultimavisita2025 = case when datos ? 'ultimaVisita2025' then ultima_visita else cliente.ultimavisita2025 end
    where cliente.negocio_id = negocio
      and cliente.id = cliente_id
    returning cliente.* into cliente_fila;
  else
    if mascota is null or propietario is null or telefono_principal is null then
      raise exception using errcode = '22023', message = 'Mascota, propietario y teléfono son obligatorios para crear el cliente.';
    end if;

    loop
      intento := intento + 1;
      cliente_id := nextval('private.pc_clientes_admision_id_seq'::regclass);
      begin
        insert into public.pc_clientes (
          id, negocio_id, nombremascota, especie, raza, sexo,
          fechanacimiento, color, tamano, esterilizado,
          nombrepropietario, telefono, telefono2, email, direccion, instagram,
          cedula, alergias, medicamentos, condiciones, alertamedica,
          veterinarioexterno, pesokg, edad, microchip, vacunas, estudios,
          fotosmascota, banos2025, notas, fecharegistro, ultimavisita2025
        )
        values (
          cliente_id, negocio, mascota, especie_paciente, raza_paciente, sexo_paciente,
          fecha_nacimiento, color_pelaje, tamano_paciente, coalesce(esterilizado_paciente, false),
          propietario, telefono_principal, telefono_secundario, email_propietario,
          direccion_propietario, instagram_propietario, cedula_propietario,
          alergias_paciente, medicamentos_paciente, condiciones_paciente,
          alerta_medica, veterinario_externo, peso_paciente, edad_paciente,
          microchip_paciente, coalesce(vacunas_paciente, '[]'::jsonb),
          coalesce(estudios_paciente, '[]'::jsonb), coalesce(fotos_paciente, '[]'::jsonb),
          coalesce(banos_2025, 0), notas_paciente, coalesce(fecha_registro, fecha_local),
          ultima_visita
        )
        returning * into cliente_fila;
        exit;
      exception
        when unique_violation then
          if intento >= 5 then
            raise exception using errcode = '23505', message = 'No se pudo asignar un identificador único al cliente.';
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
    'guardar_cliente_crm',
    resultado
  );

  return resultado;
exception
  when numeric_value_out_of_range then
    raise exception using errcode = '22023', message = 'Un valor numérico del cliente no es válido.';
end;
$$;

create or replace function public.guardar_cliente_crm_atomico(
  p_cliente_id numeric,
  p_cliente jsonb,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.guardar_cliente_crm_atomico_impl(
    p_cliente_id,
    p_cliente,
    p_operacion_id
  );
$$;

revoke all on function private.guardar_cliente_crm_atomico_impl(numeric, jsonb, uuid)
  from public, anon;
revoke all on function public.guardar_cliente_crm_atomico(numeric, jsonb, uuid)
  from public, anon;

grant usage on schema private to authenticated, service_role;
grant execute on function private.guardar_cliente_crm_atomico_impl(numeric, jsonb, uuid)
  to authenticated, service_role;
grant execute on function public.guardar_cliente_crm_atomico(numeric, jsonb, uuid)
  to authenticated, service_role;

comment on function public.guardar_cliente_crm_atomico(numeric, jsonb, uuid) is
  'Crea o edita un cliente de la clínica autenticada con ID de servidor, validación e idempotencia.';

notify pgrst, 'reload schema';
