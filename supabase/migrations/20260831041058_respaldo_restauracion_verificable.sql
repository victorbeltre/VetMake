-- Respaldo operativo completo por clínica y simulación de restauración.
--
-- Este respaldo complementa, pero no reemplaza, un volcado lógico del proyecto:
-- Auth, los binarios de Storage, secretos y configuración de plataforma requieren
-- procedimientos separados. La simulación usa exclusivamente tablas temporales.

create or replace function private.generar_respaldo_negocio_impl()
returns jsonb
language plpgsql
security definer
set search_path = ''
set statement_timeout = '30s'
as $$
declare
  negocio uuid;
  usuario uuid;
  nombre_tabla text;
  filas jsonb;
  tablas jsonb := '{}'::jsonb;
  manifiesto_tablas jsonb := '{}'::jsonb;
  archivos jsonb := '[]'::jsonb;
  total_filas bigint := 0;
  version_esquema text;
  nombre_migracion text;
  tablas_respaldo constant text[] := array[
    'negocios',
    'usuarios_negocio',
    'pc_clientes',
    'pc_empleados',
    'pc_inventario',
    'pc_tarifas',
    'pc_ventas',
    'pc_citas',
    'pc_facturas',
    'pc_factura_contadores',
    'pc_pagos',
    'pc_depositos',
    'pc_gastos',
    'pc_seguimientos',
    'pc_historias',
    'pc_fichas_clinicas',
    'pc_paquetes',
    'pc_cliente_aliases',
    'vet_learning_aliases',
    'pc_auditoria'
  ]::text[];
begin
  usuario := auth.uid();
  negocio := public.mi_negocio();
  if usuario is null or negocio is null then
    raise exception using errcode = '42501', message = 'Sesión o clínica no válida.';
  end if;
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception using errcode = '42501', message = 'Solo administración puede generar respaldos.';
  end if;

  foreach nombre_tabla in array tablas_respaldo loop
    if nombre_tabla = 'negocios' then
      execute format(
        'select coalesce(jsonb_agg(to_jsonb(fila) order by to_jsonb(fila)::text), ''[]''::jsonb)
           from public.%I as fila where fila.id = $1',
        nombre_tabla
      ) into filas using negocio;
    else
      execute format(
        'select coalesce(jsonb_agg(to_jsonb(fila) order by to_jsonb(fila)::text), ''[]''::jsonb)
           from public.%I as fila where fila.negocio_id = $1',
        nombre_tabla
      ) into filas using negocio;
    end if;
    tablas := tablas || jsonb_build_object(nombre_tabla, filas);
  end loop;

  select
    coalesce(
      jsonb_object_agg(
        elemento.clave,
        jsonb_build_object('filas', jsonb_array_length(elemento.valor))
        order by elemento.clave
      ),
      '{}'::jsonb
    ),
    coalesce(sum(jsonb_array_length(elemento.valor)), 0)::bigint
  into manifiesto_tablas, total_filas
  from jsonb_each(tablas) as elemento(clave, valor);

  if total_filas > 200000 or octet_length(tablas::text) > 67108864 then
    raise exception using
      errcode = '54000',
      message = 'El respaldo operativo excede 200,000 filas o 64 MB. Usa el volcado lógico administrado.';
  end if;

  select migracion.version, migracion.name
    into version_esquema, nombre_migracion
  from supabase_migrations.schema_migrations as migracion
  order by migracion.version desc
  limit 1;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'bucket', objeto.bucket_id,
        'ruta', objeto.name,
        'metadata', objeto.metadata,
        'creado_en', objeto.created_at,
        'actualizado_en', objeto.updated_at
      ) order by objeto.bucket_id, objeto.name
    ),
    '[]'::jsonb
  ) into archivos
  from storage.objects as objeto
  where objeto.name like negocio::text || '/%';

  return jsonb_build_object(
    'formato', 'vetmake-respaldo-negocio',
    'version', 2,
    'generado_en', clock_timestamp(),
    'negocio_id', negocio,
    'alcance', 'operativo-por-negocio',
    'esquema', jsonb_build_object(
      'migracion_version', version_esquema,
      'migracion_nombre', nombre_migracion
    ),
    'manifiesto', jsonb_build_object(
      'tablas', manifiesto_tablas,
      'total_filas', total_filas,
      'archivos_metadata', jsonb_array_length(archivos)
    ),
    'tablas', tablas,
    'archivos', archivos,
    'exclusiones', jsonb_build_array(
      'Auth: contraseñas, identidades, sesiones y configuración de correo',
      'Storage: contenido binario; solo se incluyen ruta y metadatos',
      'Secretos y configuración de Edge Functions',
      'Configuración del proyecto, DNS, SMTP y proveedores externos',
      'Catálogo global vet_knowledge_products, reproducible por migraciones',
      'Archivos diagnósticos y registros idempotentes del esquema private'
    )
  );
