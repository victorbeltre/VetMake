-- VetMake · Fusión y eliminación segura de clientes
--
-- La aplicación heredada identificaba como «virtual» cualquier id >= 90000 y
-- borraba duplicados uno por uno. Eso podía clasificar mal clientes reales,
-- dejar expedientes clínicos huérfanos y producir fusiones parciales.

create unique index if not exists pc_clientes_negocio_id_id_uidx
  on public.pc_clientes (negocio_id, id);

alter table public.pc_clientes
  add column if not exists telefono2 text,
  add column if not exists pesokg numeric,
  add column if not exists edad text,
  add column if not exists microchip text,
  add column if not exists vacunas jsonb not null default '[]'::jsonb,
  add column if not exists estudios jsonb not null default '[]'::jsonb,
  add column if not exists fotosmascota jsonb not null default '[]'::jsonb,
  add column if not exists banos2025 integer not null default 0;

create table if not exists public.pc_cliente_aliases (
  id uuid primary key default gen_random_uuid(),
  negocio_id uuid not null references public.negocios(id) on delete cascade,
  cliente_id numeric not null,
  alias text not null,
  alias_normalizado text not null,
  creado_por uuid,
  created_at timestamptz not null default now(),
  constraint pc_cliente_aliases_alias_no_vacio_chk
    check (char_length(btrim(alias_normalizado)) between 1 and 160),
  constraint pc_cliente_aliases_negocio_alias_uidx
    unique (negocio_id, alias_normalizado)
);

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'pc_cliente_aliases_cliente_fkey'
      and conrelid = 'public.pc_cliente_aliases'::regclass
  ) then
    alter table public.pc_cliente_aliases
      add constraint pc_cliente_aliases_cliente_fkey
      foreign key (negocio_id, cliente_id)
      references public.pc_clientes (negocio_id, id)
      on update cascade
      on delete cascade;
  end if;
end
$$;

create index if not exists pc_cliente_aliases_cliente_idx
  on public.pc_cliente_aliases (negocio_id, cliente_id);

alter table public.pc_cliente_aliases enable row level security;

revoke all on table public.pc_cliente_aliases from public, anon, authenticated;
grant select on table public.pc_cliente_aliases to authenticated;

drop policy if exists cliente_aliases_equipo_lee on public.pc_cliente_aliases;
create policy cliente_aliases_equipo_lee
  on public.pc_cliente_aliases
  for select
  to authenticated
  using (
    negocio_id = (select public.mi_negocio())
    and (select public.tiene_rol(array['admin','caja','veterinario','groomer']::text[]))
  );

create table if not exists private.vetmake_cliente_operaciones (
  negocio_id uuid not null references public.negocios(id) on delete cascade,
  usuario_id uuid not null,
  operacion_id uuid not null,
  accion text not null,
  resultado jsonb not null,
  created_at timestamptz not null default now(),
  primary key (negocio_id, operacion_id),
  constraint vetmake_cliente_operaciones_accion_chk
    check (accion in ('fusionar', 'eliminar'))
);

create index if not exists vetmake_cliente_operaciones_usuario_idx
  on private.vetmake_cliente_operaciones (usuario_id, created_at desc);

alter table private.vetmake_cliente_operaciones enable row level security;
revoke all on table private.vetmake_cliente_operaciones from public, anon, authenticated;

