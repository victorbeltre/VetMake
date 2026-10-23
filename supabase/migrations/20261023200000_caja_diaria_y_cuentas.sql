-- Caja diaria, libro de caja, cuentas y traslados, por clínica.
--
-- Viene de PetColinas (M18, M19 y M20), adaptado a multiempresa y al modelo de
-- VetMake (las escrituras solo por RPC). Las razones de fondo no cambian:
--
--   * El libro NO duplica el dinero: es una VISTA sobre ventas, abonos, gastos y
--     movimientos de caja. Copiar ventas a otra tabla daría dos fuentes de verdad.
--   * El arqueo es SOBRE EFECTIVO. Una transferencia no está en la gaveta.
--   * Un TRASLADO (depositar el efectivo en el banco, la liquidación del POS)
--     no es ingreso ni gasto: es la misma plata cambiando de sitio. No toca el
--     flujo del negocio, pero sí el efectivo de la gaveta y el saldo de cada
--     cuenta. La comisión de tarjeta no se estima: es lo que salió menos lo que
--     llegó en la liquidación.
--   * El banco no se arquea, se concilia: su diferencia son «partidas
--     pendientes», no un descuadre.
--
-- Lo que cambia respecto a PetColinas:
--   * Todas las tablas llevan negocio_id y las claves lo incluyen.
--   * Los bancos no están escritos en el código (PetColinas tenía Popular,
--     Banreservas y Santa Cruz en una expresión regular). Cada clínica da de
--     alta sus cuentas con palabras clave (`alias`) que se buscan en el texto
--     de la forma de pago. Si la clínica tiene UN solo banco activo, una
--     transferencia sin banco anotado cae ahí (no puede caer en otro sitio);
--     con dos o más va a «Sin asignar», como en PetColinas.
--   * Cada clínica nace con sus cuentas base (gaveta, tarjetas por liquidar,
--     tarjeta de crédito de la empresa, sin asignar) por un trigger en negocios.
--   * El cierre lo calcula el SERVIDOR (en PetColinas lo mandaba el navegador):
--     la foto del arqueo no depende de lo que diga una pestaña vieja.
--   * Las funciones SECURITY DEFINER filtran por mi_negocio() a mano: dentro de
--     ellas la RLS no aplica, así que el filtro explícito es lo único que separa
--     una clínica de otra.
--   * La caja la usan admin, caja y veterinario. El groomer no: solo ve sus
--     propias ventas, así que su libro saldría incompleto. Cuentas, traslados y
--     saldos de banco son solo-admin.

-- ─── 1. Normalizadores (sin datos de ninguna clínica) ───────────────────────
create or replace function public.pc_metodo_pago(p_texto text)
returns text language sql immutable set search_path = '' as $$
  select case
    when t ~ 'pendiente'                then 'PENDIENTE'
    when t ~ 'sin cobro|no se le cobr'  then 'SIN COBRO'
    -- La tarjeta de crédito de la empresa es DEUDA, no un cobro con tarjeta.
    -- Se detecta antes del chequeo de mixto (contiene «tarjeta» y a veces un banco).
    when t ~ 'tarjeta empresari|tarjeta (de credito |de crédito )?(de )?(la )?empresa|tarjeta corporativ'
                                        then 'TARJETA EMPRESA'
    -- MIXTO a propósito: repartir el monto sin que alguien diga cuánto va a
    -- cada método sería inventarse el dato.
    when (t ~ 'efectivo')::int
       + (t ~ 'transfer|trasferencia|deposit|banco|popular|reserv|bhd|scotia|santa cruz|banesco|promerica|vimenca|lafise|ademi|caribe|lopez de haro|apap|cibao|qik')::int
       + (t ~ 'tarjeta')::int
       + (t ~ 'cheque')::int > 1        then 'MIXTO'
    when t ~ 'efectivo'                 then 'EFECTIVO'
    when t ~ 'tarjeta'                  then 'TARJETA'
    when t ~ 'cheque'                   then 'CHEQUE'
    when t ~ 'transfer|trasferencia|deposit|banco|popular|reserv|bhd|scotia|santa cruz|banesco|promerica|vimenca|lafise|ademi|caribe|lopez de haro|apap|cibao|qik'
                                        then 'TRANSFERENCIA'
    when t = ''                         then 'SIN ANOTAR'
    else 'OTRO'
  end
  from (select lower(btrim(coalesce(p_texto, ''))) as t) x;
$$;

-- Las fechas se guardan como texto: esto convierte sin reventar con lo que haya.
create or replace function public.pc_fecha(p_texto text)
returns date language sql immutable set search_path = '' as $$
  select case when coalesce(p_texto, '') ~ '^\d{4}-\d{2}-\d{2}' then left(p_texto, 10)::date end;
$$;

revoke all on function public.pc_metodo_pago(text) from public, anon;
revoke all on function public.pc_fecha(text) from public, anon;
grant execute on function public.pc_metodo_pago(text) to authenticated, service_role;
grant execute on function public.pc_fecha(text) to authenticated, service_role;

-- ─── 2. Tablas ───────────────────────────────────────────────────────────────
create table if not exists public.pc_cuentas (
  negocio_id uuid not null references public.negocios(id) on delete cascade,
  id         text not null,
  nombre     text not null,
  tipo       text not null check (tipo in ('EFECTIVO', 'BANCO', 'PUENTE', 'CREDITO', 'SIN_ASIGNAR')),
  alias      text[] not null default '{}',
  se_cuenta  boolean not null default false,
  activa     boolean not null default true,
  orden      int not null default 100,
  notas      text,
  creado     timestamptz not null default now(),
  primary key (negocio_id, id)
);

create table if not exists public.pc_caja_dia (
  negocio_id        uuid not null references public.negocios(id) on delete cascade,
  fecha             date not null,
  estado            text not null default 'abierta' check (estado in ('abierta', 'cerrada')),
  saldo_inicial     numeric(14,2) not null default 0,
  abierta_en        timestamptz,
  abierta_por       text,
  cerrada_en        timestamptz,
  cerrada_por       text,
  efectivo_contado  numeric(14,2),
  -- Foto del momento del cierre, NO un cálculo que se rehace: si una venta se
  -- corrige días después, el arqueo sigue diciendo lo que se contó esa noche.
  entradas_efectivo numeric(14,2),
  salidas_efectivo  numeric(14,2),
  teorico_efectivo  numeric(14,2),
  diferencia        numeric(14,2),
  notas             text,
  actualizado       timestamptz not null default now(),
  primary key (negocio_id, fecha)
);

