-- VetMake · Membresías de las clínicas (planes, pagos y modo solo lectura)
--
-- Decisiones de Victor (29 oct 2026):
--   · Tres planes por clínica, no por usuario: Esencial RD$1,990, Clínica
--     RD$3,490 y Clínica Plus RD$5,990 al mes; el anual cuesta 10 meses.
--   · Al principio se cobra por TRANSFERENCIA: la clínica paga, Victor anota el
--     pago en el panel de la plataforma y el sistema mueve el vencimiento.
--   · Al vencer hay 7 días de gracia; después la clínica queda en SOLO LECTURA:
--     ve y exporta sus datos, pero no registra nada nuevo hasta pagar.
--   · «Varias sucursales» de Clínica Plus se vende como «próximamente».
--
-- Dónde se hace cumplir:
--   · Solo lectura: un trigger BEFORE en cada tabla con negocio_id. Los
--     triggers corren aunque la escritura venga de una RPC SECURITY DEFINER, así
--     que no hay que tocar cada función. Solo se bloquea cuando la petición viene
--     de la app (rol authenticated o anon); service_role y el propio Postgres
--     (migraciones, respaldos del equipo) siguen pudiendo escribir.
--   · Límite de usuarios: trigger en usuarios_negocio; aplica a todos los roles,
--     también al onboarding de la Edge Function vetmake-admin.
--   · Las tablas vetmake_* no tienen acceso directo desde la app: todo pasa por
--     RPC. Una clínica no puede alargarse el vencimiento.

-- ─── 1. Tablas ────────────────────────────────────────────────────────────────
create table if not exists public.vetmake_planes (
  codigo          text primary key check (codigo ~ '^[a-z_]+$'),
  nombre          text not null,
  precio_mensual  numeric(12,2) not null check (precio_mensual >= 0),
  precio_anual    numeric(12,2) not null check (precio_anual >= 0),
  max_usuarios    integer check (max_usuarios is null or max_usuarios > 0),
  incluye         jsonb not null default '[]'::jsonb,
  orden           integer not null default 0,
  activo          boolean not null default true
);
comment on table public.vetmake_planes is
  'Catálogo de planes de VetMake. max_usuarios null = ilimitado. Lo edita el equipo de VetMake.';

insert into public.vetmake_planes (codigo, nombre, precio_mensual, precio_anual, max_usuarios, incluye, orden) values
  ('esencial', 'Esencial', 1990, 19900, 2,
   '["2 usuarios", "Agenda y CRM", "Historia clínica", "Seguimientos por WhatsApp", "Facturas con NCF"]'::jsonb, 1),
  ('clinica', 'Clínica', 3490, 34900, 6,
   '["6 usuarios", "Todo lo de Esencial", "Caja e inventario", "Reportes 607 y 608", "Nómina con comisiones y gastos", "Planes de salud", "Importar desde Excel"]'::jsonb, 2),
  ('clinica_plus', 'Clínica Plus', 5990, 59900, null,
   '["Usuarios ilimitados", "Todo lo de Clínica", "Inteligencia VetMake", "Soporte prioritario", "Google Calendar", "Varias sucursales (próximamente)"]'::jsonb, 3)
on conflict (codigo) do nothing;

create table if not exists public.vetmake_suscripciones (
  negocio_id       uuid primary key references public.negocios(id) on delete cascade,
  plan             text not null references public.vetmake_planes(codigo),
  ciclo            text not null default 'mensual' check (ciclo in ('mensual', 'anual')),
  estado           text not null default 'prueba' check (estado in ('prueba', 'activa', 'cortesia', 'cancelada')),
  vence_el         date not null,
  dias_gracia      integer not null default 7 check (dias_gracia between 0 and 60),
  precio_acordado  numeric(12,2) check (precio_acordado is null or precio_acordado >= 0),
  nota             text,
  creado_en        timestamptz not null default now(),
  actualizado_en   timestamptz not null default now()
);
comment on table public.vetmake_suscripciones is
  'Una fila por clínica. vence_el = último día pagado. estado guarda la decisión '
  '(prueba, activa, cortesia, cancelada); la situación del día (por vencer, en '
  'gracia, solo lectura) se calcula en private.membresia_estado.';