create or replace function private.fusionar_clientes_impl(
  p_principal_id numeric,
  p_duplicados numeric[],
  p_cliente jsonb,
  p_aliases text[],
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
  principal_id numeric := p_principal_id;
  duplicados numeric[];
  aliases_limpios text[];
  resultado_previo jsonb;
  accion_previa text;
  resultado jsonb;
  principal public.pc_clientes%rowtype;
  esperado integer;
  encontrado integer;
  intento integer := 0;
  mov_historias integer := 0;
  mov_fichas integer := 0;
  mov_citas integer := 0;
  mov_facturas integer := 0;
  mov_paquetes integer := 0;
begin
  usuario := auth.uid();
  negocio := public.mi_negocio();

  if usuario is null or negocio is null then
    raise exception 'Sesión o clínica no válida.';
  end if;
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo un administrador puede fusionar clientes.';
  end if;
  if p_operacion_id is null then
    raise exception 'La operación requiere un identificador idempotente.';
  end if;
  if p_principal_id is not null
     and (
       p_principal_id <= 0
       or trunc(p_principal_id) <> p_principal_id
       or p_principal_id > 9223372036854775807::numeric
     ) then
    raise exception 'El cliente principal no tiene un identificador válido.';
  end if;
  if jsonb_typeof(coalesce(p_cliente, '{}'::jsonb)) <> 'object' then
    raise exception 'Los datos del cliente no son válidos.';
  end if;
  if octet_length(coalesce(p_cliente, '{}'::jsonb)::text) > 65536 then
    raise exception 'Los datos del cliente exceden el tamaño permitido.';
  end if;
  if coalesce(cardinality(p_duplicados), 0) > 100
     or coalesce(cardinality(p_aliases), 0) > 200 then
    raise exception 'La fusión contiene demasiados clientes o alias.';
  end if;

  -- Un mismo UUID solo puede ejecutarse una vez a la vez. Esto convierte dos
  -- clics simultáneos y los reintentos tras una respuesta perdida en la misma
  -- operación, no en dos fusiones que compitan entre sí.
  perform pg_advisory_xact_lock(hashtextextended(
    negocio::text || ':fusionar-clientes:' || p_operacion_id::text,
    0
  ));

  select operacion.accion, operacion.resultado
    into accion_previa, resultado_previo
  from private.vetmake_cliente_operaciones as operacion
  where operacion.negocio_id = negocio
    and operacion.operacion_id = p_operacion_id;

  if found then
    if accion_previa <> 'fusionar' then
      raise exception 'El identificador ya pertenece a otra operación.';
    end if;
    return resultado_previo;
  end if;

  select coalesce(array_agg(distinct valor), array[]::numeric[])
    into duplicados
  from unnest(coalesce(p_duplicados, array[]::numeric[])) as entrada(valor)
  where valor is not null
    and valor > 0
    and trunc(valor) = valor
    and valor <= 9223372036854775807::numeric
    and (principal_id is null or valor <> principal_id);

  esperado := cardinality(duplicados);

  -- Serializa fusiones que involucren cualquiera de las mismas fichas.
  perform 1
  from public.pc_clientes as cliente
  where cliente.negocio_id = negocio
    and (
      cliente.id = principal_id
      or cliente.id = any(duplicados)
    )
  order by cliente.id
  for update;

  select count(*)
    into encontrado
  from public.pc_clientes as cliente
  where cliente.negocio_id = negocio
    and cliente.id = any(duplicados);

  if encontrado <> esperado then
    raise exception 'Uno o más clientes duplicados ya no existen o pertenecen a otra clínica.';
  end if;

  if principal_id is not null then
    select cliente.*
      into principal
    from public.pc_clientes as cliente
    where cliente.negocio_id = negocio
      and cliente.id = principal_id;

    if not found then
      raise exception 'El cliente principal no existe o pertenece a otra clínica.';
    end if;
  else
    -- Las fichas que solo existían como nombres de ventas reciben su ID de la
    -- misma secuencia de pacientes usada por admisión e historias clínicas.
    loop
      intento := intento + 1;
      principal_id := nextval('private.pc_clientes_admision_id_seq'::regclass);
      exit when not exists (
        select 1 from public.pc_clientes where id = principal_id
      );
      if intento >= 5 then
        raise exception 'No se pudo asignar un identificador único al cliente principal.';
      end if;
    end loop;
  end if;

  -- Aunque un navegador antiguo no envíe los alias, el servidor conserva los
  -- nombres de todas las fichas que eliminará. Así las ventas históricas no
  -- vuelven a crear duplicados virtuales después de la fusión.
  select coalesce(array_agg(distinct valor), array[]::text[])
    into aliases_limpios
  from (
    select left(lower(regexp_replace(btrim(regexp_replace(alias, '[<>]', '', 'g')), '\s+', ' ', 'g')), 160) as valor
    from unnest(coalesce(p_aliases, array[]::text[])) as entrada(alias)
    where nullif(btrim(alias), '') is not null
    union all
    select left(lower(regexp_replace(btrim(regexp_replace(coalesce(cliente.nombremascota, ''), '[<>]', '', 'g')), '\s+', ' ', 'g')), 160)
    from public.pc_clientes as cliente
    where cliente.negocio_id = negocio
      and cliente.id = any(duplicados)
  ) as normalizados
  where nullif(valor, '') is not null;

  if exists (
    select 1
    from public.pc_cliente_aliases as alias_existente
    where alias_existente.negocio_id = negocio
      and alias_existente.alias_normalizado = any(aliases_limpios)
      and alias_existente.cliente_id <> principal_id
      and not (alias_existente.cliente_id = any(duplicados))
  ) then
    raise exception 'Uno de los alias ya pertenece a otro cliente. Revisa la selección antes de fusionar.';
  end if;

  insert into public.pc_clientes as actual (
    id,
    nombremascota,
    especie,
    raza,
    sexo,
    fechanacimiento,
    color,
    tamano,
    esterilizado,
    nombrepropietario,
    telefono,
    email,
    direccion,
    instagram,
    alergias,
    medicamentos,
    condiciones,
    veterinarioexterno,
    notas,
    fecharegistro,
    ultimavisita2025,
    cedula,
    alertamedica,
    telefono2,
    pesokg,
    edad,
    microchip,
    vacunas,
    estudios,
    fotosmascota,
    banos2025,
    negocio_id
  )
  values (
    principal_id,
    nullif(left(btrim(coalesce(p_cliente ->> 'nombreMascota', p_cliente ->> 'nombremascota', '')), 160), ''),
    nullif(left(btrim(coalesce(p_cliente ->> 'especie', '')), 80), ''),
    nullif(left(btrim(coalesce(p_cliente ->> 'raza', '')), 120), ''),
    nullif(left(btrim(coalesce(p_cliente ->> 'sexo', '')), 40), ''),
    nullif(left(btrim(coalesce(p_cliente ->> 'fechaNacimiento', p_cliente ->> 'fechanacimiento', '')), 40), ''),
    nullif(left(btrim(coalesce(p_cliente ->> 'color', '')), 120), ''),
    nullif(left(btrim(coalesce(p_cliente ->> 'tamano', '')), 80), ''),
    case
      when p_cliente ? 'esterilizado'
        then lower(coalesce(p_cliente ->> 'esterilizado', 'false')) in ('true','1','si','sí','yes')
      else null
    end,
    nullif(left(btrim(coalesce(p_cliente ->> 'nombrePropietario', p_cliente ->> 'nombrepropietario', '')), 180), ''),
    nullif(left(btrim(coalesce(p_cliente ->> 'telefono', '')), 80), ''),
    nullif(left(btrim(coalesce(p_cliente ->> 'email', '')), 240), ''),
    nullif(left(btrim(coalesce(p_cliente ->> 'direccion', '')), 500), ''),
    nullif(left(btrim(coalesce(p_cliente ->> 'instagram', '')), 160), ''),
    nullif(left(btrim(coalesce(p_cliente ->> 'alergias', '')), 1000), ''),
    nullif(left(btrim(coalesce(p_cliente ->> 'medicamentos', '')), 1000), ''),
    nullif(left(btrim(coalesce(p_cliente ->> 'condiciones', '')), 1500), ''),
    nullif(left(btrim(coalesce(p_cliente ->> 'veterinarioExterno', p_cliente ->> 'veterinarioexterno', '')), 240), ''),
    nullif(left(btrim(coalesce(p_cliente ->> 'notas', '')), 3000), ''),
    nullif(left(btrim(coalesce(p_cliente ->> 'fechaRegistro', p_cliente ->> 'fecharegistro', '')), 40), ''),
    nullif(left(btrim(coalesce(p_cliente ->> 'ultimaVisita2025', p_cliente ->> 'ultimavisita2025', '')), 40), ''),
    nullif(left(btrim(coalesce(p_cliente ->> 'cedula', '')), 80), ''),
    nullif(left(btrim(coalesce(p_cliente ->> 'alertaMedica', p_cliente ->> 'alertamedica', '')), 1500), ''),
    nullif(left(btrim(coalesce(p_cliente ->> 'telefono2', '')), 80), ''),
    case
      when nullif(btrim(coalesce(p_cliente ->> 'pesoKg', p_cliente ->> 'pesokg', '')), '') is null then null
      when btrim(coalesce(p_cliente ->> 'pesoKg', p_cliente ->> 'pesokg', '')) ~ '^[0-9]+([.][0-9]+)?$'
        then btrim(coalesce(p_cliente ->> 'pesoKg', p_cliente ->> 'pesokg'))::numeric
      else null
    end,
    nullif(left(btrim(coalesce(p_cliente ->> 'edad', '')), 80), ''),
    nullif(left(btrim(coalesce(p_cliente ->> 'microchip', '')), 160), ''),
    case
      when jsonb_typeof(p_cliente -> 'vacunas') = 'array' then p_cliente -> 'vacunas'
      else '[]'::jsonb
    end,
    case
      when jsonb_typeof(p_cliente -> 'estudios') = 'array' then p_cliente -> 'estudios'
      else '[]'::jsonb
    end,
    case
      when jsonb_typeof(p_cliente -> 'fotosMascota') = 'array' then p_cliente -> 'fotosMascota'
      when jsonb_typeof(p_cliente -> 'fotosmascota') = 'array' then p_cliente -> 'fotosmascota'
      else '[]'::jsonb
    end,
    case
      when btrim(coalesce(p_cliente ->> 'banos2025', '')) ~ '^[0-9]+$'
        then greatest(0, (p_cliente ->> 'banos2025')::integer)
      else 0
    end,
    negocio
  )
  on conflict (id) do update
    set nombremascota = coalesce(excluded.nombremascota, actual.nombremascota),
        especie = coalesce(excluded.especie, actual.especie),
        raza = coalesce(excluded.raza, actual.raza),
        sexo = coalesce(excluded.sexo, actual.sexo),
        fechanacimiento = coalesce(excluded.fechanacimiento, actual.fechanacimiento),
        color = coalesce(excluded.color, actual.color),
        tamano = coalesce(excluded.tamano, actual.tamano),
        esterilizado = coalesce(excluded.esterilizado, actual.esterilizado),
        nombrepropietario = coalesce(excluded.nombrepropietario, actual.nombrepropietario),
        telefono = coalesce(excluded.telefono, actual.telefono),
        email = coalesce(excluded.email, actual.email),
        direccion = coalesce(excluded.direccion, actual.direccion),
        instagram = coalesce(excluded.instagram, actual.instagram),
        alergias = coalesce(excluded.alergias, actual.alergias),
        medicamentos = coalesce(excluded.medicamentos, actual.medicamentos),
        condiciones = coalesce(excluded.condiciones, actual.condiciones),
        veterinarioexterno = coalesce(excluded.veterinarioexterno, actual.veterinarioexterno),
        notas = coalesce(excluded.notas, actual.notas),
        fecharegistro = coalesce(excluded.fecharegistro, actual.fecharegistro),
        ultimavisita2025 = coalesce(excluded.ultimavisita2025, actual.ultimavisita2025),
        cedula = coalesce(excluded.cedula, actual.cedula),
        alertamedica = coalesce(excluded.alertamedica, actual.alertamedica),
        telefono2 = coalesce(excluded.telefono2, actual.telefono2),
        pesokg = coalesce(excluded.pesokg, actual.pesokg),
        edad = coalesce(excluded.edad, actual.edad),
        microchip = coalesce(excluded.microchip, actual.microchip),
        vacunas = case when excluded.vacunas = '[]'::jsonb then actual.vacunas else excluded.vacunas end,
        estudios = case when excluded.estudios = '[]'::jsonb then actual.estudios else excluded.estudios end,
        fotosmascota = case when excluded.fotosmascota = '[]'::jsonb then actual.fotosmascota else excluded.fotosmascota end,
        banos2025 = greatest(actual.banos2025, excluded.banos2025)
  where actual.negocio_id = negocio
  returning * into principal;

  if principal.id is null then
    raise exception 'El identificador principal ya está ocupado por otra clínica.';
  end if;

  if esperado > 0 then
    update public.pc_historias
       set clienteid = principal_id::text
     where negocio_id = negocio
       and clienteid = any(
         select valor::text from unnest(duplicados) as ids(valor)
       );
    get diagnostics mov_historias = row_count;

    update public.pc_fichas_clinicas
       set clienteid = principal_id::text
     where negocio_id = negocio
       and clienteid = any(
         select valor::text from unnest(duplicados) as ids(valor)
       );
    get diagnostics mov_fichas = row_count;

    update public.pc_citas
       set clienteid = principal_id::bigint
     where negocio_id = negocio
       and clienteid = any(
         select valor::bigint from unnest(duplicados) as ids(valor)
       );
    get diagnostics mov_citas = row_count;

    update public.pc_facturas
       set clienteid = principal_id::text
     where negocio_id = negocio
       and clienteid = any(
         select valor::text from unnest(duplicados) as ids(valor)
       );
    get diagnostics mov_facturas = row_count;

    update public.pc_paquetes
       set clienteid = principal_id::text
     where negocio_id = negocio
       and clienteid = any(
         select valor::text from unnest(duplicados) as ids(valor)
       );
    get diagnostics mov_paquetes = row_count;

    update public.pc_cliente_aliases
       set cliente_id = principal_id
     where negocio_id = negocio
       and cliente_id = any(duplicados);

    delete from public.pc_clientes
     where negocio_id = negocio
       and id = any(duplicados);
  end if;

  insert into public.pc_cliente_aliases (
    negocio_id,
    cliente_id,
    alias,
    alias_normalizado,
    creado_por
  )
  select
    negocio,
    principal_id,
    alias_normalizado,
    alias_normalizado,
    usuario
  from unnest(aliases_limpios) as aliases(alias_normalizado)
  on conflict (negocio_id, alias_normalizado) do update
    set cliente_id = excluded.cliente_id,
        alias = excluded.alias,
        creado_por = excluded.creado_por;

  resultado := jsonb_build_object(
    'cliente', to_jsonb(principal) - 'negocio_id',
    'clienteNuevo', p_principal_id is null,
    'eliminados', to_jsonb(duplicados),
    'operacionId', p_operacion_id,
    'aliases', coalesce((
      select jsonb_agg(to_jsonb(alias_fila) - 'negocio_id')
      from public.pc_cliente_aliases as alias_fila
      where alias_fila.negocio_id = negocio
        and alias_fila.cliente_id = principal_id
    ), '[]'::jsonb),
    'referencias', jsonb_build_object(
      'historias', mov_historias,
      'fichas', mov_fichas,
      'citas', mov_citas,
      'facturas', mov_facturas,
      'paquetes', mov_paquetes
    )
  );

  insert into private.vetmake_cliente_operaciones (
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
    'fusionar',
    resultado
  );

  return resultado;
end;
$$;

create or replace function private.eliminar_cliente_impl(
  p_cliente_id numeric,
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
  cliente_fila public.pc_clientes%rowtype;
  resultado_previo jsonb;
  accion_previa text;
  resultado jsonb;
  dependencias bigint;
  nombres_cliente text[];
begin
  usuario := auth.uid();
  negocio := public.mi_negocio();

  if usuario is null or negocio is null then
    raise exception 'Sesión o clínica no válida.';
  end if;
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo un administrador puede eliminar clientes.';
  end if;
  if p_operacion_id is null then
    raise exception 'La operación requiere un identificador idempotente.';
  end if;
  if p_cliente_id is null
     or p_cliente_id <= 0
     or trunc(p_cliente_id) <> p_cliente_id
     or p_cliente_id > 9223372036854775807::numeric then
    raise exception 'El cliente no tiene un identificador válido.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    negocio::text || ':eliminar-cliente:' || p_operacion_id::text,
    0
  ));

  select operacion.accion, operacion.resultado
    into accion_previa, resultado_previo
  from private.vetmake_cliente_operaciones as operacion
  where operacion.negocio_id = negocio
    and operacion.operacion_id = p_operacion_id;

  if found then
    if accion_previa <> 'eliminar' then
      raise exception 'El identificador ya pertenece a otra operación.';
    end if;
    return resultado_previo;
  end if;

  select *
    into cliente_fila
  from public.pc_clientes
  where negocio_id = negocio
    and id = p_cliente_id
  for update;

  if not found then
    raise exception 'El cliente no existe o pertenece a otra clínica.';
  end if;

  select coalesce(array_agg(distinct nombre), array[]::text[])
    into nombres_cliente
  from (
    select lower(regexp_replace(btrim(coalesce(cliente_fila.nombremascota, '')), '\s+', ' ', 'g')) as nombre
    union all
    select alias_fila.alias_normalizado
    from public.pc_cliente_aliases as alias_fila
    where alias_fila.negocio_id = negocio
      and alias_fila.cliente_id = p_cliente_id
  ) as nombres
  where nullif(nombre, '') is not null;

  select
    (select count(*) from public.pc_historias where negocio_id = negocio and clienteid = p_cliente_id::text)
    + (select count(*) from public.pc_fichas_clinicas where negocio_id = negocio and clienteid = p_cliente_id::text)
    + (select count(*) from public.pc_citas where negocio_id = negocio and clienteid = p_cliente_id::bigint)
    + (select count(*) from public.pc_facturas where negocio_id = negocio and clienteid = p_cliente_id::text)
    + (select count(*) from public.pc_paquetes where negocio_id = negocio and clienteid = p_cliente_id::text)
    + (select count(*) from public.pc_ventas as venta
        where venta.negocio_id = negocio
          and lower(regexp_replace(btrim(coalesce(venta.cliente, '')), '\s+', ' ', 'g')) = any(nombres_cliente))
    + (select count(*) from public.pc_seguimientos as seguimiento
        where seguimiento.negocio_id = negocio
          and lower(regexp_replace(btrim(coalesce(seguimiento.mascota, '')), '\s+', ' ', 'g')) = any(nombres_cliente))
    + (select count(*) from public.pc_depositos as deposito
        where deposito.negocio_id = negocio
          and lower(regexp_replace(btrim(coalesce(deposito.mascota, '')), '\s+', ' ', 'g')) = any(nombres_cliente))
    + (select count(*) from public.pc_citas as cita
        where cita.negocio_id = negocio
          and lower(regexp_replace(btrim(coalesce(cita.nombremascota, '')), '\s+', ' ', 'g')) = any(nombres_cliente))
    + (select count(*) from public.pc_facturas as factura
        where factura.negocio_id = negocio
          and lower(regexp_replace(btrim(coalesce(factura.mascota, '')), '\s+', ' ', 'g')) = any(nombres_cliente))
    + (select count(*) from public.pc_paquetes as paquete
        where paquete.negocio_id = negocio
          and lower(regexp_replace(btrim(coalesce(paquete.mascota, '')), '\s+', ' ', 'g')) = any(nombres_cliente))
    into dependencias;

  if dependencias > 0 then
    raise exception 'Este cliente tiene actividad histórica. No se puede eliminar; fusiónalo con la ficha correcta.';
  end if;

  delete from public.pc_clientes
   where negocio_id = negocio
     and id = p_cliente_id;

  resultado := jsonb_build_object(
    'clienteId', p_cliente_id,
    'operacionId', p_operacion_id
  );

  insert into private.vetmake_cliente_operaciones (
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
    'eliminar',
    resultado
  );

  return resultado;
