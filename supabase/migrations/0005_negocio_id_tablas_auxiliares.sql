-- VetMake · Fase 1: completar la frontera multi-tenant de tablas auxiliares
--
-- Requiere 0001–0004. Estas tablas son necesarias para que la aplicación
-- pueda operar con seguimientos, nómina, tarifas, historias clínicas,
-- fichas, depósitos y auditoría sin depender de tablas de PetColinas.
-- No se copian datos reales.

-- ─── 0. Crear el esquema vacío a partir del contrato observado ───────────
create table if not exists public.pc_seguimientos (
  id          text primary key,
  mascota     text,
  propietario text,
  telefono    text,
  tipo        text,
  frecuencia  numeric,
  ultimafecha text,
  proximafecha text,
  notas       text,
  activo      boolean default true,
  completado  boolean default false,
  created_at  timestamptz default now()
);

create table if not exists public.pc_pagos (
  id            text primary key,
  mes           text,
  empleadoid    text,
  mensualidad   numeric default 0,
  comisiones    numeric default 0,
  descuentos    numeric default 0,
  notas         text,
  created_at    timestamptz default now(),
  totalpagado   numeric,
  empleadonombre text,
  fecha         text
);

create table if not exists public.pc_tarifas (
  id        text primary key,
  nombre    text,
  precio    numeric,
  comision  numeric,
  area      text
);

create table if not exists public.pc_historias (
  id             text primary key,
  clienteid      text,
  fecha          text,
  tipo           text,
  descripcion    text,
  veterinario    text,
  diagnostico    text,
  tratamiento    text,
  medicamentos   text,
  proximacita    text,
  notas          text,
  creadoen       text,
  peso           text,
  temperatura    text,
  motivo         text,
  anamnesis      text,
  examen_fisico  text,
  prescripcion   text,
  vacunas        jsonb default '[]'::jsonb
);

create table if not exists public.pc_fichas_clinicas (
  id        text primary key,
  clienteid text,
  tipo      text,
  datos     jsonb default '{}'::jsonb,
  creadoen  text,
  created_at timestamptz default now()
);

create table if not exists public.pc_depositos (
  id             bigint primary key,
  fecha          text not null,
  mascota        text,
  propietario    text,
  telefono       text,
  tipo           text not null check (tipo in ('deposito', 'uso')),
  monto          numeric default 0,
  facturaid      text,
  facturanumero  text,
  notas          text,
  usuario        text,
  created_at     timestamptz default now()
);

create table if not exists public.pc_auditoria (
  id       bigint primary key,
  fecha    timestamptz default now(),
  usuario  text,
  tabla    text,
  accion   text,
  filaid   text,
  resumen  text,
  monto    numeric default 0
);

-- ─── 1. Añadir la frontera de negocio ────────────────────────────────────
alter table public.pc_seguimientos add column if not exists negocio_id uuid references public.negocios(id);
alter table public.pc_pagos add column if not exists negocio_id uuid references public.negocios(id);
alter table public.pc_tarifas add column if not exists negocio_id uuid references public.negocios(id);
alter table public.pc_historias add column if not exists negocio_id uuid references public.negocios(id);
alter table public.pc_fichas_clinicas add column if not exists negocio_id uuid references public.negocios(id);
alter table public.pc_depositos add column if not exists negocio_id uuid references public.negocios(id);
alter table public.pc_auditoria add column if not exists negocio_id uuid references public.negocios(id);

-- vetmake-dev arranca sin filas en estas tablas. En una futura migración con
-- datos reales se hará primero el backfill y luego se impondrá NOT NULL.
alter table public.pc_seguimientos alter column negocio_id set not null;
alter table public.pc_pagos alter column negocio_id set not null;
alter table public.pc_tarifas alter column negocio_id set not null;
alter table public.pc_historias alter column negocio_id set not null;
alter table public.pc_fichas_clinicas alter column negocio_id set not null;
alter table public.pc_depositos alter column negocio_id set not null;
alter table public.pc_auditoria alter column negocio_id set not null;