comment on column public.vetmake_suscripciones.precio_acordado is
  'Precio por ciclo pactado con la clínica (oferta de fundadores). Null = precio de lista.';

create table if not exists public.vetmake_pagos (
  id              uuid primary key default gen_random_uuid(),
  negocio_id      uuid not null references public.negocios(id) on delete cascade,
  monto           numeric(12,2) not null check (monto > 0),
  fecha_pago      date not null,
  metodo          text not null default 'transferencia'
                  check (metodo in ('transferencia', 'efectivo', 'tarjeta', 'otro')),
  referencia      text,
  plan            text not null references public.vetmake_planes(codigo),
  ciclo           text not null check (ciclo in ('mensual', 'anual')),
  meses           integer not null check (meses between 1 and 24),
  vence_antes     date not null,
  vence_despues   date not null,
  plan_antes      text not null,
  ciclo_antes     text not null,
  estado_antes    text not null,
  registrado_por  uuid references auth.users(id) on delete set null,
  anulado         boolean not null default false,
  anulado_en      timestamptz,
  -- clock_timestamp: dos pagos en la misma transacción quedan ordenados.
  creado_en       timestamptz not null default clock_timestamp()
);
create index if not exists vetmake_pagos_negocio_idx on public.vetmake_pagos (negocio_id, creado_en desc);

create table if not exists public.vetmake_superadmins (
  usuario_id  uuid primary key references auth.users(id) on delete cascade,
  creado_en   timestamptz not null default now()
);
comment on table public.vetmake_superadmins is
  'Personas del equipo de VetMake que registran pagos y cambian planes. Alta solo con service_role o migración.';

create table if not exists public.vetmake_plataforma_config (
  id              boolean primary key default true check (id),
  datos_pago      text not null default 'Escríbenos por WhatsApp y te enviamos los datos de la cuenta para transferir.',
  whatsapp        text not null default '18297446060',
  actualizado_en  timestamptz not null default now()
);
insert into public.vetmake_plataforma_config (id) values (true) on conflict (id) do nothing;

alter table public.vetmake_planes enable row level security;
alter table public.vetmake_suscripciones enable row level security;
alter table public.vetmake_pagos enable row level security;
alter table public.vetmake_superadmins enable row level security;
alter table public.vetmake_plataforma_config enable row level security;

revoke all on public.vetmake_planes, public.vetmake_suscripciones, public.vetmake_pagos,
  public.vetmake_superadmins, public.vetmake_plataforma_config from public, anon, authenticated;

-- El catálogo es público dentro de la app (se compara en «Mi plan»).
grant select on public.vetmake_planes to authenticated;
drop policy if exists vetmake_planes_lectura on public.vetmake_planes;
create policy vetmake_planes_lectura on public.vetmake_planes
  for select to authenticated using (activo = true);
-- Las demás tablas no tienen políticas para authenticated: solo RPC.

-- ─── 2. Funciones base ───────────────────────────────────────────────────────
create or replace function private.hoy_rd()
returns date language sql stable set search_path = '' as $$
  select (now() at time zone 'America/Santo_Domingo')::date;
$$;

-- Situación de la membresía HOY. Una clínica sin fila (no debería pasar) se
-- deja escribir: un error de datos no debe tumbar una clínica que paga.
create or replace function private.membresia_estado(
  p_negocio uuid,
  out estado text, out vence_el date, out dias integer, out puede_escribir boolean)
language plpgsql stable security definer set search_path = '' as $$
declare s public.vetmake_suscripciones;
begin
  select * into s from public.vetmake_suscripciones where negocio_id = p_negocio;
  if not found then
    estado := 'sin_plan'; puede_escribir := true; return;
  end if;
  vence_el := s.vence_el;
  dias := s.vence_el - private.hoy_rd();
  if s.estado = 'cortesia' then
    estado := 'cortesia'; dias := null; puede_escribir := true;
  elsif s.estado = 'cancelada' then
    estado := 'cancelada'; puede_escribir := false;
  elsif dias >= 0 then
    estado := case when s.estado = 'prueba' then 'prueba' when dias <= 7 then 'por_vencer' else 'activa' end;
    puede_escribir := true;
  elsif -dias <= s.dias_gracia then
    estado := 'en_gracia'; puede_escribir := true;
  else
    estado := 'solo_lectura'; puede_escribir := false;
  end if;
