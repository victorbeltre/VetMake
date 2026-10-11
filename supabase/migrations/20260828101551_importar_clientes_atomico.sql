-- VetMake · importación masiva y atómica de clientes
--
-- El importador heredado enviaba lotes directamente a pc_clientes y asignaba
-- identificadores con Date.now(). Esta operación valida el lote completo,
-- reutiliza la validación canónica del CRM, asigna IDs en PostgreSQL y permite
-- reintentar una respuesta perdida sin duplicar pacientes.

alter table private.vetmake_clinica_operaciones
  drop constraint if exists vetmake_clinica_operaciones_accion_chk;

alter table private.vetmake_clinica_operaciones
  add constraint vetmake_clinica_operaciones_accion_chk
  check (accion in (
    'guardar_ficha',
    'guardar_ficha_medica',
    'guardar_telefono_venta',
    'guardar_cliente_crm',
    'importar_clientes'
  ));

create or replace function private.importar_clientes_atomico_impl(
  p_clientes jsonb,
  p_fuente text,
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
  fuente_limpia text;
  cantidad integer;
  posicion bigint;
  cliente_datos jsonb;
  cliente_resultado jsonb;
  clientes_resultado jsonb := '[]'::jsonb;
  operacion_fila uuid;
  accion_previa text;
  resultado_previo jsonb;
  resultado jsonb;
  error_estado text;
  error_mensaje text;
begin
  usuario := auth.uid();
  negocio := public.mi_negocio();

  if usuario is null or negocio is null then
    raise exception using errcode = '42501', message = 'Sesión o clínica no válida.';
  end if;
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception using errcode = '42501', message = 'Solo administración puede importar clientes.';
  end if;
  if p_operacion_id is null then
    raise exception using errcode = '22023', message = 'La importación requiere un identificador idempotente.';
  end if;
  if p_clientes is null or jsonb_typeof(p_clientes) <> 'array' then
    raise exception using errcode = '22023', message = 'El lote de clientes no tiene un formato válido.';
  end if;
  if octet_length(p_clientes::text) > 4194304 then
    raise exception using errcode = '22023', message = 'El lote de clientes excede el tamaño permitido.';
  end if;

  cantidad := jsonb_array_length(p_clientes);
  if cantidad < 1 or cantidad > 200 then
    raise exception using errcode = '22023', message = 'Cada lote debe contener entre 1 y 200 clientes.';
  end if;

  fuente_limpia := nullif(
    left(btrim(regexp_replace(coalesce(p_fuente, ''), '[<>]', '', 'g')), 500),
    ''
  );
  if fuente_limpia is null then
    raise exception using errcode = '22023', message = 'La importación requiere una fuente identificable.';
  end if;

  -- Serializa únicamente los reintentos de este lote. El bloqueo desaparece
  -- al cerrar la transacción y no retiene filas de clientes durante la carga.
  perform pg_advisory_xact_lock(hashtextextended(
    negocio::text || ':importar-clientes:' || p_operacion_id::text,
    0
  ));

  select operacion.accion, operacion.resultado
    into accion_previa, resultado_previo
  from private.vetmake_clinica_operaciones as operacion
  where operacion.negocio_id = negocio
    and operacion.operacion_id = p_operacion_id;

  if found then
    if accion_previa <> 'importar_clientes' then
      raise exception using errcode = '22023', message = 'El identificador ya pertenece a otra operación.';
    end if;
    return resultado_previo;
  end if;

  for cliente_datos, posicion in
    select fila.value, fila.ordinality
    from jsonb_array_elements(p_clientes) with ordinality as fila(value, ordinality)
    order by fila.ordinality
  loop
    if jsonb_typeof(cliente_datos) <> 'object' then
      raise exception using
        errcode = '22023',
        message = format('Fila %s: los datos del cliente no tienen un formato válido.', posicion);
    end if;

    -- Cada fila recibe un UUID estable derivado del lote y su posición. La
    -- operación individual conserva así su propia trazabilidad e idempotencia.
    operacion_fila := md5(
      negocio::text || ':importar-clientes:' || p_operacion_id::text || ':' || posicion::text
    )::uuid;

    begin
      cliente_resultado := private.guardar_cliente_crm_atomico_impl(
        null,
        cliente_datos,
        operacion_fila
      );
    exception
      when others then
        get stacked diagnostics
          error_estado = returned_sqlstate,
          error_mensaje = message_text;
        raise exception using
          errcode = error_estado,
          message = format('Fila %s: %s', posicion, error_mensaje);
    end;

    if cliente_resultado -> 'cliente' is null then
      raise exception using
        errcode = 'P0001',
        message = format('Fila %s: el servidor no confirmó el cliente.', posicion);
    end if;

    clientes_resultado := clientes_resultado || jsonb_build_array(cliente_resultado -> 'cliente');
  end loop;

  resultado := jsonb_build_object(
    'clientes', clientes_resultado,
    'cantidad', cantidad,
    'fuente', fuente_limpia,
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
    'importar_clientes',
    resultado
  );

  return resultado;
end;
$$;

create or replace function public.importar_clientes_atomico(
  p_clientes jsonb,
  p_fuente text,
  p_operacion_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.importar_clientes_atomico_impl(
    p_clientes,
    p_fuente,
    p_operacion_id
  );
$$;

revoke all on function private.importar_clientes_atomico_impl(jsonb, text, uuid)
  from public, anon;
revoke all on function public.importar_clientes_atomico(jsonb, text, uuid)
  from public, anon;

grant usage on schema private to authenticated, service_role;
grant execute on function private.importar_clientes_atomico_impl(jsonb, text, uuid)
  to authenticated, service_role;
grant execute on function public.importar_clientes_atomico(jsonb, text, uuid)
  to authenticated, service_role;

-- La tabla queda de solo lectura para el Data API autenticado. Todas las
-- altas, ediciones y bajas pasan por RPC con reglas explícitas de negocio.
revoke insert, update, delete on table public.pc_clientes from authenticated;

drop policy if exists clientes_equipo_inserta on public.pc_clientes;
drop policy if exists clientes_equipo_actualiza on public.pc_clientes;
drop policy if exists clientes_admin_borra on public.pc_clientes;

comment on function public.importar_clientes_atomico(jsonb, text, uuid) is
  'Importa de 1 a 200 clientes en una sola transacción, con IDs de servidor, validación e idempotencia.';

notify pgrst, 'reload schema';