end;
$$;

create or replace function public.fusionar_clientes(
  p_principal_id numeric,
  p_duplicados numeric[],
  p_cliente jsonb,
  p_aliases text[],
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.fusionar_clientes_impl(
    p_principal_id,
    p_duplicados,
    p_cliente,
    p_aliases,
    p_operacion_id
  );
$$;

create or replace function public.eliminar_cliente(
  p_cliente_id numeric,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.eliminar_cliente_impl(p_cliente_id, p_operacion_id);
$$;

revoke all on function private.fusionar_clientes_impl(numeric, numeric[], jsonb, text[], uuid) from public, anon;
revoke all on function private.eliminar_cliente_impl(numeric, uuid) from public, anon;
revoke all on function public.fusionar_clientes(numeric, numeric[], jsonb, text[], uuid) from public, anon;
revoke all on function public.eliminar_cliente(numeric, uuid) from public, anon;

grant usage on schema private to authenticated, service_role;
grant execute on function private.fusionar_clientes_impl(numeric, numeric[], jsonb, text[], uuid) to authenticated, service_role;
grant execute on function private.eliminar_cliente_impl(numeric, uuid) to authenticated, service_role;
grant execute on function public.fusionar_clientes(numeric, numeric[], jsonb, text[], uuid) to authenticated, service_role;
grant execute on function public.eliminar_cliente(numeric, uuid) to authenticated, service_role;

-- Todo borrado real de clientes pasa por las validaciones anteriores. La
-- fusión privada conserva primero las referencias clínicas y contables.
revoke delete on table public.pc_clientes from authenticated;