end $$;

create or replace function private.es_superadmin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.vetmake_superadmins a where a.usuario_id = (select auth.uid()));
$$;
revoke all on function private.hoy_rd() from public, anon, authenticated;
revoke all on function private.membresia_estado(uuid) from public, anon, authenticated;
revoke all on function private.es_superadmin() from public, anon, authenticated;
grant execute on function private.hoy_rd() to authenticated, service_role;

-- ─── 3. Modo solo lectura ────────────────────────────────────────────────────
create or replace function private.exigir_membresia_vigente()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_rol text := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '');
  v_negocio uuid;
  v_estado record;
begin
  if v_rol in ('authenticated', 'anon') then
    v_negocio := case when tg_op = 'DELETE' then old.negocio_id else new.negocio_id end;
    if v_negocio is not null then
      select * into v_estado from private.membresia_estado(v_negocio);
      if not v_estado.puede_escribir then
        raise exception using
          errcode = 'P0001',
          message = case when v_estado.estado = 'cancelada'
            then 'La membresía de VetMake de esta clínica está cancelada: solo se pueden consultar y exportar los datos.'
            else 'La membresía de VetMake está vencida: la clínica está en modo solo lectura. Registra el pago para seguir trabajando.' end,
          hint = 'vetmake_membresia_vencida';
      end if;
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
revoke all on function private.exigir_membresia_vigente() from public, anon, authenticated;

-- Todas las tablas de datos de la clínica, menos la auditoría (la escribe un
-- trigger después del cambio), las membresías de usuarios (el admin debe poder
-- quitar accesos para bajar de plan) y el aprendizaje compartido.
do $$
declare t text;
begin
  for t in
    select c.table_name
      from information_schema.columns c
      join information_schema.tables tb
        on tb.table_schema = c.table_schema and tb.table_name = c.table_name and tb.table_type = 'BASE TABLE'
     where c.table_schema = 'public' and c.column_name = 'negocio_id'
       and c.table_name not in ('pc_auditoria', 'usuarios_negocio', 'vet_learning_aliases')
       and c.table_name not like 'vetmake\_%'
  loop
    execute format('drop trigger if exists vetmake_membresia_vigente on public.%I', t);
    execute format(
      'create trigger vetmake_membresia_vigente before insert or update or delete on public.%I '
      'for each row execute function private.exigir_membresia_vigente()', t);
  end loop;
end $$;

-- ─── 4. Límite de usuarios por plan ──────────────────────────────────────────
create or replace function private.limitar_usuarios_plan()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_max integer; v_plan text; v_usados integer;
begin
  if not new.activo then return new; end if;
  if tg_op = 'UPDATE' and old.activo and old.negocio_id = new.negocio_id then return new; end if;
  select p.max_usuarios, p.nombre into v_max, v_plan
    from public.vetmake_suscripciones s join public.vetmake_planes p on p.codigo = s.plan
   where s.negocio_id = new.negocio_id;
  if v_max is null then return new; end if;
  -- Serializa altas simultáneas de la misma clínica.
  perform 1 from public.negocios where id = new.negocio_id for update;
  select count(*) into v_usados from public.usuarios_negocio m
   where m.negocio_id = new.negocio_id and m.activo and m.usuario_id <> new.usuario_id;
  if v_usados >= v_max then
    raise exception using
      errcode = 'P0001',
      message = format('El plan %s permite %s usuarios y la clínica ya tiene %s. Quita un acceso o cambia de plan.', v_plan, v_max, v_usados),
      hint = 'vetmake_limite_usuarios';
  end if;
  return new;
end $$;
revoke all on function private.limitar_usuarios_plan() from public, anon, authenticated;

