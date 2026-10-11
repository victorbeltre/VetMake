-- VetMake · Fase 1: planes prepagados
--
-- El frontend usa esta tabla para vender y consumir planes de baños.
-- No se copian datos reales de PetColinas.

create table if not exists public.pc_paquetes (
  id          text primary key,
  mascota     text,
  clienteid   text,
  nombre      text,
  banostotal  numeric default 0,
  banosusados numeric default 0,
  precio      numeric default 0,
  fecha       text,
  vence       text,
  estado      text default 'activo',
  notas       text,
  created_at  timestamptz default now()
);

alter table public.pc_paquetes
  add column if not exists negocio_id uuid references public.negocios(id);
alter table public.pc_paquetes alter column negocio_id set not null;

create index if not exists pc_paquetes_negocio_id_idx
  on public.pc_paquetes (negocio_id);

alter table public.pc_paquetes enable row level security;

grant select, insert, update, delete on table public.pc_paquetes to authenticated;
revoke all on table public.pc_paquetes from anon;

drop policy if exists "negocio_lee_sus_paquetes" on public.pc_paquetes;
drop policy if exists "negocio_escribe_sus_paquetes" on public.pc_paquetes;
drop policy if exists "negocio_actualiza_sus_paquetes" on public.pc_paquetes;
drop policy if exists "negocio_borra_sus_paquetes" on public.pc_paquetes;

create policy "negocio_lee_sus_paquetes"
  on public.pc_paquetes for select to authenticated
  using (negocio_id = (select mi_negocio()));
create policy "negocio_escribe_sus_paquetes"
  on public.pc_paquetes for insert to authenticated
  with check (negocio_id = (select mi_negocio()));
create policy "negocio_actualiza_sus_paquetes"
  on public.pc_paquetes for update to authenticated
  using (negocio_id = (select mi_negocio()))
  with check (negocio_id = (select mi_negocio()));
create policy "negocio_borra_sus_paquetes"
  on public.pc_paquetes for delete to authenticated
  using (negocio_id = (select mi_negocio()));
