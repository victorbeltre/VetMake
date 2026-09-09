alter table public.negocios
  add column if not exists formulario_token uuid not null default gen_random_uuid(),
  add column if not exists formulario_activo boolean not null default true;

create unique index if not exists negocios_formulario_token_uidx
  on public.negocios (formulario_token);

comment on column public.negocios.formulario_token is
  'Token no predecible usado por el enlace público de admisión de clientes.';
comment on column public.negocios.formulario_activo is
  'Permite al negocio pausar su formulario público sin borrar el enlace.';