drop trigger if exists vetmake_limite_usuarios on public.usuarios_negocio;
create trigger vetmake_limite_usuarios before insert or update of activo, negocio_id on public.usuarios_negocio
  for each row execute function private.limitar_usuarios_plan();

-- ─── 5. Prueba de 14 días para cada clínica nueva ────────────────────────────
-- El nombre empieza por «vetmake_a» para correr antes de vetmake_cuentas_base.
create or replace function private.membresia_negocio_nuevo()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.vetmake_suscripciones (negocio_id, plan, ciclo, estado, vence_el, nota)
  values (new.id, 'clinica', 'mensual', 'prueba', private.hoy_rd() + 14, 'Prueba gratis de 14 días')
  on conflict (negocio_id) do nothing;
  return new;
end $$;
revoke all on function private.membresia_negocio_nuevo() from public, anon, authenticated;

drop trigger if exists vetmake_a_membresia_inicial on public.negocios;
create trigger vetmake_a_membresia_inicial after insert on public.negocios
  for each row execute function private.membresia_negocio_nuevo();

-- Las clínicas que ya existían (pruebas y demo) quedan de cortesía, sin límite.
insert into public.vetmake_suscripciones (negocio_id, plan, ciclo, estado, vence_el, nota)
select n.id, 'clinica_plus', 'mensual', 'cortesia', private.hoy_rd(), 'Clínica existente antes de las membresías'
  from public.negocios n
on conflict (negocio_id) do nothing;

-- Victor administra la plataforma con su cuenta sin clínica.
insert into public.vetmake_superadmins (usuario_id)
select u.id from auth.users u where lower(u.email) = 'petcolinasrd@gmail.com'
on conflict (usuario_id) do nothing;

-- ─── 6. Resumen de una membresía ─────────────────────────────────────────────
create or replace function private.membresia_resumen(p_negocio uuid, p_con_pagos boolean)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  s public.vetmake_suscripciones;
  p public.vetmake_planes;
  e record;
  v_usados integer;
  v_pagos jsonb := '[]'::jsonb;
begin
  select * into s from public.vetmake_suscripciones where negocio_id = p_negocio;
  if not found then
    return jsonb_build_object('estado_actual', 'sin_plan', 'puede_escribir', true);
  end if;
  select * into p from public.vetmake_planes where codigo = s.plan;
  select * into e from private.membresia_estado(p_negocio);
  select count(*) into v_usados from public.usuarios_negocio m where m.negocio_id = p_negocio and m.activo;
  if p_con_pagos then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.creado_en desc), '[]'::jsonb) into v_pagos
      from (select g.id, g.monto, g.fecha_pago, g.metodo, g.referencia, g.plan, g.ciclo, g.meses,
                   g.vence_antes, g.vence_despues, g.anulado, g.creado_en
              from public.vetmake_pagos g where g.negocio_id = p_negocio
             order by g.creado_en desc limit 24) x;
  end if;
  return jsonb_build_object(
    'negocio_id', p_negocio,
    'plan', s.plan,
    'plan_nombre', p.nombre,
    'ciclo', s.ciclo,
    'estado', s.estado,
    'estado_actual', e.estado,
    'vence_el', s.vence_el,
    'dias_restantes', e.dias,
    'dias_gracia', s.dias_gracia,
    'puede_escribir', e.puede_escribir,
    'precio', coalesce(s.precio_acordado, case when s.ciclo = 'anual' then p.precio_anual else p.precio_mensual end),
    'precio_acordado', s.precio_acordado,
    'precio_lista_mensual', p.precio_mensual,
    'precio_lista_anual', p.precio_anual,
    'max_usuarios', p.max_usuarios,
    'usuarios_activos', v_usados,
    'incluye', p.incluye,
    'nota', s.nota,
    'pagos', v_pagos
  );
end $$;
revoke all on function private.membresia_resumen(uuid, boolean) from public, anon, authenticated;

-- ─── 7. RPC para la clínica ──────────────────────────────────────────────────
create or replace function private.mi_membresia_impl()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_usuario uuid := (select auth.uid());
  v_negocio uuid; v_rol text;
  c public.vetmake_plataforma_config;