create index if not exists pc_seguimientos_negocio_id_idx on public.pc_seguimientos (negocio_id);
create index if not exists pc_pagos_negocio_id_idx on public.pc_pagos (negocio_id);
create index if not exists pc_tarifas_negocio_id_idx on public.pc_tarifas (negocio_id);
create index if not exists pc_historias_negocio_id_idx on public.pc_historias (negocio_id);
create index if not exists pc_fichas_clinicas_negocio_id_idx on public.pc_fichas_clinicas (negocio_id);
create index if not exists pc_depositos_negocio_id_idx on public.pc_depositos (negocio_id);
create index if not exists pc_auditoria_negocio_id_idx on public.pc_auditoria (negocio_id);

-- ─── 2. RLS y Data API: solo usuarios autenticados ───────────────────────
alter table public.pc_seguimientos enable row level security;
alter table public.pc_pagos enable row level security;
alter table public.pc_tarifas enable row level security;
alter table public.pc_historias enable row level security;
alter table public.pc_fichas_clinicas enable row level security;
alter table public.pc_depositos enable row level security;
alter table public.pc_auditoria enable row level security;

grant select, insert, update, delete on table
  public.pc_seguimientos,
  public.pc_pagos,
  public.pc_tarifas,
  public.pc_historias,
  public.pc_fichas_clinicas,
  public.pc_depositos,
  public.pc_auditoria
  to authenticated;

revoke all on table
  public.pc_seguimientos,
  public.pc_pagos,
  public.pc_tarifas,
  public.pc_historias,
  public.pc_fichas_clinicas,
  public.pc_depositos,
  public.pc_auditoria
  from anon;

-- ─── 3. Políticas uniformes por negocio ──────────────────────────────────
drop policy if exists "negocio_lee_sus_seguimientos" on public.pc_seguimientos;
drop policy if exists "negocio_escribe_sus_seguimientos" on public.pc_seguimientos;
drop policy if exists "negocio_actualiza_sus_seguimientos" on public.pc_seguimientos;
drop policy if exists "negocio_borra_sus_seguimientos" on public.pc_seguimientos;
create policy "negocio_lee_sus_seguimientos" on public.pc_seguimientos for select to authenticated using (negocio_id = (select mi_negocio()));
create policy "negocio_escribe_sus_seguimientos" on public.pc_seguimientos for insert to authenticated with check (negocio_id = (select mi_negocio()));
create policy "negocio_actualiza_sus_seguimientos" on public.pc_seguimientos for update to authenticated using (negocio_id = (select mi_negocio())) with check (negocio_id = (select mi_negocio()));
create policy "negocio_borra_sus_seguimientos" on public.pc_seguimientos for delete to authenticated using (negocio_id = (select mi_negocio()));

drop policy if exists "negocio_lee_sus_pagos" on public.pc_pagos;
drop policy if exists "negocio_escribe_sus_pagos" on public.pc_pagos;
drop policy if exists "negocio_actualiza_sus_pagos" on public.pc_pagos;
drop policy if exists "negocio_borra_sus_pagos" on public.pc_pagos;
create policy "negocio_lee_sus_pagos" on public.pc_pagos for select to authenticated using (negocio_id = (select mi_negocio()));
create policy "negocio_escribe_sus_pagos" on public.pc_pagos for insert to authenticated with check (negocio_id = (select mi_negocio()));
create policy "negocio_actualiza_sus_pagos" on public.pc_pagos for update to authenticated using (negocio_id = (select mi_negocio())) with check (negocio_id = (select mi_negocio()));
create policy "negocio_borra_sus_pagos" on public.pc_pagos for delete to authenticated using (negocio_id = (select mi_negocio()));

drop policy if exists "negocio_lee_sus_tarifas" on public.pc_tarifas;
drop policy if exists "negocio_escribe_sus_tarifas" on public.pc_tarifas;
drop policy if exists "negocio_actualiza_sus_tarifas" on public.pc_tarifas;
drop policy if exists "negocio_borra_sus_tarifas" on public.pc_tarifas;
create policy "negocio_lee_sus_tarifas" on public.pc_tarifas for select to authenticated using (negocio_id = (select mi_negocio()));
create policy "negocio_escribe_sus_tarifas" on public.pc_tarifas for insert to authenticated with check (negocio_id = (select mi_negocio()));
create policy "negocio_actualiza_sus_tarifas" on public.pc_tarifas for update to authenticated using (negocio_id = (select mi_negocio())) with check (negocio_id = (select mi_negocio()));
create policy "negocio_borra_sus_tarifas" on public.pc_tarifas for delete to authenticated using (negocio_id = (select mi_negocio()));