create table if not exists public.pc_caja_movimientos (
  id          bigserial primary key,
  negocio_id  uuid not null references public.negocios(id) on delete cascade,
  fecha       date not null,
  hora        time,
  tipo        text not null check (tipo in ('ENTRADA', 'SALIDA')),
  concepto    text not null,
  categoria   text,
  metodo_pago text not null default 'EFECTIVO',
  referencia  text,
  monto       numeric(14,2) not null check (monto > 0),
  usuario     text,
  usuario_id  uuid,
  notas       text,
  creado      timestamptz not null default now()
);
create index if not exists pc_caja_mov_negocio_fecha_idx on public.pc_caja_movimientos (negocio_id, fecha);

create table if not exists public.pc_traslados (
  id             bigserial primary key,
  negocio_id     uuid not null references public.negocios(id) on delete cascade,
  fecha          date not null,
  hora           time,
  cuenta_origen  text not null,
  cuenta_destino text not null,
  monto          numeric(14,2) not null check (monto > 0),
  monto_recibido numeric(14,2) check (monto_recibido is null or monto_recibido > 0),
  concepto       text not null,
  referencia     text,
  usuario        text,
  usuario_id     uuid,
  notas          text,
  creado         timestamptz not null default now(),
  constraint pc_traslados_distintas check (cuenta_origen <> cuenta_destino),
  foreign key (negocio_id, cuenta_origen) references public.pc_cuentas (negocio_id, id),
  foreign key (negocio_id, cuenta_destino) references public.pc_cuentas (negocio_id, id)
);
create index if not exists pc_traslados_negocio_fecha_idx on public.pc_traslados (negocio_id, fecha);

-- El saldo que el dueño LEE de la app del banco: no se calcula, se declara.
create table if not exists public.pc_cuenta_saldos (
  negocio_id    uuid not null,
  cuenta_id     text not null,
  fecha         date not null,
  saldo         numeric(14,2) not null,
  declarado_por text,
  declarado_en  timestamptz not null default now(),
  notas         text,
  primary key (negocio_id, cuenta_id, fecha),
  foreign key (negocio_id, cuenta_id) references public.pc_cuentas (negocio_id, id) on delete cascade
);

-- RLS: lectura por clínica y rol; ninguna escritura directa (solo por RPC).
alter table public.pc_cuentas          enable row level security;
alter table public.pc_caja_dia         enable row level security;
alter table public.pc_caja_movimientos enable row level security;
alter table public.pc_traslados        enable row level security;
alter table public.pc_cuenta_saldos    enable row level security;

revoke all on public.pc_cuentas, public.pc_caja_dia, public.pc_caja_movimientos,
              public.pc_traslados, public.pc_cuenta_saldos from anon, public, authenticated;
revoke all on sequence public.pc_caja_movimientos_id_seq, public.pc_traslados_id_seq from anon, public, authenticated;
grant select on public.pc_cuentas, public.pc_caja_dia, public.pc_caja_movimientos,
                public.pc_traslados, public.pc_cuenta_saldos to authenticated;

drop policy if exists "caja_dia_personal_lee" on public.pc_caja_dia;
create policy "caja_dia_personal_lee" on public.pc_caja_dia for select to authenticated
  using (negocio_id = (select public.mi_negocio())
         and (select public.tiene_rol(array['admin', 'caja', 'veterinario'])));

drop policy if exists "caja_mov_personal_lee" on public.pc_caja_movimientos;
create policy "caja_mov_personal_lee" on public.pc_caja_movimientos for select to authenticated
  using (negocio_id = (select public.mi_negocio())
         and (select public.tiene_rol(array['admin', 'caja', 'veterinario'])));

drop policy if exists "cuentas_admin_lee" on public.pc_cuentas;
create policy "cuentas_admin_lee" on public.pc_cuentas for select to authenticated
  using (negocio_id = (select public.mi_negocio()) and (select public.tiene_rol(array['admin'])));

drop policy if exists "traslados_admin_lee" on public.pc_traslados;
create policy "traslados_admin_lee" on public.pc_traslados for select to authenticated
  using (negocio_id = (select public.mi_negocio()) and (select public.tiene_rol(array['admin'])));

drop policy if exists "cuenta_saldos_admin_lee" on public.pc_cuenta_saldos;
create policy "cuenta_saldos_admin_lee" on public.pc_cuenta_saldos for select to authenticated
  using (negocio_id = (select public.mi_negocio()) and (select public.tiene_rol(array['admin'])));

-- ─── 3. Cuentas base de cada clínica ────────────────────────────────────────
create or replace function private.caja_asegurar_cuentas(p_negocio uuid)
returns void language sql security definer set search_path = '' as $$
  insert into public.pc_cuentas (negocio_id, id, nombre, tipo, se_cuenta, activa, orden, notas) values
    (p_negocio, 'gaveta', 'Caja chica (gaveta)', 'EFECTIVO', true, true, 10,
     'La única que se cuenta a mano. Su arqueo es el cierre de caja de cada día.'),
    (p_negocio, 'tarjetas', 'Tarjetas por liquidar', 'PUENTE', false, true, 50,
     'Cuenta puente: la venta con tarjeta entra aquí el día de la venta y sale cuando el banco la deposita. Lo que sale menos lo que entra al banco es la comisión.'),
    (p_negocio, 'tarjeta_empresa', 'Tarjeta de crédito de la empresa', 'CREDITO', false, true, 60,
     'Deuda, no dinero: lo pagado con ella no sale del banco hasta pagar el estado de cuenta. Se salda con un traslado desde el banco.'),
    (p_negocio, 'sin_asignar', 'Sin asignar', 'SIN_ASIGNAR', false, true, 90,
     'Transferencias sin banco reconocible, pagos mixtos o sin anotar. Mientras tenga saldo, la conciliación no puede cerrar.')
  on conflict (negocio_id, id) do nothing;
$$;
revoke all on function private.caja_asegurar_cuentas(uuid) from public, anon, authenticated;

create or replace function private.caja_cuentas_negocio_nuevo()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.caja_asegurar_cuentas(new.id);
  return new;
end $$;
revoke all on function private.caja_cuentas_negocio_nuevo() from public, anon, authenticated;

drop trigger if exists vetmake_cuentas_base on public.negocios;
create trigger vetmake_cuentas_base after insert on public.negocios
  for each row execute function private.caja_cuentas_negocio_nuevo();

select private.caja_asegurar_cuentas(n.id) from public.negocios n;

