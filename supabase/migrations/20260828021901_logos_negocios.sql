insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('logos-negocios', 'logos-negocios', true, 2097152,
  array['image/png','image/jpeg','image/webp'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types
where (
  storage.buckets.public,
  storage.buckets.file_size_limit,
  storage.buckets.allowed_mime_types
) is distinct from (
  excluded.public,
  excluded.file_size_limit,
  excluded.allowed_mime_types
);

-- La migración puede reconciliar un proyecto donde el bucket se creó desde
-- el Dashboard. Las políticas se reemplazan para evitar nombres duplicados y
-- para que una membresía desactivada deje de autorizar inmediatamente: la
-- versión endurecida de mi_negocio() devuelve NULL para membresías inactivas.
drop policy if exists "logos negocio insertar admin" on storage.objects;
drop policy if exists "logos negocio leer admin" on storage.objects;
drop policy if exists "logos negocio actualizar admin" on storage.objects;
drop policy if exists "logos negocio eliminar admin" on storage.objects;

create policy "logos negocio insertar admin" on storage.objects
for insert to authenticated
with check (bucket_id = 'logos-negocios' and exists (
  select 1 from public.usuarios_negocio u
  where u.usuario_id = (select auth.uid()) and u.rol = 'admin'
    and u.negocio_id = (select public.mi_negocio())
    and u.negocio_id::text = (storage.foldername(name))[1]
));
create policy "logos negocio leer admin" on storage.objects
for select to authenticated
using (bucket_id = 'logos-negocios' and exists (
  select 1 from public.usuarios_negocio u
  where u.usuario_id = (select auth.uid()) and u.rol = 'admin'
    and u.negocio_id = (select public.mi_negocio())
    and u.negocio_id::text = (storage.foldername(name))[1]
));

create policy "logos negocio actualizar admin" on storage.objects
for update to authenticated
using (bucket_id = 'logos-negocios' and exists (
  select 1 from public.usuarios_negocio u
  where u.usuario_id = (select auth.uid()) and u.rol = 'admin'
    and u.negocio_id = (select public.mi_negocio())
    and u.negocio_id::text = (storage.foldername(name))[1]
))
with check (bucket_id = 'logos-negocios' and exists (
  select 1 from public.usuarios_negocio u
  where u.usuario_id = (select auth.uid()) and u.rol = 'admin'
    and u.negocio_id = (select public.mi_negocio())
    and u.negocio_id::text = (storage.foldername(name))[1]
));

create policy "logos negocio eliminar admin" on storage.objects
for delete to authenticated
using (bucket_id = 'logos-negocios' and exists (
  select 1 from public.usuarios_negocio u
  where u.usuario_id = (select auth.uid()) and u.rol = 'admin'
    and u.negocio_id = (select public.mi_negocio())
    and u.negocio_id::text = (storage.foldername(name))[1]
));
