-- VetMake · Vinculación atómica de usuarios y empleados
--
-- Auth puede enviar la invitación fuera de PostgreSQL, pero la membresía y el
-- empleado deben quedar vinculados juntos o no cambiar ninguno.

create or replace function public.vetmake_vincular_empleado(
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
  membresia_otro uuid;
  empleado_vinculado text;
begin
  if p_solicitante is null or p_usuario_id is null
     or nullif(btrim(coalesce(p_empleado_id, '')), '') is null then
    raise exception using errcode = '22023', message = 'Faltan datos para vincular el acceso.';
  end if;

  if p_rol not in ('admin', 'caja', 'veterinario', 'groomer') then
    raise exception using errcode = '22023', message = 'El rol solicitado no es válido.';
  end if;

  if nullif(btrim(coalesce(p_email, '')), '') is null
     or p_email !~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
    raise exception using errcode = '22023', message = 'El correo solicitado no es válido.';
  end if;

  select membresia.negocio_id
  into negocio
  from public.usuarios_negocio as membresia
  join public.negocios as clinica on clinica.id = membresia.negocio_id
  where membresia.usuario_id = p_solicitante
    and membresia.rol = 'admin'
    and membresia.activo = true
    and clinica.activo = true;

  if negocio is null then
    raise exception using errcode = '42501', message = 'Solo un administrador activo puede vincular personal.';
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

  select membresia.negocio_id
  into membresia_otro
  from public.usuarios_negocio as membresia
  where membresia.usuario_id = p_usuario_id
  for update;

  if membresia_otro is not null and membresia_otro <> negocio then
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

  if membresia_otro is null then
    insert into public.usuarios_negocio (usuario_id, negocio_id, rol, activo)
    values (p_usuario_id, negocio, p_rol, true)
    on conflict (usuario_id) do nothing;

    if not found then
      select membresia.negocio_id
      into membresia_otro
      from public.usuarios_negocio as membresia
      where membresia.usuario_id = p_usuario_id;
      if membresia_otro is distinct from negocio then
        raise exception using errcode = '23505', message = 'Ese usuario fue asignado simultáneamente a otra clínica.';
      end if;
    end if;
  end if;

  update public.usuarios_negocio
  set rol = p_rol,
      activo = true
  where usuario_id = p_usuario_id
    and negocio_id = negocio;

  update public.pc_empleados
  set usuario_id = p_usuario_id,
      email = lower(btrim(p_email)),
      rol = p_rol
  where id = empleado.id
    and negocio_id = negocio
  returning * into empleado;

  return to_jsonb(empleado);
end;
$$;

revoke all on function public.vetmake_vincular_empleado(uuid, text, uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.vetmake_vincular_empleado(uuid, text, uuid, text, text)
  to service_role;