drop policy if exists "negocio_lee_sus_historias" on public.pc_historias;
drop policy if exists "negocio_escribe_sus_historias" on public.pc_historias;
drop policy if exists "negocio_actualiza_sus_historias" on public.pc_historias;
drop policy if exists "negocio_borra_sus_historias" on public.pc_historias;
create policy "negocio_lee_sus_historias" on public.pc_historias for select to authenticated using (negocio_id = (select mi_negocio()));
create policy "negocio_escribe_sus_historias" on public.pc_historias for insert to authenticated with check (negocio_id = (select mi_negocio()));
create policy "negocio_actualiza_sus_historias" on public.pc_historias for update to authenticated using (negocio_id = (select mi_negocio())) with check (negocio_id = (select mi_negocio()));
create policy "negocio_borra_sus_historias" on public.pc_historias for delete to authenticated using (negocio_id = (select mi_negocio()));

drop policy if exists "negocio_lee_sus_fichas_clinicas" on public.pc_fichas_clinicas;
drop policy if exists "negocio_escribe_sus_fichas_clinicas" on public.pc_fichas_clinicas;
drop policy if exists "negocio_actualiza_sus_fichas_clinicas" on public.pc_fichas_clinicas;
drop policy if exists "negocio_borra_sus_fichas_clinicas" on public.pc_fichas_clinicas;
create policy "negocio_lee_sus_fichas_clinicas" on public.pc_fichas_clinicas for select to authenticated using (negocio_id = (select mi_negocio()));
create policy "negocio_escribe_sus_fichas_clinicas" on public.pc_fichas_clinicas for insert to authenticated with check (negocio_id = (select mi_negocio()));
create policy "negocio_actualiza_sus_fichas_clinicas" on public.pc_fichas_clinicas for update to authenticated using (negocio_id = (select mi_negocio())) with check (negocio_id = (select mi_negocio()));
create policy "negocio_borra_sus_fichas_clinicas" on public.pc_fichas_clinicas for delete to authenticated using (negocio_id = (select mi_negocio()));

drop policy if exists "negocio_lee_sus_depositos" on public.pc_depositos;
drop policy if exists "negocio_escribe_sus_depositos" on public.pc_depositos;
drop policy if exists "negocio_actualiza_sus_depositos" on public.pc_depositos;
drop policy if exists "negocio_borra_sus_depositos" on public.pc_depositos;
create policy "negocio_lee_sus_depositos" on public.pc_depositos for select to authenticated using (negocio_id = (select mi_negocio()));
create policy "negocio_escribe_sus_depositos" on public.pc_depositos for insert to authenticated with check (negocio_id = (select mi_negocio()));
create policy "negocio_actualiza_sus_depositos" on public.pc_depositos for update to authenticated using (negocio_id = (select mi_negocio())) with check (negocio_id = (select mi_negocio()));
create policy "negocio_borra_sus_depositos" on public.pc_depositos for delete to authenticated using (negocio_id = (select mi_negocio()));

drop policy if exists "negocio_lee_su_auditoria" on public.pc_auditoria;
drop policy if exists "negocio_escribe_su_auditoria" on public.pc_auditoria;
drop policy if exists "negocio_actualiza_su_auditoria" on public.pc_auditoria;
drop policy if exists "negocio_borra_su_auditoria" on public.pc_auditoria;
create policy "negocio_lee_su_auditoria" on public.pc_auditoria for select to authenticated using (negocio_id = (select mi_negocio()));
create policy "negocio_escribe_su_auditoria" on public.pc_auditoria for insert to authenticated with check (negocio_id = (select mi_negocio()));
create policy "negocio_actualiza_su_auditoria" on public.pc_auditoria for update to authenticated using (negocio_id = (select mi_negocio())) with check (negocio_id = (select mi_negocio()));
create policy "negocio_borra_su_auditoria" on public.pc_auditoria for delete to authenticated using (negocio_id = (select mi_negocio()));