begin
  if v_usuario is null then
    raise exception using errcode = '42501', message = 'Se requiere una sesión autenticada.';
  end if;
  select m.negocio_id, m.rol into v_negocio, v_rol
    from public.usuarios_negocio m where m.usuario_id = v_usuario and m.activo;
  if v_negocio is null then
    raise exception using errcode = '42501', message = 'No autorizado.';
  end if;
  select * into c from public.vetmake_plataforma_config where id;
  return private.membresia_resumen(v_negocio, v_rol = 'admin')
    || jsonb_build_object(
         'es_admin', v_rol = 'admin',
         'datos_pago', c.datos_pago,
         'whatsapp', c.whatsapp,
         'planes', (select coalesce(jsonb_agg(to_jsonb(p) order by p.orden), '[]'::jsonb)
                      from public.vetmake_planes p where p.activo));
end $$;
revoke all on function private.mi_membresia_impl() from public, anon, authenticated;
grant execute on function private.mi_membresia_impl() to authenticated;

create or replace function public.mi_membresia()
returns jsonb language sql stable set search_path = '' as $$ select private.mi_membresia_impl(); $$;
revoke all on function public.mi_membresia() from public, anon;
grant execute on function public.mi_membresia() to authenticated;

-- ─── 8. RPC de la plataforma (solo superadmins) ──────────────────────────────
create or replace function private.exigir_superadmin()
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.es_superadmin() then
    raise exception using errcode = '42501', message = 'Solo el equipo de VetMake puede hacer esto.';
  end if;
end $$;
revoke all on function private.exigir_superadmin() from public, anon, authenticated;

create or replace function private.plataforma_soy_admin_impl()
returns boolean language sql stable security definer set search_path = '' as $$
  select private.es_superadmin();
$$;
revoke all on function private.plataforma_soy_admin_impl() from public, anon, authenticated;
grant execute on function private.plataforma_soy_admin_impl() to authenticated;

create or replace function private.plataforma_resumen_impl()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_clinicas jsonb; c public.vetmake_plataforma_config;
begin
  perform private.exigir_superadmin();
  select coalesce(jsonb_agg(
           private.membresia_resumen(n.id, true) || jsonb_build_object(
             'nombre', n.nombre,
             'creado_en', n.creado_en,
             'activo', n.activo,
             'telefono', to_jsonb(n) ->> 'telefono',
             'whatsapp_clinica', to_jsonb(n) ->> 'whatsapp',
             'email', coalesce(to_jsonb(n) ->> 'email',
                        (select u.email from public.usuarios_negocio m join auth.users u on u.id = m.usuario_id
                          where m.negocio_id = n.id and m.rol = 'admin' and m.activo limit 1)))
           order by n.nombre), '[]'::jsonb)
    into v_clinicas
    from public.negocios n;
  select * into c from public.vetmake_plataforma_config where id;
  return jsonb_build_object(
    'clinicas', v_clinicas,
    'planes', (select coalesce(jsonb_agg(to_jsonb(p) order by p.orden), '[]'::jsonb) from public.vetmake_planes p),
    'config', jsonb_build_object('datos_pago', c.datos_pago, 'whatsapp', c.whatsapp),
    'hoy', private.hoy_rd()
  );
end $$;
revoke all on function private.plataforma_resumen_impl() from public, anon, authenticated;
grant execute on function private.plataforma_resumen_impl() to authenticated;