-- ─── 4. A qué cuenta cae cada movimiento ─────────────────────────────────────
-- SECURITY DEFINER porque pc_cuentas es solo-admin: sin esto, para caja todo
-- caería en «sin_asignar» en silencio. Solo responde para la clínica de quien
-- pregunta.
create or replace function private.cuenta_de_impl(p_negocio uuid, p_metodo text, p_texto text)
returns text language plpgsql stable security definer set search_path = '' as $$
declare v_id text; v_bancos int; t text := lower(coalesce(p_texto, ''));
begin
  if p_negocio is distinct from (select public.mi_negocio()) then return null; end if;
  if p_metodo = 'EFECTIVO' then return 'gaveta'; end if;
  if p_metodo = 'TARJETA' then return 'tarjetas'; end if;
  if p_metodo = 'TARJETA EMPRESA' then return 'tarjeta_empresa'; end if;
  if p_metodo in ('TRANSFERENCIA', 'CHEQUE') then
    select c.id into v_id from public.pc_cuentas c
     where c.negocio_id = p_negocio and c.tipo = 'BANCO' and c.activa
       and exists (select 1 from unnest(c.alias) a where length(btrim(a)) >= 3 and position(lower(btrim(a)) in t) > 0)
     order by c.orden, c.id limit 1;
    if v_id is not null then return v_id; end if;
    select count(*) into v_bancos from public.pc_cuentas c
     where c.negocio_id = p_negocio and c.tipo = 'BANCO' and c.activa;
    if v_bancos = 1 then
      select c.id into v_id from public.pc_cuentas c
       where c.negocio_id = p_negocio and c.tipo = 'BANCO' and c.activa;
      return v_id;
    end if;
  end if;
  return 'sin_asignar';
end $$;
revoke all on function private.cuenta_de_impl(uuid, text, text) from public, anon, authenticated;
grant execute on function private.cuenta_de_impl(uuid, text, text) to authenticated, service_role;

-- Envoltorio invoker: la lógica privilegiada vive en private (lo exige el
-- asesor de seguridad para todo SECURITY DEFINER en el esquema expuesto).
create or replace function public.pc_cuenta_de(p_negocio uuid, p_metodo text, p_texto text)
returns text language sql stable security invoker set search_path = '' as $$
  select private.cuenta_de_impl(p_negocio, p_metodo, p_texto); $$;
revoke all on function public.pc_cuenta_de(uuid, text, text) from public, anon;
grant execute on function public.pc_cuenta_de(uuid, text, text) to authenticated, service_role;

-- ─── 5. El libro de caja (vista, respeta la RLS de quien lee) ────────────────
create or replace view public.pc_caja_libro as
select
  v.negocio_id,
  'venta:' || v.id as id, public.pc_fecha(v.fecha) as fecha,
  coalesce(v.created_at, public.pc_fecha(v.fecha)::timestamptz) as fecha_hora,
  v.id::text as referencia,
  coalesce(nullif(v.servicio, ''), nullif(v.descripcion, ''), 'Venta')
    || coalesce(' - ' || nullif(v.cliente, ''), '') as concepto,
  coalesce(nullif(v.area, ''), 'Ventas') as categoria,
  public.pc_metodo_pago(coalesce(v.formapago, '') || ' ' || coalesce(v.banco, '')) as metodo_pago,
  lower(coalesce(v.formapago, '') || ' ' || coalesce(v.banco, '')) as texto_pago,
  coalesce(v.total, 0)::numeric(14,2) as entrada,
  0::numeric(14,2) as salida,
  v.recibidopor as usuario, 'venta'::text as origen
from public.pc_ventas v
where public.pc_fecha(v.fecha) is not null
  and v.anulada_en is null
  and public.pc_metodo_pago(coalesce(v.formapago, '') || ' ' || coalesce(v.banco, '')) not in ('PENDIENTE', 'SIN COBRO')
  and coalesce(jsonb_array_length(case when jsonb_typeof(v.abonos) = 'array' then v.abonos else '[]'::jsonb end), 0) = 0
union all
-- Las ventas con abonos entran por aquí, el día en que llegó cada abono.
select
  v.negocio_id,
  'abono:' || v.id || ':' || (a.ord - 1), public.pc_fecha(a.item ->> 'fecha'),
  coalesce(public.pc_fecha(a.item ->> 'fecha')::timestamptz, v.created_at),
  v.id::text, 'Abono - ' || coalesce(nullif(v.cliente, ''), 'cliente'), 'Abonos',
  public.pc_metodo_pago(coalesce(a.item ->> 'forma', '') || ' ' || coalesce(a.item ->> 'banco', '')),
  lower(coalesce(a.item ->> 'forma', '') || ' ' || coalesce(a.item ->> 'banco', '')),
  coalesce((a.item ->> 'monto')::numeric, 0)::numeric(14,2), 0::numeric(14,2),
  a.item ->> 'por', 'abono'
from public.pc_ventas v
cross join lateral jsonb_array_elements(
  case when jsonb_typeof(v.abonos) = 'array' then v.abonos else '[]'::jsonb end) with ordinality as a(item, ord)
where v.anulada_en is null
  and public.pc_fecha(a.item ->> 'fecha') is not null
  and coalesce((a.item ->> 'monto')::numeric, 0) > 0
union all
-- Un gasto «pendiente de pago» se incurrió pero el dinero no se movió: no entra.
select
  g.negocio_id,
  'gasto:' || g.id, public.pc_fecha(g.fecha),
  coalesce(g.created_at, public.pc_fecha(g.fecha)::timestamptz),
  coalesce(nullif(g.proveedor, ''), g.id::text),
  coalesce(nullif(g.descripcion, ''), 'Gasto'),
  coalesce(nullif(g.categoria, ''), 'Sin categoría'),
  public.pc_metodo_pago(g.formapago), lower(coalesce(g.formapago, '')),
  0::numeric(14,2), coalesce(g.monto, 0)::numeric(14,2), g.pagadopor, 'gasto'
from public.pc_gastos g
where public.pc_fecha(g.fecha) is not null
  and g.anulado_en is null
  and public.pc_metodo_pago(g.formapago) <> 'PENDIENTE'
union all
select
  m.negocio_id,
  'mov:' || m.id, m.fecha, (m.fecha + coalesce(m.hora, '00:00'::time))::timestamptz,
  m.referencia, m.concepto, coalesce(nullif(m.categoria, ''), 'Caja'),
  m.metodo_pago, lower(coalesce(m.metodo_pago, '') || ' ' || coalesce(m.referencia, '')),
  (case when m.tipo = 'ENTRADA' then m.monto else 0 end)::numeric(14,2),
  (case when m.tipo = 'SALIDA'  then m.monto else 0 end)::numeric(14,2),
  m.usuario, 'movimiento'
