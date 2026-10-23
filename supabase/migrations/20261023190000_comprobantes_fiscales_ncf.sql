-- Comprobantes fiscales (NCF) por clínica.
--
-- Viene de PetColinas (M16), adaptado a multiempresa y al modelo de VetMake
-- (escrituras solo por RPC). Sin NCF la factura no es un comprobante: el cliente
-- empresa no puede deducir el gasto y el 607 hay que armarlo a mano.
--
-- Diferencias con PetColinas, a propósito:
--   * Cada clínica tiene SUS rangos autorizados por la DGII: la clave de
--     pc_ncf_secuencias es (negocio_id, tipo) y el NCF es único por clínica.
--   * El número se toma y se graba en la factura en UNA transacción
--     (asignar_ncf_factura). En PetColinas se pedía el número y después se
--     guardaba la factura aparte: si lo segundo fallaba quedaba un hueco en la
--     secuencia imposible de justificar ante la DGII.
--   * Es idempotente: si la factura ya tiene NCF se devuelve el mismo; un
--     reintento (doble clic, red lenta) nunca consume un segundo número.
--   * Las facturas que la app arma a partir de las ventas no tienen fila propia
--     en pc_facturas. Al asignarles NCF se crean con private.crear_factura y se
--     anota su id de origen en origen_ref (único por clínica), así un reintento
--     encuentra la misma fila en vez de crear otra.
--   * El NCF no se puede cambiar después: actualizar_factura no toca estas
--     columnas y authenticated no tiene DML directo sobre pc_facturas.
--
-- No se siembra ningún rango: cargar números que la DGII no autorizó sería
-- emitir comprobantes falsos. Cada clínica registra el suyo desde la app.

-- ─── 1. Rangos autorizados ──────────────────────────────────────────────────
create table if not exists public.pc_ncf_secuencias (
  negocio_id      uuid not null references public.negocios(id) on delete cascade,
  tipo            text not null check (tipo in ('B01', 'B02', 'B14', 'B15')),
  desde           bigint not null check (desde > 0),
  hasta           bigint not null check (hasta <= 99999999),
  siguiente       bigint not null,
  vence           date,
  activa          boolean not null default true,
  actualizado     timestamptz not null default now(),
  actualizado_por uuid,
  primary key (negocio_id, tipo),
  check (hasta >= desde),
  check (siguiente >= desde)
);
alter table public.pc_ncf_secuencias enable row level security;
revoke all on public.pc_ncf_secuencias from anon, public, authenticated;
grant select on public.pc_ncf_secuencias to authenticated;

-- Todo el personal que factura lo lee (para ver cuántos quedan); nadie escribe
-- directo: los rangos entran por guardar_secuencia_ncf (solo admin).
drop policy if exists "ncf_personal_lee" on public.pc_ncf_secuencias;
create policy "ncf_personal_lee" on public.pc_ncf_secuencias
  for select to authenticated
  using (negocio_id = (select mi_negocio())
         and (select tiene_rol(array['admin', 'caja', 'veterinario'])));

-- ─── 2. El comprobante en la factura ────────────────────────────────────────
alter table public.pc_facturas add column if not exists ncf        text;
alter table public.pc_facturas add column if not exists ncftipo    text;
alter table public.pc_facturas add column if not exists rnccliente text;
alter table public.pc_facturas add column if not exists origen_ref text;

create unique index if not exists pc_facturas_negocio_ncf_uidx
  on public.pc_facturas (negocio_id, ncf) where ncf is not null;
create unique index if not exists pc_facturas_negocio_origen_uidx
  on public.pc_facturas (negocio_id, origen_ref) where origen_ref is not null;

