-- VetMake · Admisión pública segura
--
-- La función pública de formulario usa service_role, pero la validación,
-- deduplicación, rate limit e inserción deben ocurrir juntas en PostgreSQL.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create sequence if not exists private.pc_clientes_admision_id_seq as bigint;

select setval(
  'private.pc_clientes_admision_id_seq',
  greatest(
    coalesce((select max(id)::bigint from public.pc_clientes), 0),
    (select last_value from private.pc_clientes_admision_id_seq),
    1
  ),
  true
);

create table if not exists private.vetmake_admision_limites (
  alcance text not null,
  clave text not null,
  ventana timestamptz not null,
  solicitudes integer not null default 0 check (solicitudes > 0),
  actualizado_en timestamptz not null default now(),
  primary key (alcance, clave, ventana)
);

alter table private.vetmake_admision_limites enable row level security;
revoke all on table private.vetmake_admision_limites from public, anon, authenticated;
revoke all on sequence private.pc_clientes_admision_id_seq from public, anon, authenticated;

create or replace function public.vetmake_enviar_admision(
  p_token uuid,
  p_datos jsonb,
  p_fingerprint text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  negocio uuid;
  zona text;
  limite_global integer;
  limite_fuente integer;
  ventana_minuto timestamptz := date_trunc('minute', statement_timestamp());
  ventana_diez_minutos timestamptz := to_timestamp(
    floor(extract(epoch from statement_timestamp()) / 600) * 600
  );
  fingerprint text := left(coalesce(nullif(btrim(p_fingerprint), ''), 'desconocido'), 128);
  propietario text;
  telefono text;
  telefono_digitos text;
  mascota text;
  especie text;
  email text;
  fecha_nacimiento text;
  cliente_existente numeric;
  cliente_id numeric;
begin
  if p_token is null or p_datos is null or jsonb_typeof(p_datos) <> 'object'
     or pg_column_size(p_datos) > 65536 then
    raise exception using errcode = '22023', message = 'La inscripción no es válida o excede el tamaño permitido.';
  end if;

  select clinica.id, coalesce(clinica.zona_horaria, 'America/Santo_Domingo')
  into negocio, zona
  from public.negocios as clinica
  where clinica.formulario_token = p_token
    and clinica.formulario_activo = true
    and clinica.activo = true;

  if negocio is null then
    raise exception using errcode = 'P0002', message = 'Este formulario no está disponible.';
  end if;

  -- Mantiene la tabla pequeña sin depender de un cron externo.
  delete from private.vetmake_admision_limites
  where ventana < statement_timestamp() - interval '1 day';

  insert into private.vetmake_admision_limites (alcance, clave, ventana, solicitudes)
  values ('negocio_minuto', negocio::text, ventana_minuto, 1)
  on conflict (alcance, clave, ventana) do update
  set solicitudes = private.vetmake_admision_limites.solicitudes + 1,
      actualizado_en = statement_timestamp()
  returning solicitudes into limite_global;

  if limite_global > 30 then
    raise exception using errcode = 'P0001', message = 'Hay demasiadas inscripciones. Inténtalo dentro de unos minutos.';
  end if;

  insert into private.vetmake_admision_limites (alcance, clave, ventana, solicitudes)
  values ('fuente_diez_minutos', negocio::text || ':' || fingerprint, ventana_diez_minutos, 1)
  on conflict (alcance, clave, ventana) do update
  set solicitudes = private.vetmake_admision_limites.solicitudes + 1,
      actualizado_en = statement_timestamp()
  returning solicitudes into limite_fuente;

  if limite_fuente > 5 then
    raise exception using errcode = 'P0001', message = 'Espera unos minutos antes de volver a enviar el formulario.';
  end if;

  propietario := left(btrim(regexp_replace(coalesce(p_datos ->> 'propietario', ''), '[<>]', '', 'g')), 120);
  telefono := left(btrim(regexp_replace(coalesce(p_datos ->> 'telefono', ''), '[<>]', '', 'g')), 35);
  telefono_digitos := regexp_replace(telefono, '[^0-9]', '', 'g');
  mascota := left(btrim(regexp_replace(coalesce(p_datos ->> 'mascota', ''), '[<>]', '', 'g')), 100);
  especie := left(btrim(regexp_replace(coalesce(p_datos ->> 'especie', ''), '[<>]', '', 'g')), 30);
  email := lower(left(btrim(regexp_replace(coalesce(p_datos ->> 'email', ''), '[<>]', '', 'g')), 160));
  fecha_nacimiento := nullif(left(btrim(coalesce(p_datos ->> 'fechaNacimiento', '')), 10), '');

  if propietario = '' or mascota = '' or especie = ''
     or length(telefono_digitos) not between 7 and 15 then
    raise exception using errcode = '22023', message = 'Completa nombre, teléfono, mascota y especie con datos válidos.';
  end if;

  if email <> '' and email !~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
    raise exception using errcode = '22023', message = 'El correo no es válido.';
  end if;

  if fecha_nacimiento is not null then
    if fecha_nacimiento !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
      raise exception using errcode = '22007', message = 'La fecha de nacimiento no es válida.';
    end if;
    perform fecha_nacimiento::date;
  end if;

  -- Serializa solamente el mismo teléfono+mascota; otras admisiones continúan
  -- en paralelo, pero dos envíos simultáneos no crean duplicados.
  perform pg_advisory_xact_lock(hashtextextended(
    negocio::text || ':' || telefono_digitos || ':' || lower(mascota),
    0
  ));

  select cliente.id
  into cliente_existente
  from public.pc_clientes as cliente
  where cliente.negocio_id = negocio
    and regexp_replace(coalesce(cliente.telefono, ''), '[^0-9]', '', 'g') = telefono_digitos
    and lower(btrim(coalesce(cliente.nombremascota, ''))) = lower(mascota)
    and cliente.created_at >= statement_timestamp() - interval '5 minutes'
  order by cliente.created_at desc
  limit 1;

  if cliente_existente is not null then
    return jsonb_build_object('ok', true, 'duplicate', true, 'id', cliente_existente);
  end if;

  cliente_id := nextval('private.pc_clientes_admision_id_seq'::regclass);

  insert into public.pc_clientes (
    id, negocio_id, nombremascota, especie, raza, sexo, fechanacimiento,
    color, tamano, esterilizado, nombrepropietario, telefono, email,
    direccion, alergias, medicamentos, condiciones, alertamedica, notas,
    fecharegistro
  ) values (
    cliente_id,
    negocio,
    mascota,
    especie,
    left(btrim(regexp_replace(coalesce(p_datos ->> 'raza', ''), '[<>]', '', 'g')), 80),
    left(btrim(regexp_replace(coalesce(p_datos ->> 'sexo', ''), '[<>]', '', 'g')), 20),
    fecha_nacimiento,
    left(btrim(regexp_replace(coalesce(p_datos ->> 'color', ''), '[<>]', '', 'g')), 60),
    left(btrim(regexp_replace(coalesce(p_datos ->> 'tamano', ''), '[<>]', '', 'g')), 50),
    coalesce((p_datos ->> 'esterilizado')::boolean, false),
    propietario,
    telefono,
    nullif(email, ''),
    left(btrim(regexp_replace(coalesce(p_datos ->> 'direccion', ''), '[<>]', '', 'g')), 250),
    left(btrim(regexp_replace(coalesce(p_datos ->> 'alergias', ''), '[<>]', '', 'g')), 350),
    left(btrim(regexp_replace(coalesce(p_datos ->> 'medicamentos', ''), '[<>]', '', 'g')), 350),
    left(btrim(regexp_replace(coalesce(p_datos ->> 'condiciones', ''), '[<>]', '', 'g')), 500),
    left(btrim(regexp_replace(coalesce(p_datos ->> 'alertaMedica', ''), '[<>]', '', 'g')), 350),
    left(
      'Nos conoció por: ' || coalesce(nullif(btrim(regexp_replace(coalesce(p_datos ->> 'canal', ''), '[<>]', '', 'g')), ''), 'Formulario web') ||
      ' | Servicio: ' || coalesce(nullif(btrim(regexp_replace(coalesce(p_datos ->> 'servicio', ''), '[<>]', '', 'g')), ''), 'Por definir') ||
      ' | Formulario web VetMake' ||
      case when nullif(btrim(coalesce(p_datos ->> 'notas', '')), '') is not null
        then ' | ' || btrim(regexp_replace(p_datos ->> 'notas', '[<>]', '', 'g'))
        else '' end,
      1200
    ),
    ((statement_timestamp() at time zone zona)::date)::text
  );

  return jsonb_build_object('ok', true, 'id', cliente_id);
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception using errcode = '22023', message = 'La inscripción contiene datos inválidos.';
end;
$$;

revoke all on function public.vetmake_enviar_admision(uuid, jsonb, text)
  from public, anon, authenticated;
grant execute on function public.vetmake_enviar_admision(uuid, jsonb, text)
  to service_role;
