-- El trigger debe distinguir una actualización directa del rol `authenticated`
-- de una actualización hecha dentro de la función SECURITY DEFINER. Usar el
-- rol efectivo evita que un indicador de sesión sobreviva durante la transacción.

create or replace function public.proteger_cobros_venta()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op <> 'UPDATE' then
    return new;
  end if;

  -- Las funciones financieras SECURITY DEFINER y las migraciones ejecutan con
  -- un rol de servidor. Las escrituras REST ordinarias ejecutan como authenticated.
  if current_user <> 'authenticated' then
    return new;
  end if;

  if new.abonos is distinct from old.abonos
     or new.abonado is distinct from old.abonado
     or new.formapago is distinct from old.formapago
     or new.fecharecordatorio is distinct from old.fecharecordatorio
     or new.cobradopor is distinct from old.cobradopor then
    raise exception using
      errcode = '42501',
      message = 'Los cobros deben registrarse con la operación transaccional de VetMake.';
  end if;

  if coalesce(old.abonado, 0) > 0
     and new.total is distinct from old.total then
    raise exception using
      errcode = '42501',
      message = 'No se puede cambiar el total de una venta que ya tiene abonos.';
  end if;

  return new;
end;
$$;

revoke all on function public.proteger_cobros_venta()
  from public, anon, authenticated;
