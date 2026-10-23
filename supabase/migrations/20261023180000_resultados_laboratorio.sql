-- Resultados de laboratorio (hemograma) en la Evolución del paciente.
--
-- Viene de PetColinas (M21). Se sube el informe del laboratorio (PDF o foto) y
-- se le pone ENCIMA la marca de la clínica. Los resultados NO se leen ni se
-- reescriben: el documento se usa como IMAGEN, así que ningún valor puede
-- cambiar. Una versión anterior en PetColinas leía el documento (IA, luego OCR)
-- y al probarla con una foto cambió resultados; se eliminó por completo.
--
-- Multiempresa:
--   * cada fila lleva negocio_id y solo la ve su clínica (admin y veterinario,
--     igual que pc_historias);
--   * la clave es (negocio_id, id): el id lo genera el navegador y no debe
--     chocar con el de otra clínica;
--   * en el bucket cada clínica escribe y lee SOLO bajo su carpeta
--     `<negocio_id>/...`; el frontend arma la ruta así.
-- Sin UPDATE ni DELETE a propósito: un resultado guardado no se reescribe.

create table if not exists public.pc_lab_resultados (
  negocio_id     uuid not null references public.negocios(id) on delete cascade,
  id             text not null,
  clienteid      text not null,
  fecha          date,
  tipo           text not null default 'hemograma',
  laboratorio    text,
  datos          jsonb not null default '{}'::jsonb,
  original_path  text,
  original_mime  text,
  pdf_path       text,
  verificado_por text,
  creado         timestamptz not null default now(),
  primary key (negocio_id, id)
);
alter table public.pc_lab_resultados enable row level security;

create index if not exists pc_lab_resultados_cliente_idx
  on public.pc_lab_resultados (negocio_id, clienteid);

revoke all on public.pc_lab_resultados from anon, public;
grant select, insert on public.pc_lab_resultados to authenticated;

drop policy if exists "lab_clinicos_lee" on public.pc_lab_resultados;
create policy "lab_clinicos_lee" on public.pc_lab_resultados
  for select to authenticated
  using (negocio_id = (select mi_negocio())
         and (select tiene_rol(array['admin', 'veterinario'])));

drop policy if exists "lab_clinicos_inserta" on public.pc_lab_resultados;
create policy "lab_clinicos_inserta" on public.pc_lab_resultados
  for insert to authenticated
  with check (negocio_id = (select mi_negocio())
              and (select tiene_rol(array['admin', 'veterinario'])));

-- Bucket privado (enlace firmado de 5 minutos), 10 MB, solo PDF e imágenes.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('laboratorios', 'laboratorios', false, 10485760,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

drop policy if exists "laboratorios_clinica_lee" on storage.objects;
create policy "laboratorios_clinica_lee" on storage.objects
  for select to authenticated
  using (bucket_id = 'laboratorios'
         and (storage.foldername(name))[1] = (select mi_negocio())::text
         and (select tiene_rol(array['admin', 'veterinario'])));

drop policy if exists "laboratorios_clinica_sube" on storage.objects;
create policy "laboratorios_clinica_sube" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'laboratorios'
              and (storage.foldername(name))[1] = (select mi_negocio())::text
              and (select tiene_rol(array['admin', 'veterinario'])));