from public.pc_caja_movimientos m;

-- SIEMPRE después de cada create or replace: la reinicia y se saltaría la RLS.
alter view public.pc_caja_libro set (security_invoker = on);
revoke all on public.pc_caja_libro from anon, public;
grant select on public.pc_caja_libro to authenticated;

-- ─── 6. Libro por cuenta y saldos reales ─────────────────────────────────────
create or replace view public.pc_cuenta_libro as
  select l.negocio_id, l.id, public.pc_cuenta_de(l.negocio_id, l.metodo_pago, l.texto_pago) as cuenta_id,
         l.fecha, l.fecha_hora, l.referencia, l.concepto, l.categoria,
         l.metodo_pago, l.entrada, l.salida, l.usuario, l.origen
    from public.pc_caja_libro l
  union all
  select t.negocio_id, 'traslado:' || t.id || ':sale', t.cuenta_origen,
         t.fecha, (t.fecha + coalesce(t.hora, '00:00'::time))::timestamptz,
         t.referencia, t.concepto, 'Traslado', 'TRASLADO',
         0::numeric(14,2), t.monto, t.usuario, 'traslado'
    from public.pc_traslados t
  union all
  select t.negocio_id, 'traslado:' || t.id || ':entra', t.cuenta_destino,
         t.fecha, (t.fecha + coalesce(t.hora, '00:00'::time))::timestamptz,
         t.referencia, t.concepto, 'Traslado', 'TRASLADO',
         coalesce(t.monto_recibido, t.monto), 0::numeric(14,2), t.usuario, 'traslado'
    from public.pc_traslados t;
alter view public.pc_cuenta_libro set (security_invoker = on);
revoke all on public.pc_cuenta_libro from anon, public;
grant select on public.pc_cuenta_libro to authenticated;

-- Para la gaveta el saldo real es el arqueo; para los bancos, lo declarado.
create or replace view public.pc_cuenta_declarado as
  select s.negocio_id, s.cuenta_id, s.fecha, s.saldo, s.declarado_por as por, s.notas, 'declarado'::text as origen
    from public.pc_cuenta_saldos s
  union all
  select d.negocio_id, 'gaveta', d.fecha, d.efectivo_contado, d.cerrada_por, d.notas, 'arqueo'::text
    from public.pc_caja_dia d
   where d.estado = 'cerrada' and d.efectivo_contado is not null;
alter view public.pc_cuenta_declarado set (security_invoker = on);
revoke all on public.pc_cuenta_declarado from anon, public;
grant select on public.pc_cuenta_declarado to authenticated;

-- ─── 7. Contexto común de las funciones ──────────────────────────────────────
-- Devuelve la clínica y el rol activos, o rompe con 42501. Dentro de una
-- función SECURITY DEFINER la RLS no aplica: todo filtra por este negocio.
create or replace function private.caja_contexto(p_roles text[], out negocio uuid, out rol text, out nombre text)
language plpgsql stable security definer set search_path = '' as $$
declare usuario uuid := (select auth.uid());
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Se requiere una sesión autenticada.';
  end if;
  select m.negocio_id, m.rol into negocio, rol
    from public.usuarios_negocio m
    join public.negocios c on c.id = m.negocio_id
   where m.usuario_id = usuario and m.activo = true and c.activo = true;
  if negocio is null or not (rol = any(p_roles)) then
    raise exception using errcode = '42501', message = 'No autorizado.';
  end if;
  select coalesce(
           (select nullif(btrim(e.nombre), '') from public.pc_empleados e
             where e.negocio_id = negocio and e.usuario_id = usuario limit 1),
           (select u.email from auth.users u where u.id = usuario), 'usuario')
    into nombre;
end $$;
revoke all on function private.caja_contexto(text[]) from public, anon, authenticated;
grant execute on function private.caja_contexto(text[]) to authenticated, service_role;

-- ─── 8. Resumen del día (solo totales) ───────────────────────────────────────
-- entradas/salidas_efectivo SÍ llevan traslados (billetes entrando o saliendo
-- de la gaveta); entradas/salidas_total NO (un traslado no es ingreso ni gasto).
create or replace function private.caja_resumen_impl(p_fecha date)
returns table (saldo_inicial numeric, entradas_efectivo numeric, salidas_efectivo numeric,
               teorico_efectivo numeric, entradas_total numeric, salidas_total numeric)
language plpgsql stable security definer set search_path = '' as $$
declare ctx record;
begin
  select * into ctx from private.caja_contexto(array['admin', 'caja', 'veterinario']);
  return query
  with ini as (
    select coalesce((select d.saldo_inicial from public.pc_caja_dia d
                      where d.negocio_id = ctx.negocio and d.fecha = p_fecha), 0) as s
  ), mov as (
    select coalesce(sum(l.entrada) filter (where l.metodo_pago = 'EFECTIVO'), 0) as ent_ef,
           coalesce(sum(l.salida)  filter (where l.metodo_pago = 'EFECTIVO'), 0) as sal_ef,
           coalesce(sum(l.entrada), 0) as ent_tot,
           coalesce(sum(l.salida), 0) as sal_tot
      from public.pc_caja_libro l
     where l.negocio_id = ctx.negocio and l.fecha = p_fecha
  ), tras as (
    select coalesce(sum(coalesce(t.monto_recibido, t.monto)) filter (where t.cuenta_destino = 'gaveta'), 0) as ent_ef,
           coalesce(sum(t.monto) filter (where t.cuenta_origen = 'gaveta'), 0) as sal_ef
      from public.pc_traslados t
     where t.negocio_id = ctx.negocio and t.fecha = p_fecha
  )
  select ini.s, (mov.ent_ef + tras.ent_ef), (mov.sal_ef + tras.sal_ef),
         (ini.s + mov.ent_ef + tras.ent_ef - mov.sal_ef - tras.sal_ef),
         mov.ent_tot, mov.sal_tot
    from ini, mov, tras;
end $$;