end;
$$;

create or replace function private.probar_respaldo_negocio_impl()
returns jsonb
language plpgsql
security definer
set search_path = ''
set statement_timeout = '45s'
as $$
declare
  respaldo jsonb;
  negocio uuid;
  nombre_tabla text;
  nombre_temporal text;
  filas jsonb;
  filas_esperadas bigint;
  filas_restauradas bigint;
  total_restaurado bigint := 0;
  filas_otro_negocio bigint;
  errores_relaciones bigint := 0;
  auth_membresias_faltantes bigint := 0;
  auth_empleados_faltantes bigint := 0;
  resultado_tablas jsonb := '{}'::jsonb;
  rls_faltante jsonb := '[]'::jsonb;
  funciones_faltantes jsonb := '[]'::jsonb;
  tablas_respaldo constant text[] := array[
    'negocios',
    'usuarios_negocio',
    'pc_clientes',
    'pc_empleados',
    'pc_inventario',
    'pc_tarifas',
    'pc_ventas',
    'pc_citas',
    'pc_facturas',
    'pc_factura_contadores',
    'pc_pagos',
    'pc_depositos',
    'pc_gastos',
    'pc_seguimientos',
    'pc_historias',
    'pc_fichas_clinicas',
    'pc_paquetes',
    'pc_cliente_aliases',
    'vet_learning_aliases',
    'pc_auditoria'
  ]::text[];
  funciones_criticas constant text[] := array[
    'registrar_venta_atomica',
    'corregir_venta',
    'anular_venta',
    'guardar_cita_atomica',
    'eliminar_cita_segura',
    'crear_factura',
    'actualizar_factura',
    'anular_factura',
    'registrar_cobro_venta',
    'guardar_cliente_crm_atomico',
    'guardar_ficha_clinica_atomica',
    'guardar_ficha_medica_atomica',
    'guardar_inventario_lote',
    'guardar_tarifas_lote'
  ]::text[];