-- Registrar un pago mueve el vencimiento. Desde dónde se cuenta:
--   · activa o en gracia: desde el vencimiento (los días de gracia se deben);
--   · en prueba: desde el fin de la prueba o desde hoy, lo que sea mayor;
--   · cortesía, cancelada o ya en solo lectura: desde hoy.
create or replace function private.plataforma_registrar_pago_impl(
  p_negocio uuid, p_monto numeric, p_fecha date, p_metodo text, p_referencia text,
  p_meses integer, p_plan text, p_ciclo text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  s public.vetmake_suscripciones;
  v_hoy date := private.hoy_rd();
  v_plan text; v_ciclo text; v_meses integer; v_base date; v_nuevo date;
  v_max integer; v_usados integer;
begin
  perform private.exigir_superadmin();
  select * into s from public.vetmake_suscripciones where negocio_id = p_negocio for update;
  if not found then
    raise exception using errcode = '22023', message = 'Esa clínica no tiene membresía.';
  end if;
  if coalesce(p_monto, 0) <= 0 then
    raise exception using errcode = '22023', message = 'El monto debe ser mayor que cero.';
  end if;
  v_plan := coalesce(nullif(btrim(p_plan), ''), s.plan);
  v_ciclo := coalesce(nullif(btrim(p_ciclo), ''), s.ciclo);
  if v_ciclo not in ('mensual', 'anual') then
    raise exception using errcode = '22023', message = 'El ciclo debe ser mensual o anual.';
  end if;
  select max_usuarios into v_max from public.vetmake_planes where codigo = v_plan and activo;
  if not found then
    raise exception using errcode = '22023', message = 'Ese plan no existe.';
  end if;
  select count(*) into v_usados from public.usuarios_negocio m where m.negocio_id = p_negocio and m.activo;
  if v_max is not null and v_usados > v_max then
    raise exception using errcode = '22023',
      message = format('La clínica tiene %s usuarios activos y ese plan permite %s. Que quite accesos antes de bajar de plan.', v_usados, v_max);
  end if;
  v_meses := coalesce(p_meses, case when v_ciclo = 'anual' then 12 else 1 end);
  if v_meses not between 1 and 24 then
    raise exception using errcode = '22023', message = 'Los meses pagados deben estar entre 1 y 24.';
  end if;

  if s.estado in ('cortesia', 'cancelada') or s.vence_el < v_hoy - s.dias_gracia then
    v_base := v_hoy - 1;
  elsif s.estado = 'prueba' then
    v_base := greatest(s.vence_el, v_hoy - 1);
  else
    v_base := s.vence_el;
  end if;
  v_nuevo := (v_base + make_interval(months => v_meses))::date;

  insert into public.vetmake_pagos (negocio_id, monto, fecha_pago, metodo, referencia, plan, ciclo, meses,
                                    vence_antes, vence_despues, plan_antes, ciclo_antes, estado_antes, registrado_por)
  values (p_negocio, p_monto, coalesce(p_fecha, v_hoy), coalesce(nullif(btrim(p_metodo), ''), 'transferencia'),
          nullif(btrim(p_referencia), ''), v_plan, v_ciclo, v_meses, s.vence_el, v_nuevo,
          s.plan, s.ciclo, s.estado, (select auth.uid()));

  update public.vetmake_suscripciones
     set estado = 'activa', plan = v_plan, ciclo = v_ciclo, vence_el = v_nuevo, actualizado_en = now()
   where negocio_id = p_negocio;
  update public.negocios set plan = v_plan where id = p_negocio;

  return private.membresia_resumen(p_negocio, true);
end $$;
revoke all on function private.plataforma_registrar_pago_impl(uuid, numeric, date, text, text, integer, text, text) from public, anon, authenticated;
grant execute on function private.plataforma_registrar_pago_impl(uuid, numeric, date, text, text, integer, text, text) to authenticated;

-- Anular devuelve vencimiento, plan, ciclo y estado a como estaban. Solo el último pago vigente,
-- para no dejar huecos en la cadena de vencimientos.
create or replace function private.plataforma_anular_pago_impl(p_pago uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare g public.vetmake_pagos; v_ultimo uuid;
begin
  perform private.exigir_superadmin();
  select * into g from public.vetmake_pagos where id = p_pago for update;
  if not found or g.anulado then
    raise exception using errcode = '22023', message = 'Ese pago no existe o ya está anulado.';
  end if;
  perform 1 from public.vetmake_suscripciones where negocio_id = g.negocio_id for update;
  select id into v_ultimo from public.vetmake_pagos
   where negocio_id = g.negocio_id and not anulado order by creado_en desc, id limit 1;
  if v_ultimo <> g.id then
    raise exception using errcode = '22023', message = 'Solo se puede anular el último pago. Anula primero los posteriores.';
  end if;
  update public.vetmake_pagos set anulado = true, anulado_en = now() where id = g.id;
  update public.vetmake_suscripciones
     set vence_el = g.vence_antes, plan = g.plan_antes, ciclo = g.ciclo_antes, estado = g.estado_antes,
         actualizado_en = now()
   where negocio_id = g.negocio_id;
  update public.negocios set plan = g.plan_antes where id = g.negocio_id;
  return private.membresia_resumen(g.negocio_id, true);
end $$;
revoke all on function private.plataforma_anular_pago_impl(uuid) from public, anon, authenticated;
grant execute on function private.plataforma_anular_pago_impl(uuid) to authenticated;

-- Cambios a mano: plan, ciclo, estado (prueba, cortesía, cancelar), fecha,
-- gracia y precio de fundador. Cada parámetro null deja el valor como está.
create or replace function private.plataforma_guardar_membresia_impl(
  p_negocio uuid, p_plan text, p_ciclo text, p_estado text, p_vence_el date,
  p_dias_gracia integer, p_precio_acordado numeric, p_quitar_precio boolean, p_nota text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.vetmake_suscripciones; v_max integer; v_usados integer;
begin
  perform private.exigir_superadmin();
  select * into s from public.vetmake_suscripciones where negocio_id = p_negocio for update;
  if not found then
    raise exception using errcode = '22023', message = 'Esa clínica no tiene membresía.';
  end if;
  if p_plan is not null then
    select max_usuarios into v_max from public.vetmake_planes where codigo = p_plan and activo;
    if not found then
      raise exception using errcode = '22023', message = 'Ese plan no existe.';
    end if;
    select count(*) into v_usados from public.usuarios_negocio m where m.negocio_id = p_negocio and m.activo;
    if v_max is not null and v_usados > v_max then
      raise exception using errcode = '22023',
        message = format('La clínica tiene %s usuarios activos y ese plan permite %s. Que quite accesos antes de bajar de plan.', v_usados, v_max);
    end if;
  end if;
  update public.vetmake_suscripciones set
    plan = coalesce(p_plan, plan),
    ciclo = coalesce(p_ciclo, ciclo),
    estado = coalesce(p_estado, estado),
    vence_el = coalesce(p_vence_el, vence_el),
    dias_gracia = coalesce(p_dias_gracia, dias_gracia),
    precio_acordado = case when coalesce(p_quitar_precio, false) then null else coalesce(p_precio_acordado, precio_acordado) end,
    nota = coalesce(p_nota, nota),
    actualizado_en = now()
  where negocio_id = p_negocio;
  if p_plan is not null then
    update public.negocios set plan = p_plan where id = p_negocio;
  end if;
  return private.membresia_resumen(p_negocio, true);
end $$;
revoke all on function private.plataforma_guardar_membresia_impl(uuid, text, text, text, date, integer, numeric, boolean, text) from public, anon, authenticated;
grant execute on function private.plataforma_guardar_membresia_impl(uuid, text, text, text, date, integer, numeric, boolean, text) to authenticated;

create or replace function private.plataforma_guardar_config_impl(p_datos_pago text, p_whatsapp text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_wa text := regexp_replace(coalesce(p_whatsapp, ''), '\D', '', 'g');
begin
  perform private.exigir_superadmin();
  if nullif(btrim(p_datos_pago), '') is null then
    raise exception using errcode = '22023', message = 'Escribe los datos para transferir.';
  end if;
  if length(v_wa) < 10 then
    raise exception using errcode = '22023', message = 'El WhatsApp debe tener al menos 10 dígitos.';
  end if;
  update public.vetmake_plataforma_config
     set datos_pago = btrim(p_datos_pago), whatsapp = v_wa, actualizado_en = now()
   where id;
  return jsonb_build_object('datos_pago', btrim(p_datos_pago), 'whatsapp', v_wa);
end $$;
revoke all on function private.plataforma_guardar_config_impl(text, text) from public, anon, authenticated;
grant execute on function private.plataforma_guardar_config_impl(text, text) to authenticated;

-- Para la Edge Function vetmake-admin: comprobar el cupo ANTES de invitar.
create or replace function private.membresia_cupo(p_negocio uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'max_usuarios', p.max_usuarios,
    'usuarios_activos', (select count(*) from public.usuarios_negocio m where m.negocio_id = p_negocio and m.activo),
    'plan_nombre', p.nombre,
    'puede_escribir', (select e.puede_escribir from private.membresia_estado(p_negocio) e))
  from public.vetmake_suscripciones s join public.vetmake_planes p on p.codigo = s.plan
  where s.negocio_id = p_negocio;
$$;
revoke all on function private.membresia_cupo(uuid) from public, anon, authenticated;

-- Envolturas públicas (SECURITY INVOKER) — el patrón del resto de VetMake.
create or replace function public.plataforma_soy_admin()
returns boolean language sql stable set search_path = '' as $$ select private.plataforma_soy_admin_impl(); $$;
create or replace function public.plataforma_resumen()
returns jsonb language sql stable set search_path = '' as $$ select private.plataforma_resumen_impl(); $$;
create or replace function public.plataforma_registrar_pago(
  p_negocio uuid, p_monto numeric, p_fecha date default null, p_metodo text default 'transferencia',
  p_referencia text default null, p_meses integer default null, p_plan text default null, p_ciclo text default null)
returns jsonb language sql set search_path = '' as $$
  select private.plataforma_registrar_pago_impl(p_negocio, p_monto, p_fecha, p_metodo, p_referencia, p_meses, p_plan, p_ciclo);
$$;
create or replace function public.plataforma_anular_pago(p_pago uuid)
returns jsonb language sql set search_path = '' as $$ select private.plataforma_anular_pago_impl(p_pago); $$;
create or replace function public.plataforma_guardar_membresia(
  p_negocio uuid, p_plan text default null, p_ciclo text default null, p_estado text default null,
  p_vence_el date default null, p_dias_gracia integer default null, p_precio_acordado numeric default null,
  p_quitar_precio boolean default false, p_nota text default null)
returns jsonb language sql set search_path = '' as $$
  select private.plataforma_guardar_membresia_impl(p_negocio, p_plan, p_ciclo, p_estado, p_vence_el,
                                                    p_dias_gracia, p_precio_acordado, p_quitar_precio, p_nota);
$$;
create or replace function public.plataforma_guardar_config(p_datos_pago text, p_whatsapp text)
returns jsonb language sql set search_path = '' as $$ select private.plataforma_guardar_config_impl(p_datos_pago, p_whatsapp); $$;
create or replace function public.membresia_cupo(p_negocio uuid)
returns jsonb language sql stable set search_path = '' as $$ select private.membresia_cupo(p_negocio); $$;

revoke all on function public.plataforma_soy_admin() from public, anon;
revoke all on function public.plataforma_resumen() from public, anon;
revoke all on function public.plataforma_registrar_pago(uuid, numeric, date, text, text, integer, text, text) from public, anon;
revoke all on function public.plataforma_anular_pago(uuid) from public, anon;
revoke all on function public.plataforma_guardar_membresia(uuid, text, text, text, date, integer, numeric, boolean, text) from public, anon;
revoke all on function public.plataforma_guardar_config(text, text) from public, anon;
revoke all on function public.membresia_cupo(uuid) from public, anon, authenticated;
grant execute on function public.plataforma_soy_admin() to authenticated;
grant execute on function public.plataforma_resumen() to authenticated;
grant execute on function public.plataforma_registrar_pago(uuid, numeric, date, text, text, integer, text, text) to authenticated;
grant execute on function public.plataforma_anular_pago(uuid) to authenticated;
grant execute on function public.plataforma_guardar_membresia(uuid, text, text, text, date, integer, numeric, boolean, text) to authenticated;
grant execute on function public.plataforma_guardar_config(text, text) to authenticated;
grant execute on function public.membresia_cupo(uuid) to service_role;
grant execute on function private.membresia_cupo(uuid) to service_role;