-- ─── 9. Reporte de periodo ───────────────────────────────────────────────────
-- Misma firma de 4 argumentos que en PetColinas: añadir uno crearía una
-- sobrecarga que PostgREST no sabría resolver con una pestaña vieja abierta.
-- por_cuenta y por_cuenta_categoria vienen NULOS para quien no es admin.
create or replace function private.caja_reporte_impl(p_desde date, p_hasta date, p_metodo text, p_categoria text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare ctx record; v jsonb; v_admin boolean;
begin
  select * into ctx from private.caja_contexto(array['admin', 'caja', 'veterinario']);
  if p_desde is null or p_hasta is null then
    raise exception using errcode = '22023', message = 'Falta el rango de fechas.';
  end if;
  if p_hasta < p_desde then
    raise exception using errcode = '22023', message = format('El rango está al revés: %s va después de %s.', p_desde, p_hasta);
  end if;
  if p_hasta - p_desde > 1100 then
    raise exception using errcode = '22023', message = 'El rango no puede pasar de tres años.';
  end if;
  v_admin := ctx.rol = 'admin';

  with mov as (
    select l.*, public.pc_cuenta_de(l.negocio_id, l.metodo_pago, l.texto_pago) as cuenta_id
      from public.pc_caja_libro l
     where l.negocio_id = ctx.negocio
       and l.fecha between p_desde and p_hasta
       and (p_metodo is null or l.metodo_pago = p_metodo)
       and (p_categoria is null or l.categoria = p_categoria)
  ), tot as (
    select coalesce(sum(entrada), 0) e, coalesce(sum(salida), 0) s, count(*) n, count(distinct fecha) d from mov
  ), met as (
    select coalesce(jsonb_agg(x order by x->>'metodo'), '[]'::jsonb) j from (
      select jsonb_build_object('metodo', metodo_pago, 'entradas', sum(entrada), 'salidas', sum(salida),
               'neto', sum(entrada) - sum(salida), 'movimientos', count(*)) x
        from mov group by metodo_pago) z
  ), cat as (
    select coalesce(jsonb_agg(x order by (x->>'total')::numeric desc), '[]'::jsonb) j from (
      select jsonb_build_object('categoria', categoria, 'entradas', sum(entrada), 'salidas', sum(salida),
               'neto', sum(entrada) - sum(salida), 'total', sum(entrada) + sum(salida), 'movimientos', count(*)) x
        from mov group by categoria) z
  ), dia as (
    select coalesce(jsonb_agg(x order by x->>'fecha'), '[]'::jsonb) j from (
      select jsonb_build_object('fecha', fecha, 'entradas', sum(entrada), 'salidas', sum(salida),
               'neto', sum(entrada) - sum(salida), 'movimientos', count(*)) x
        from mov group by fecha) z
  ), cta as (
    select coalesce(jsonb_agg(x order by (x->>'orden')::int, x->>'cuenta_id'), '[]'::jsonb) j from (
      select jsonb_build_object('cuenta_id', m.cuenta_id, 'nombre', coalesce(c.nombre, m.cuenta_id),
               'tipo', coalesce(c.tipo, 'SIN_ASIGNAR'), 'orden', coalesce(c.orden, 999),
               'entradas', sum(m.entrada), 'salidas', sum(m.salida),
               'neto', sum(m.entrada) - sum(m.salida), 'movimientos', count(*)) x
        from mov m
        left join public.pc_cuentas c on c.negocio_id = ctx.negocio and c.id = m.cuenta_id
       group by m.cuenta_id, c.nombre, c.tipo, c.orden) z
  ), ctacat as (
    select coalesce(jsonb_agg(x order by x->>'cuenta_id', (x->>'total')::numeric desc), '[]'::jsonb) j from (
      select jsonb_build_object('cuenta_id', cuenta_id, 'categoria', categoria,
               'entradas', sum(entrada), 'salidas', sum(salida), 'neto', sum(entrada) - sum(salida),
               'total', sum(entrada) + sum(salida), 'movimientos', count(*)) x
        from mov group by cuenta_id, categoria) z
  ), arq as (
    select count(*) filter (where estado = 'cerrada') cerrados,
           count(*) filter (where estado = 'abierta') abiertos,
           count(*) filter (where estado = 'cerrada' and abs(coalesce(diferencia, 0)) >= 0.005) con_descuadre,
           coalesce(sum(diferencia) filter (where estado = 'cerrada'), 0) descuadre_neto,
           coalesce(sum(abs(diferencia)) filter (where estado = 'cerrada'), 0) descuadre_abs
      from public.pc_caja_dia
     where negocio_id = ctx.negocio and fecha between p_desde and p_hasta
  )
  select jsonb_build_object(
    'desde', p_desde, 'hasta', p_hasta, 'dias_rango', (p_hasta - p_desde) + 1,
    'totales', jsonb_build_object(
      'entradas', tot.e, 'salidas', tot.s, 'neto', tot.e - tot.s,
      'movimientos', tot.n, 'dias_con_movimiento', tot.d,
      -- promedio sobre los días que SÍ tuvieron movimiento: los cerrados hunden la media.
      'promedio_dia_entradas', case when tot.d > 0 then round(tot.e / tot.d, 2) else 0 end,
      'promedio_dia_neto',     case when tot.d > 0 then round((tot.e - tot.s) / tot.d, 2) else 0 end),
    'por_metodo', met.j, 'por_categoria', cat.j, 'por_dia', dia.j,
    'por_cuenta',           case when v_admin then cta.j    else null end,
    'por_cuenta_categoria', case when v_admin then ctacat.j else null end,
    'arqueos', jsonb_build_object(
      'cerrados', arq.cerrados, 'abiertos', arq.abiertos, 'con_descuadre', arq.con_descuadre,
      'descuadre_neto', arq.descuadre_neto, 'descuadre_abs', arq.descuadre_abs)
  ) into v
  from tot, met, cat, dia, cta, ctacat, arq;
  return v;
end $$;

-- ─── 10. Estado de las cuentas en un día (solo admin) ────────────────────────
-- El teórico se ancla en el último saldo REAL conocido (arqueo o saldo
-- declarado). Sin ancla sería la suma de todo desde el principio, que no
-- significa nada: se devuelve `sin_ancla` y la pantalla lo dice.
create or replace function private.cuentas_estado_impl(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare ctx record; v jsonb;
begin
  select * into ctx from private.caja_contexto(array['admin']);
  select coalesce(jsonb_agg(x order by orden), '[]'::jsonb) into v from (
    select c.orden, jsonb_build_object(
      'cuenta_id', c.id, 'nombre', c.nombre, 'tipo', c.tipo, 'se_cuenta', c.se_cuenta, 'alias', c.alias,
      'ancla_fecha', a.fecha, 'ancla_saldo', a.saldo, 'ancla_origen', a.origen,
      'sin_ancla', (a.fecha is null),
      'saldo_inicial', ini.v, 'entradas', dia.e, 'salidas', dia.s,
      'saldo_final_teorico', ini.v + dia.e - dia.s,
      'declarado_hoy', hoy.saldo, 'declarado_origen', hoy.origen,
      'diferencia', case when hoy.saldo is null then null else hoy.saldo - (ini.v + dia.e - dia.s) end,
      'movimientos', dia.n) x
    from public.pc_cuentas c
    left join lateral (
      select d.fecha, d.saldo, d.origen from public.pc_cuenta_declarado d
       where d.negocio_id = ctx.negocio and d.cuenta_id = c.id and d.fecha < p_fecha
       order by d.fecha desc limit 1) a on true
    cross join lateral (
      select coalesce(a.saldo, 0) + coalesce((
        select sum(l.entrada - l.salida) from public.pc_cuenta_libro l
         where l.negocio_id = ctx.negocio and l.cuenta_id = c.id
           and l.fecha > coalesce(a.fecha, '0001-01-01'::date) and l.fecha < p_fecha), 0) as v) ini
    cross join lateral (
      select coalesce(sum(l.entrada), 0) e, coalesce(sum(l.salida), 0) s, count(*) n
        from public.pc_cuenta_libro l
       where l.negocio_id = ctx.negocio and l.cuenta_id = c.id and l.fecha = p_fecha) dia
    left join lateral (
      select d.saldo, d.origen from public.pc_cuenta_declarado d
       where d.negocio_id = ctx.negocio and d.cuenta_id = c.id and d.fecha = p_fecha limit 1) hoy on true
    where c.negocio_id = ctx.negocio and c.activa
  ) z;
  return jsonb_build_object('fecha', p_fecha, 'cuentas', v);
end $$;

-- ─── 11. Escrituras ──────────────────────────────────────────────────────────
create or replace function private.caja_abrir_dia_impl(p_fecha date, p_saldo_inicial numeric)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ctx record; fila public.pc_caja_dia%rowtype;
begin
  select * into ctx from private.caja_contexto(array['admin', 'caja', 'veterinario']);
  if p_fecha is null or p_saldo_inicial is null or p_saldo_inicial < 0 or p_saldo_inicial > 99999999 then
    raise exception using errcode = '22023', message = 'Escribe la fecha y el efectivo con el que abre la caja.';
  end if;
  select * into fila from public.pc_caja_dia d where d.negocio_id = ctx.negocio and d.fecha = p_fecha for update;
  if found and fila.estado = 'cerrada' then
    raise exception using errcode = '22023', message = 'La caja de ese día ya está cerrada. Un administrador puede reabrirla.';
  end if;
  insert into public.pc_caja_dia as d (negocio_id, fecha, estado, saldo_inicial, abierta_en, abierta_por, actualizado)
  values (ctx.negocio, p_fecha, 'abierta', round(p_saldo_inicial, 2), now(), ctx.nombre, now())
  on conflict (negocio_id, fecha) do update
    set saldo_inicial = excluded.saldo_inicial, actualizado = now()
  returning * into fila;
  return to_jsonb(fila);
end $$;

-- El servidor calcula el teórico en el momento del cierre: la foto no depende
-- de lo que tenga cargado el navegador.
create or replace function private.caja_cerrar_dia_impl(p_fecha date, p_efectivo_contado numeric, p_notas text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ctx record; fila public.pc_caja_dia%rowtype; r record;
begin
  select * into ctx from private.caja_contexto(array['admin', 'caja', 'veterinario']);
  if p_efectivo_contado is null or p_efectivo_contado < 0 or p_efectivo_contado > 99999999 then
    raise exception using errcode = '22023', message = 'Escribe el efectivo contado en la gaveta.';
  end if;
  select * into fila from public.pc_caja_dia d where d.negocio_id = ctx.negocio and d.fecha = p_fecha for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'Primero hay que abrir la caja de ese día.';
  end if;
  if fila.estado = 'cerrada' then
    raise exception using errcode = '22023', message = 'La caja de ese día ya está cerrada.';
  end if;
  select * into r from private.caja_resumen_impl(p_fecha);
  update public.pc_caja_dia
     set estado = 'cerrada', cerrada_en = now(), cerrada_por = ctx.nombre,
         efectivo_contado = round(p_efectivo_contado, 2),
         entradas_efectivo = r.entradas_efectivo, salidas_efectivo = r.salidas_efectivo,
         teorico_efectivo = r.teorico_efectivo,
         diferencia = round(p_efectivo_contado - r.teorico_efectivo, 2),
         notas = nullif(left(btrim(coalesce(p_notas, '')), 1000), ''), actualizado = now()
   where negocio_id = ctx.negocio and fecha = p_fecha
  returning * into fila;
  return to_jsonb(fila);
end $$;

create or replace function private.caja_reabrir_dia_impl(p_fecha date)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ctx record; fila public.pc_caja_dia%rowtype;
begin
  select * into ctx from private.caja_contexto(array['admin']);
  update public.pc_caja_dia set estado = 'abierta', actualizado = now()
   where negocio_id = ctx.negocio and fecha = p_fecha and estado = 'cerrada'
  returning * into fila;
  if not found then
    raise exception using errcode = 'P0002', message = 'No hay una caja cerrada en esa fecha.';
  end if;
  return to_jsonb(fila);
end $$;

create or replace function private.caja_registrar_movimiento_impl(p_mov jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ctx record; fila public.pc_caja_movimientos%rowtype; v_fecha date; v_tipo text; v_metodo text; v_monto numeric;
begin
  select * into ctx from private.caja_contexto(array['admin', 'caja', 'veterinario']);
  v_fecha := (p_mov ->> 'fecha')::date;
  v_tipo := upper(coalesce(p_mov ->> 'tipo', ''));
  v_metodo := upper(coalesce(nullif(p_mov ->> 'metodo_pago', ''), 'EFECTIVO'));
  v_monto := round((p_mov ->> 'monto')::numeric, 2);
  if v_fecha is null or v_tipo not in ('ENTRADA', 'SALIDA') or v_monto is null or v_monto <= 0 or v_monto > 99999999
     or nullif(btrim(coalesce(p_mov ->> 'concepto', '')), '') is null then
    raise exception using errcode = '22023', message = 'El movimiento necesita fecha, tipo, concepto y un monto mayor que cero.';
  end if;
  if v_metodo not in ('EFECTIVO', 'TRANSFERENCIA', 'TARJETA', 'TARJETA EMPRESA', 'CHEQUE') then
    raise exception using errcode = '22023', message = 'Método de pago no válido.';
  end if;
  if exists (select 1 from public.pc_caja_dia d where d.negocio_id = ctx.negocio and d.fecha = v_fecha and d.estado = 'cerrada') then
    raise exception using errcode = '22023', message = 'La caja de ese día está cerrada. Un administrador puede reabrirla.';
  end if;
  insert into public.pc_caja_movimientos (negocio_id, fecha, hora, tipo, concepto, categoria, metodo_pago, referencia, monto, usuario, usuario_id, notas)
  values (ctx.negocio, v_fecha, nullif(p_mov ->> 'hora', '')::time, v_tipo,
          left(btrim(p_mov ->> 'concepto'), 200), nullif(left(btrim(coalesce(p_mov ->> 'categoria', '')), 80), ''),
          v_metodo, nullif(left(btrim(coalesce(p_mov ->> 'referencia', '')), 120), ''), v_monto,
          ctx.nombre, (select auth.uid()), nullif(left(btrim(coalesce(p_mov ->> 'notas', '')), 1000), ''))
  returning * into fila;
  return to_jsonb(fila);
exception
  when invalid_text_representation or invalid_datetime_format or datetime_field_overflow or numeric_value_out_of_range then
    raise exception using errcode = '22023', message = 'El movimiento tiene una fecha, hora o monto inválidos.';
end $$;

-- Alta o edición de una cuenta. Solo se crean cuentas de BANCO: las demás son
-- las base de la clínica y solo se pueden renombrar o activar/desactivar.
create or replace function private.cuentas_guardar_impl(p_cuenta jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ctx record; fila public.pc_cuentas%rowtype; v_id text; v_nombre text; v_alias text[];
begin
  select * into ctx from private.caja_contexto(array['admin']);
  perform private.caja_asegurar_cuentas(ctx.negocio);
  v_nombre := nullif(left(btrim(coalesce(p_cuenta ->> 'nombre', '')), 80), '');
  select coalesce(array_agg(distinct lower(btrim(x.v))) filter (where length(btrim(x.v)) >= 3), '{}')
    into v_alias
    from jsonb_array_elements_text(coalesce(p_cuenta -> 'alias', '[]'::jsonb)) as x(v);
  v_id := nullif(btrim(coalesce(p_cuenta ->> 'id', '')), '');

  if v_id is null then
    if v_nombre is null then
      raise exception using errcode = '22023', message = 'La cuenta necesita un nombre.';
    end if;
    v_id := 'banco_' || substr(md5(ctx.negocio::text || v_nombre || clock_timestamp()::text), 1, 8);
    insert into public.pc_cuentas (negocio_id, id, nombre, tipo, alias, se_cuenta, activa, orden)
    values (ctx.negocio, v_id, v_nombre, 'BANCO', v_alias, false, true,
            20 + (select count(*) from public.pc_cuentas c where c.negocio_id = ctx.negocio and c.tipo = 'BANCO')::int)
    returning * into fila;
  else
    update public.pc_cuentas c
       set nombre = coalesce(v_nombre, c.nombre),
           alias  = case when c.tipo = 'BANCO' and p_cuenta ? 'alias' then v_alias else c.alias end,
           activa = case when c.id in ('gaveta', 'sin_asignar') then true
                         else coalesce((p_cuenta ->> 'activa')::boolean, c.activa) end
     where c.negocio_id = ctx.negocio and c.id = v_id
    returning * into fila;
    if not found then
      raise exception using errcode = 'P0002', message = 'La cuenta no existe en esta clínica.';
    end if;
  end if;
  return to_jsonb(fila);
end $$;

create or replace function private.cuentas_registrar_traslado_impl(p_traslado jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ctx record; fila public.pc_traslados%rowtype; v_monto numeric; v_recibido numeric;
        v_origen text := btrim(coalesce(p_traslado ->> 'cuenta_origen', ''));
        v_destino text := btrim(coalesce(p_traslado ->> 'cuenta_destino', ''));
begin
  select * into ctx from private.caja_contexto(array['admin']);
  perform private.caja_asegurar_cuentas(ctx.negocio);
  v_monto := round((p_traslado ->> 'monto')::numeric, 2);
  v_recibido := round(nullif(p_traslado ->> 'monto_recibido', '')::numeric, 2);
  if v_origen = '' or v_destino = '' or v_origen = v_destino then
    raise exception using errcode = '22023', message = 'Elige una cuenta de origen y una de destino distintas.';
  end if;
  if (select count(*) from public.pc_cuentas c
       where c.negocio_id = ctx.negocio and c.id in (v_origen, v_destino) and c.activa) <> 2 then
    raise exception using errcode = '22023', message = 'Alguna de las cuentas no existe o está desactivada.';
  end if;
  if v_monto is null or v_monto <= 0 or v_monto > 99999999 or (v_recibido is not null and (v_recibido <= 0 or v_recibido > v_monto)) then
    raise exception using errcode = '22023', message = 'Revisa los montos: lo recibido no puede ser mayor que lo enviado.';
  end if;
  if nullif(btrim(coalesce(p_traslado ->> 'concepto', '')), '') is null then
    raise exception using errcode = '22023', message = 'Escribe el concepto del traslado.';
  end if;
  insert into public.pc_traslados (negocio_id, fecha, hora, cuenta_origen, cuenta_destino, monto, monto_recibido,
                                   concepto, referencia, usuario, usuario_id, notas)
  values (ctx.negocio, (p_traslado ->> 'fecha')::date, nullif(p_traslado ->> 'hora', '')::time, v_origen, v_destino,
          v_monto, case when v_recibido = v_monto then null else v_recibido end,
          left(btrim(p_traslado ->> 'concepto'), 200), nullif(left(btrim(coalesce(p_traslado ->> 'referencia', '')), 120), ''),
          ctx.nombre, (select auth.uid()), nullif(left(btrim(coalesce(p_traslado ->> 'notas', '')), 1000), ''))
  returning * into fila;
  return to_jsonb(fila);
exception
  when invalid_text_representation or invalid_datetime_format or datetime_field_overflow or numeric_value_out_of_range or not_null_violation then
    raise exception using errcode = '22023', message = 'El traslado tiene una fecha, hora o monto inválidos.';
end $$;

create or replace function private.cuentas_declarar_saldo_impl(p_cuenta_id text, p_fecha date, p_saldo numeric, p_notas text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ctx record; fila public.pc_cuenta_saldos%rowtype;
begin
  select * into ctx from private.caja_contexto(array['admin']);
  if p_cuenta_id = 'gaveta' then
    raise exception using errcode = '22023', message = 'El saldo de la gaveta es el que se cuenta al cerrar la caja.';
  end if;
  if not exists (select 1 from public.pc_cuentas c where c.negocio_id = ctx.negocio and c.id = p_cuenta_id) then
    raise exception using errcode = 'P0002', message = 'La cuenta no existe en esta clínica.';
  end if;
  if p_fecha is null or p_saldo is null or abs(p_saldo) > 9999999999 then
    raise exception using errcode = '22023', message = 'Escribe la fecha y el saldo.';
  end if;
  insert into public.pc_cuenta_saldos as s (negocio_id, cuenta_id, fecha, saldo, declarado_por, declarado_en, notas)
  values (ctx.negocio, p_cuenta_id, p_fecha, round(p_saldo, 2), ctx.nombre, now(), nullif(left(btrim(coalesce(p_notas, '')), 1000), ''))
  on conflict (negocio_id, cuenta_id, fecha) do update
    set saldo = excluded.saldo, declarado_por = excluded.declarado_por, declarado_en = now(), notas = excluded.notas
  returning * into fila;
  return to_jsonb(fila);
end $$;

-- ─── 12. Permisos y envoltorios públicos (invoker) ───────────────────────────
revoke all on function private.caja_resumen_impl(date) from public, anon, authenticated;
revoke all on function private.caja_reporte_impl(date, date, text, text) from public, anon, authenticated;
revoke all on function private.cuentas_estado_impl(date) from public, anon, authenticated;
revoke all on function private.caja_abrir_dia_impl(date, numeric) from public, anon, authenticated;
revoke all on function private.caja_cerrar_dia_impl(date, numeric, text) from public, anon, authenticated;
revoke all on function private.caja_reabrir_dia_impl(date) from public, anon, authenticated;
revoke all on function private.caja_registrar_movimiento_impl(jsonb) from public, anon, authenticated;
revoke all on function private.cuentas_guardar_impl(jsonb) from public, anon, authenticated;
revoke all on function private.cuentas_registrar_traslado_impl(jsonb) from public, anon, authenticated;
revoke all on function private.cuentas_declarar_saldo_impl(text, date, numeric, text) from public, anon, authenticated;
grant execute on function private.caja_resumen_impl(date) to authenticated, service_role;
grant execute on function private.caja_reporte_impl(date, date, text, text) to authenticated, service_role;
grant execute on function private.cuentas_estado_impl(date) to authenticated, service_role;
grant execute on function private.caja_abrir_dia_impl(date, numeric) to authenticated, service_role;
grant execute on function private.caja_cerrar_dia_impl(date, numeric, text) to authenticated, service_role;
grant execute on function private.caja_reabrir_dia_impl(date) to authenticated, service_role;
grant execute on function private.caja_registrar_movimiento_impl(jsonb) to authenticated, service_role;
grant execute on function private.cuentas_guardar_impl(jsonb) to authenticated, service_role;
grant execute on function private.cuentas_registrar_traslado_impl(jsonb) to authenticated, service_role;
grant execute on function private.cuentas_declarar_saldo_impl(text, date, numeric, text) to authenticated, service_role;

create or replace function public.pc_caja_resumen(p_fecha date)
returns table (saldo_inicial numeric, entradas_efectivo numeric, salidas_efectivo numeric,
               teorico_efectivo numeric, entradas_total numeric, salidas_total numeric)
language sql stable set search_path = '' as $$ select * from private.caja_resumen_impl(p_fecha); $$;

create or replace function public.pc_caja_reporte(p_desde date, p_hasta date, p_metodo text default null, p_categoria text default null)
returns jsonb language sql stable set search_path = '' as $$
  select private.caja_reporte_impl(p_desde, p_hasta, p_metodo, p_categoria); $$;

create or replace function public.pc_cuentas_estado(p_fecha date)
returns jsonb language sql stable set search_path = '' as $$ select private.cuentas_estado_impl(p_fecha); $$;

create or replace function public.caja_abrir_dia(p_fecha date, p_saldo_inicial numeric)
returns jsonb language sql set search_path = '' as $$ select private.caja_abrir_dia_impl(p_fecha, p_saldo_inicial); $$;

create or replace function public.caja_cerrar_dia(p_fecha date, p_efectivo_contado numeric, p_notas text default null)
returns jsonb language sql set search_path = '' as $$ select private.caja_cerrar_dia_impl(p_fecha, p_efectivo_contado, p_notas); $$;

create or replace function public.caja_reabrir_dia(p_fecha date)
returns jsonb language sql set search_path = '' as $$ select private.caja_reabrir_dia_impl(p_fecha); $$;

create or replace function public.caja_registrar_movimiento(p_mov jsonb)
returns jsonb language sql set search_path = '' as $$ select private.caja_registrar_movimiento_impl(p_mov); $$;

create or replace function public.cuentas_guardar(p_cuenta jsonb)
returns jsonb language sql set search_path = '' as $$ select private.cuentas_guardar_impl(p_cuenta); $$;

create or replace function public.cuentas_registrar_traslado(p_traslado jsonb)
returns jsonb language sql set search_path = '' as $$ select private.cuentas_registrar_traslado_impl(p_traslado); $$;

create or replace function public.cuentas_declarar_saldo(p_cuenta_id text, p_fecha date, p_saldo numeric, p_notas text default null)
returns jsonb language sql set search_path = '' as $$ select private.cuentas_declarar_saldo_impl(p_cuenta_id, p_fecha, p_saldo, p_notas); $$;

revoke all on function public.pc_caja_resumen(date) from public, anon;
revoke all on function public.pc_caja_reporte(date, date, text, text) from public, anon;
revoke all on function public.pc_cuentas_estado(date) from public, anon;
revoke all on function public.caja_abrir_dia(date, numeric) from public, anon;
revoke all on function public.caja_cerrar_dia(date, numeric, text) from public, anon;
revoke all on function public.caja_reabrir_dia(date) from public, anon;
revoke all on function public.caja_registrar_movimiento(jsonb) from public, anon;
revoke all on function public.cuentas_guardar(jsonb) from public, anon;
revoke all on function public.cuentas_registrar_traslado(jsonb) from public, anon;
revoke all on function public.cuentas_declarar_saldo(text, date, numeric, text) from public, anon;
grant execute on function public.pc_caja_resumen(date) to authenticated;
grant execute on function public.pc_caja_reporte(date, date, text, text) to authenticated;
grant execute on function public.pc_cuentas_estado(date) to authenticated;
grant execute on function public.caja_abrir_dia(date, numeric) to authenticated;
grant execute on function public.caja_cerrar_dia(date, numeric, text) to authenticated;
grant execute on function public.caja_reabrir_dia(date) to authenticated;
grant execute on function public.caja_registrar_movimiento(jsonb) to authenticated;
grant execute on function public.cuentas_guardar(jsonb) to authenticated;
grant execute on function public.cuentas_registrar_traslado(jsonb) to authenticated;
grant execute on function public.cuentas_declarar_saldo(text, date, numeric, text) to authenticated;