begin
  respaldo := private.generar_respaldo_negocio_impl();
  negocio := (respaldo ->> 'negocio_id')::uuid;

  if respaldo ->> 'formato' <> 'vetmake-respaldo-negocio'
     or (respaldo ->> 'version')::integer <> 2
     or jsonb_typeof(respaldo -> 'tablas') <> 'object' then
    raise exception using errcode = '22023', message = 'El paquete de respaldo no tiene un formato compatible.';
  end if;

  if exists (
    select 1 from unnest(tablas_respaldo) as esperada(nombre)
    where not (respaldo -> 'tablas' ? esperada.nombre)
  ) or exists (
    select 1 from jsonb_object_keys(respaldo -> 'tablas') as presente(nombre)
    where not (presente.nombre = any(tablas_respaldo))
  ) then
    raise exception using errcode = '22023', message = 'El paquete no contiene exactamente las tablas esperadas.';
  end if;

  foreach nombre_tabla in array tablas_respaldo loop
    filas := respaldo #> array['tablas', nombre_tabla];
    if jsonb_typeof(filas) <> 'array' then
      raise exception using errcode = '22023', message = 'Una tabla del respaldo no contiene una lista de filas.';
    end if;
    filas_esperadas := (respaldo #>> array['manifiesto', 'tablas', nombre_tabla, 'filas'])::bigint;
    if filas_esperadas is null or filas_esperadas <> jsonb_array_length(filas) then
      raise exception using errcode = '22023', message = 'El manifiesto no coincide con el contenido del respaldo.';
    end if;

    nombre_temporal := 'vetmake_restore_' || nombre_tabla;
    execute format('drop table if exists pg_temp.%I', nombre_temporal);
    execute format(
      'create temporary table %I (like public.%I including all) on commit drop',
      nombre_temporal,
      nombre_tabla
    );
    if nombre_tabla = 'vet_learning_aliases' then
      execute format(
        'insert into pg_temp.%I overriding system value
         select * from jsonb_populate_recordset(null::public.%I, $1)',
        nombre_temporal,
        nombre_tabla
      ) using filas;
    else
      execute format(
        'insert into pg_temp.%I
         select * from jsonb_populate_recordset(null::public.%I, $1)',
        nombre_temporal,
        nombre_tabla
      ) using filas;
    end if;

    execute format('select count(*)::bigint from pg_temp.%I', nombre_temporal)
      into filas_restauradas;
    if filas_restauradas <> filas_esperadas then
      raise exception using errcode = 'P0001', message = 'La restauración temporal perdió filas.';
    end if;

    if nombre_tabla = 'negocios' then
      execute format(
        'select count(*)::bigint from pg_temp.%I where id is distinct from $1',
        nombre_temporal
      ) into filas_otro_negocio using negocio;
    else
      execute format(
        'select count(*)::bigint from pg_temp.%I where negocio_id is distinct from $1',
        nombre_temporal
      ) into filas_otro_negocio using negocio;
    end if;
    if filas_otro_negocio <> 0 then
      raise exception using errcode = '42501', message = 'El respaldo contiene filas de otra clínica.';
    end if;

    total_restaurado := total_restaurado + filas_restauradas;
    resultado_tablas := resultado_tablas || jsonb_build_object(
      nombre_tabla,
      jsonb_build_object('esperadas', filas_esperadas, 'restauradas', filas_restauradas)
    );
  end loop;

  if total_restaurado <> (respaldo #>> array['manifiesto', 'total_filas'])::bigint then
    raise exception using errcode = 'P0001', message = 'El total restaurado no coincide con el manifiesto.';
  end if;

  select count(*)::bigint into errores_relaciones
  from pg_temp.vetmake_restore_pc_cliente_aliases as alias
  left join pg_temp.vetmake_restore_pc_clientes as cliente
    on cliente.negocio_id = alias.negocio_id and cliente.id = alias.cliente_id
  where cliente.id is null;

  errores_relaciones := errores_relaciones + (
    select count(*)::bigint
    from pg_temp.vetmake_restore_pc_citas as cita
    left join pg_temp.vetmake_restore_pc_ventas as venta
      on venta.negocio_id = cita.negocio_id and venta.id = cita.venta_id
    where cita.venta_id is not null and venta.id is null
  );

  errores_relaciones := errores_relaciones + (
    select count(*)::bigint
    from pg_temp.vetmake_restore_pc_ventas as venta
    left join pg_temp.vetmake_restore_pc_empleados as empleado
      on empleado.negocio_id = venta.negocio_id and empleado.id = venta.empleadoid
    where venta.empleadoid is not null and empleado.id is null
  );

  if errores_relaciones <> 0 then
    raise exception using errcode = '23503', message = 'La restauración temporal encontró relaciones internas rotas.';
  end if;

  select count(*)::bigint into auth_membresias_faltantes
  from pg_temp.vetmake_restore_usuarios_negocio as membresia
  left join auth.users as cuenta on cuenta.id = membresia.usuario_id
  where cuenta.id is null;

  select count(*)::bigint into auth_empleados_faltantes
  from pg_temp.vetmake_restore_pc_empleados as empleado
  left join auth.users as cuenta on cuenta.id = empleado.usuario_id
  where empleado.usuario_id is not null and cuenta.id is null;

  select coalesce(jsonb_agg(esperada.nombre order by esperada.nombre), '[]'::jsonb)
    into rls_faltante
  from unnest(tablas_respaldo) as esperada(nombre)
  where not exists (
    select 1
    from pg_class as tabla
    join pg_namespace as esquema on esquema.oid = tabla.relnamespace
    where esquema.nspname = 'public'
      and tabla.relname = esperada.nombre
      and tabla.relrowsecurity
  );

  select coalesce(jsonb_agg(esperada.nombre order by esperada.nombre), '[]'::jsonb)
    into funciones_faltantes
  from unnest(funciones_criticas) as esperada(nombre)
  where not exists (
    select 1
    from pg_proc as funcion
    join pg_namespace as esquema on esquema.oid = funcion.pronamespace
    where esquema.nspname = 'public'
      and funcion.proname = esperada.nombre
  );

  return jsonb_build_object(
    'exito',
      jsonb_array_length(rls_faltante) = 0
      and jsonb_array_length(funciones_faltantes) = 0
      and auth_membresias_faltantes = 0
      and auth_empleados_faltantes = 0,
    'modo', 'tablas-temporales-sin-escrituras-reales',
    'negocio_id', negocio,
    'generado_en', clock_timestamp(),
    'esquema', respaldo -> 'esquema',
    'total_filas', total_restaurado,
    'tablas', resultado_tablas,
    'validaciones', jsonb_build_object(
      'claves_unicas_y_checks', true,
      'aislamiento_negocio', true,
      'relaciones_internas_rotas', errores_relaciones,
      'rls_faltante', rls_faltante,
      'funciones_criticas_faltantes', funciones_faltantes,
      'membresias_auth_faltantes', auth_membresias_faltantes,
      'empleados_auth_faltantes', auth_empleados_faltantes
    ),
    'archivos', jsonb_build_object(
      'metadata_verificada', jsonb_array_length(respaldo -> 'archivos'),
      'binarios_restaurados', false
    ),
    'exclusiones', respaldo -> 'exclusiones'
  );
end;
$$;

create or replace function public.generar_respaldo_negocio()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.generar_respaldo_negocio_impl();
$$;

create or replace function public.probar_respaldo_negocio()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.probar_respaldo_negocio_impl();
$$;

revoke all on function private.generar_respaldo_negocio_impl()
  from public, anon;
revoke all on function private.probar_respaldo_negocio_impl()
  from public, anon;
revoke all on function public.generar_respaldo_negocio()
  from public, anon;
revoke all on function public.probar_respaldo_negocio()
  from public, anon;

grant usage on schema private to authenticated, service_role;
grant execute on function private.generar_respaldo_negocio_impl()
  to authenticated, service_role;
grant execute on function private.probar_respaldo_negocio_impl()
  to authenticated, service_role;
grant execute on function public.generar_respaldo_negocio()
  to authenticated, service_role;
grant execute on function public.probar_respaldo_negocio()
  to authenticated, service_role;

comment on function public.generar_respaldo_negocio() is
  'Exporta las 20 tablas operativas de la clínica, su manifiesto y metadatos de Storage; solo administración.';
comment on function public.probar_respaldo_negocio() is
  'Reconstruye el respaldo en tablas temporales y verifica conteos, restricciones, relaciones, RLS y RPC sin modificar datos reales.';

notify pgrst, 'reload schema';