-- ─── 3. Asignar el NCF a una factura ────────────────────────────────────────
create or replace function private.asignar_ncf_factura_impl(p_factura jsonb, p_tipo text, p_rnc_cliente text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  usuario uuid := (select auth.uid());
  negocio uuid;
  rol text;
  ref text := nullif(btrim(coalesce(p_factura ->> 'id', '')), '');
  rnc text := regexp_replace(coalesce(p_rnc_cliente, ''), '[^0-9]', '', 'g');
  creada jsonb;
  fila public.pc_facturas%rowtype;
  sec public.pc_ncf_secuencias%rowtype;
  comprobante text;
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Se requiere una sesión autenticada.';
  end if;

  select membresia.negocio_id, membresia.rol
  into negocio, rol
  from public.usuarios_negocio as membresia
  join public.negocios as clinica on clinica.id = membresia.negocio_id
  where membresia.usuario_id = usuario
    and membresia.activo = true
    and clinica.activo = true;

  if negocio is null or rol not in ('admin', 'caja', 'veterinario') then
    raise exception using errcode = '42501', message = 'Tu rol no puede emitir comprobantes fiscales.';
  end if;

  if p_tipo is null or p_tipo not in ('B01', 'B02', 'B14', 'B15') then
    raise exception using errcode = '22023', message = 'Tipo de comprobante no válido.';
  end if;
  -- El crédito fiscal existe para que el cliente deduzca: sin su RNC (9 dígitos)
  -- o cédula (11) la DGII devuelve la línea del 607.
  if p_tipo = 'B01' and length(rnc) not in (9, 11) then
    raise exception using errcode = '22023',
      message = 'El Crédito Fiscal (B01) exige el RNC (9 dígitos) o la cédula (11) del cliente.';
  end if;
  if ref is null then
    raise exception using errcode = '22023', message = 'Falta identificar la factura.';
  end if;

  select f.* into fila
  from public.pc_facturas as f
  where f.negocio_id = negocio and (f.id = ref or f.origen_ref = ref)
  order by (f.id = ref) desc
  limit 1
  for update;

  if not found then
    -- Factura armada desde las ventas: se crea con la misma validación de
    -- siempre y se anota de dónde salió.
    creada := private.crear_factura(p_factura - 'id' - 'numero');
    update public.pc_facturas
       set origen_ref = ref
     where id = creada ->> 'id' and negocio_id = negocio
    returning * into fila;
  end if;

  if fila.estado = 'anulada' then
    raise exception using errcode = '22023', message = 'Una factura anulada no recibe comprobante fiscal.';
  end if;

  -- Ya tenía comprobante: se devuelve el mismo, nunca se consume otro.
  if fila.ncf is not null then
    return to_jsonb(fila);
  end if;

  -- Bloquea el rango de esta clínica: dos personas facturando a la vez reciben
  -- números distintos.
  select s.* into sec
  from public.pc_ncf_secuencias as s
  where s.negocio_id = negocio and s.tipo = p_tipo
  for update;

  if not found then
    raise exception using errcode = 'P0002',
      message = format('No hay un rango de NCF %s registrado. El administrador lo carga en Configuración con los números autorizados por la DGII.', p_tipo);
  end if;
  if not sec.activa then
    raise exception using errcode = '22023', message = format('El rango de NCF %s está desactivado.', p_tipo);
  end if;
  if sec.siguiente > sec.hasta then
    raise exception using errcode = '22023',
      message = format('Se acabaron los NCF %s. Hay que solicitar un rango nuevo a la DGII.', p_tipo);
  end if;
  if sec.vence is not null and sec.vence < current_date then
    raise exception using errcode = '22023',
      message = format('La autorización de los NCF %s venció el %s.', p_tipo, to_char(sec.vence, 'DD/MM/YYYY'));
  end if;

  comprobante := p_tipo || lpad(sec.siguiente::text, 8, '0');

  update public.pc_ncf_secuencias
     set siguiente = siguiente + 1, actualizado = now(), actualizado_por = usuario
   where negocio_id = negocio and tipo = p_tipo;

  update public.pc_facturas
     set ncf = comprobante,
         ncftipo = p_tipo,
         rnccliente = case when p_tipo = 'B01' then rnc else nullif(rnc, '') end
   where id = fila.id and negocio_id = negocio
  returning * into fila;

  return to_jsonb(fila);
end;
$$;

-- ─── 4. Registrar o actualizar un rango (solo admin) ────────────────────────
create or replace function private.guardar_secuencia_ncf_impl(p_secuencia jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  usuario uuid := (select auth.uid());
  negocio uuid;
  rol text;
  v_tipo text := upper(btrim(coalesce(p_secuencia ->> 'tipo', '')));
  v_desde bigint;
  v_hasta bigint;
  v_vence date;
  v_activa boolean := coalesce((p_secuencia ->> 'activa')::boolean, true);
  actual public.pc_ncf_secuencias%rowtype;
  v_siguiente bigint;
  fila public.pc_ncf_secuencias%rowtype;
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Se requiere una sesión autenticada.';
  end if;

  select membresia.negocio_id, membresia.rol
  into negocio, rol
  from public.usuarios_negocio as membresia
  join public.negocios as clinica on clinica.id = membresia.negocio_id
  where membresia.usuario_id = usuario
    and membresia.activo = true
    and clinica.activo = true;

  if negocio is null or rol <> 'admin' then
    raise exception using errcode = '42501', message = 'Solo un administrador registra rangos de NCF.';
  end if;

  if v_tipo not in ('B01', 'B02', 'B14', 'B15') then
    raise exception using errcode = '22023', message = 'Tipo de comprobante no válido.';
  end if;

  v_desde := (p_secuencia ->> 'desde')::bigint;
  v_hasta := (p_secuencia ->> 'hasta')::bigint;
  v_vence := nullif(p_secuencia ->> 'vence', '')::date;

  if v_desde is null or v_hasta is null or v_desde < 1 or v_hasta > 99999999 or v_hasta < v_desde then
    raise exception using errcode = '22023', message = 'El rango no es válido: «desde» y «hasta» van de 1 a 99999999 y «hasta» no puede ser menor.';
  end if;

  select s.* into actual
  from public.pc_ncf_secuencias as s
  where s.negocio_id = negocio and s.tipo = v_tipo
  for update;

  -- Un rango nuevo empieza en «desde». Si el rango cargado incluye números que
  -- ya se emitieron, se sigue donde se quedó: jamás se repite un NCF.
  v_siguiente := v_desde;
  if found and v_desde < actual.siguiente then
    v_siguiente := least(actual.siguiente, v_hasta + 1);
  end if;
  if exists (
    select 1 from public.pc_facturas f
    where f.negocio_id = negocio and f.ncftipo = v_tipo
      and substr(f.ncf, 4)::bigint >= v_siguiente
      and substr(f.ncf, 4)::bigint <= v_hasta
  ) then
    raise exception using errcode = '23505',
      message = 'Ese rango incluye NCF que ya se emitieron en esta clínica. Revisa los números autorizados por la DGII.';
  end if;

  insert into public.pc_ncf_secuencias as s
    (negocio_id, tipo, desde, hasta, siguiente, vence, activa, actualizado, actualizado_por)
  values (negocio, v_tipo, v_desde, v_hasta, v_siguiente, v_vence, v_activa, now(), usuario)
  on conflict (negocio_id, tipo) do update
    set desde = excluded.desde, hasta = excluded.hasta, siguiente = excluded.siguiente,
        vence = excluded.vence, activa = excluded.activa,
        actualizado = excluded.actualizado, actualizado_por = excluded.actualizado_por
  returning * into fila;

  return to_jsonb(fila);
exception
  when invalid_text_representation or numeric_value_out_of_range or invalid_datetime_format then
    raise exception using errcode = '22023', message = 'El rango contiene números o una fecha inválidos.';
end;
$$;

revoke all on function private.asignar_ncf_factura_impl(jsonb, text, text) from public, anon, authenticated, service_role;
revoke all on function private.guardar_secuencia_ncf_impl(jsonb) from public, anon, authenticated, service_role;
grant execute on function private.asignar_ncf_factura_impl(jsonb, text, text) to authenticated, service_role;
grant execute on function private.guardar_secuencia_ncf_impl(jsonb) to authenticated, service_role;

-- ─── 5. Envoltorios públicos (invoker) ──────────────────────────────────────
create or replace function public.asignar_ncf_factura(p_factura jsonb, p_tipo text, p_rnc_cliente text default null)
returns jsonb
language sql
set search_path = ''
as $$
  select private.asignar_ncf_factura_impl(p_factura, p_tipo, p_rnc_cliente);
$$;

create or replace function public.guardar_secuencia_ncf(p_secuencia jsonb)
returns jsonb
language sql
set search_path = ''
as $$
  select private.guardar_secuencia_ncf_impl(p_secuencia);
$$;

revoke all on function public.asignar_ncf_factura(jsonb, text, text) from public, anon;
revoke all on function public.guardar_secuencia_ncf(jsonb) from public, anon;
grant execute on function public.asignar_ncf_factura(jsonb, text, text) to authenticated;
grant execute on function public.guardar_secuencia_ncf(jsonb) to authenticated;

comment on function public.asignar_ncf_factura(jsonb, text, text) is
  'Toma el siguiente NCF del rango de la clínica y lo graba en la factura en una sola transacción; idempotente.';
comment on function public.guardar_secuencia_ncf(jsonb) is
  'Registra o actualiza el rango de NCF autorizado por la DGII para la clínica (solo admin).';
