-- Notas de crédito (B04) y reporte 607, por clínica.
--
-- Nota de crédito: una factura con NCF ya entregada al cliente no se borra ni
-- se reescribe. Si hay que devolver todo o parte, se emite un comprobante B04
-- que la modifica (su NCF va en «NCF modificado» del 607). Reglas:
--   * solo sobre facturas con NCF y no anuladas;
--   * la suma de las notas nunca pasa del total de la factura;
--   * el número sale del rango B04 de la clínica, bloqueado en la misma
--     transacción que guarda la nota (como asignar_ncf_factura);
--   * idempotente por p_operacion_id: un doble clic no gasta dos B04.
--
-- 607: la DGII recibe el archivo que genera su propia herramienta de envío
-- (Oficina Virtual). Aquí se arman las filas con las 23 columnas en el orden
-- oficial, listas para pegar en esa herramienta, que es la que valida y produce
-- el TXT. No se genera el TXT aquí: un formato adivinado que la DGII rechace es
-- peor que un paso manual.
--   * Entran las facturas con NCF del mes (no anuladas) y las notas de crédito.
--   * Las facturas anuladas que tenían NCF van al 608: se devuelven aparte.
--   * Las ventas sin NCF no van en el detalle del 607; se devuelve su cantidad
--     y monto para que nadie crea que el 607 es todo lo vendido.

-- ─── 1. El tipo B04 en los rangos ───────────────────────────────────────────
alter table public.pc_ncf_secuencias drop constraint if exists pc_ncf_secuencias_tipo_check;
alter table public.pc_ncf_secuencias add constraint pc_ncf_secuencias_tipo_check
  check (tipo in ('B01', 'B02', 'B04', 'B14', 'B15'));

-- ─── 2. Notas de crédito ────────────────────────────────────────────────────
create table if not exists public.pc_notas_credito (
  negocio_id     uuid not null references public.negocios(id) on delete cascade,
  id             uuid not null default gen_random_uuid(),
  operacion_id   uuid not null,
  ncf            text not null,
  factura_id     text not null,
  ncf_modificado text not null,
  fecha          date not null,
  motivo         text not null,
  subtotal       numeric(14,2) not null check (subtotal >= 0),
  itbis          numeric(14,2) not null check (itbis >= 0),
  total          numeric(14,2) not null check (total > 0),
  rnccliente     text,
  propietario    text,
  emitida_por    uuid,
  emitida_nombre text,
  created_at     timestamptz not null default now(),
  primary key (negocio_id, id),
  unique (negocio_id, ncf),
  unique (negocio_id, operacion_id)
);
create index if not exists pc_notas_credito_factura_idx on public.pc_notas_credito (negocio_id, factura_id);
alter table public.pc_notas_credito enable row level security;
revoke all on public.pc_notas_credito from anon, public, authenticated;
grant select on public.pc_notas_credito to authenticated;

drop policy if exists "notas_credito_lee" on public.pc_notas_credito;
create policy "notas_credito_lee" on public.pc_notas_credito for select to authenticated
  using (negocio_id = (select public.mi_negocio())
         and (select public.tiene_rol(array['admin', 'caja', 'veterinario'])));

-- Los rangos aceptan B04 y el control de solapamiento mira también las notas.
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

  if v_tipo not in ('B01', 'B02', 'B04', 'B14', 'B15') then
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
  ) or exists (
    select 1 from public.pc_notas_credito n
    where v_tipo = 'B04' and n.negocio_id = negocio
      and substr(n.ncf, 4)::bigint >= v_siguiente
      and substr(n.ncf, 4)::bigint <= v_hasta
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

-- ─── 3. Emitir una nota de crédito (solo admin) ─────────────────────────────
create or replace function private.emitir_nota_credito_impl(p_factura_ref text, p_total numeric, p_motivo text, p_operacion_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ctx record; fac public.pc_facturas%rowtype; sec public.pc_ncf_secuencias%rowtype;
        previo public.pc_notas_credito%rowtype; ya numeric; v_total numeric; v_sub numeric; v_itbis numeric;
        comprobante text; fila public.pc_notas_credito%rowtype;
begin
  select * into ctx from private.caja_contexto(array['admin']);
  if p_operacion_id is null then
    raise exception using errcode = '22023', message = 'Falta el identificador de la operación.';
  end if;
  -- Reintento de la misma operación: se devuelve la nota ya emitida.
  select * into previo from public.pc_notas_credito n
   where n.negocio_id = ctx.negocio and n.operacion_id = p_operacion_id;
  if found then return to_jsonb(previo); end if;

  if nullif(btrim(coalesce(p_motivo, '')), '') is null or length(btrim(p_motivo)) < 5 then
    raise exception using errcode = '22023', message = 'Escribe el motivo de la nota de crédito (mínimo 5 letras).';
  end if;

  select f.* into fac from public.pc_facturas f
   where f.negocio_id = ctx.negocio and (f.id = p_factura_ref or f.origen_ref = p_factura_ref)
   order by (f.id = p_factura_ref) desc limit 1
   for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'La factura no existe en esta clínica.';
  end if;
  if fac.ncf is null then
    raise exception using errcode = '22023', message = 'La factura no tiene NCF: una nota de crédito solo modifica comprobantes fiscales.';
  end if;
  if fac.estado = 'anulada' then
    raise exception using errcode = '22023', message = 'La factura está anulada.';
  end if;

  select coalesce(sum(n.total), 0) into ya from public.pc_notas_credito n
   where n.negocio_id = ctx.negocio and n.factura_id = fac.id;
  v_total := round(coalesce(p_total, fac.total - ya), 2);
  if v_total <= 0 then
    raise exception using errcode = '22023', message = 'El monto de la nota debe ser mayor que cero.';
  end if;
  if v_total > fac.total - ya + 0.004 then
    raise exception using errcode = '22023',
      message = format('La nota no puede pasar de lo que queda por acreditar en la factura: RD$ %s.', to_char(fac.total - ya, 'FM999G999G990D00'));
  end if;
  -- El ITBIS se acredita en la misma proporción en que se facturó.
  if coalesce(fac.itbisamt, 0) > 0 and fac.total > 0 then
    v_itbis := round(v_total * fac.itbisamt / fac.total, 2);
  else
    v_itbis := 0;
  end if;
  v_sub := v_total - v_itbis;

  select s.* into sec from public.pc_ncf_secuencias s
   where s.negocio_id = ctx.negocio and s.tipo = 'B04'
   for update;
  if not found then
    raise exception using errcode = 'P0002',
      message = 'No hay un rango de NCF B04 (notas de crédito) registrado. El administrador lo carga en Configuración con los números autorizados por la DGII.';
  end if;
  if not sec.activa then
    raise exception using errcode = '22023', message = 'El rango de NCF B04 está desactivado.';
  end if;
  if sec.siguiente > sec.hasta then
    raise exception using errcode = '22023', message = 'Se acabaron los NCF B04. Hay que solicitar un rango nuevo a la DGII.';
  end if;
  if sec.vence is not null and sec.vence < current_date then
    raise exception using errcode = '22023',
      message = format('La autorización de los NCF B04 venció el %s.', to_char(sec.vence, 'DD/MM/YYYY'));
  end if;
  comprobante := 'B04' || lpad(sec.siguiente::text, 8, '0');
  update public.pc_ncf_secuencias set siguiente = siguiente + 1, actualizado = now(), actualizado_por = (select auth.uid())
   where negocio_id = ctx.negocio and tipo = 'B04';

  insert into public.pc_notas_credito (negocio_id, operacion_id, ncf, factura_id, ncf_modificado, fecha, motivo,
                                       subtotal, itbis, total, rnccliente, propietario, emitida_por, emitida_nombre)
  values (ctx.negocio, p_operacion_id, comprobante, fac.id, fac.ncf, current_date, left(btrim(p_motivo), 500),
          v_sub, v_itbis, v_total, fac.rnccliente, fac.propietario, (select auth.uid()), ctx.nombre)
  returning * into fila;
  return to_jsonb(fila);
exception
  when numeric_value_out_of_range then
    raise exception using errcode = '22023', message = 'El monto no es válido.';
end $$;

-- ─── 4. Reporte 607 de un mes (solo admin) ──────────────────────────────────
create or replace function private.reporte_607_impl(p_periodo text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare ctx record; v_desde date; v_hasta date; v jsonb;
begin
  select * into ctx from private.caja_contexto(array['admin']);
  if p_periodo is null or p_periodo !~ '^\d{6}$' then
    raise exception using errcode = '22023', message = 'El periodo va como AAAAMM, por ejemplo 202610.';
  end if;
  v_desde := to_date(p_periodo || '01', 'YYYYMMDD');
  v_hasta := (v_desde + interval '1 month' - interval '1 day')::date;

  with fac as (
    select f.*, public.pc_metodo_pago(coalesce(f.metodopago, '')) as metodo
      from public.pc_facturas f
     where f.negocio_id = ctx.negocio and f.ncf is not null
       and public.pc_fecha(f.fecha) between v_desde and v_hasta
  ), filas as (
    -- Una fila por comprobante, con las columnas del formato 607 en su orden.
    select public.pc_fecha(f.fecha) as orden_fecha, f.ncf as orden_ncf, jsonb_build_object(
      'rnc', coalesce(f.rnccliente, ''),
      'tipo_id', case length(coalesce(f.rnccliente, '')) when 9 then '1' when 11 then '2' else '' end,
      'ncf', f.ncf, 'ncf_modificado', '', 'tipo_ingreso', '01',
      'fecha', to_char(public.pc_fecha(f.fecha), 'YYYYMMDD'), 'fecha_retencion', '',
      'monto', coalesce(f.subtotal, 0), 'itbis', coalesce(f.itbisamt, 0),
      'itbis_retenido', 0, 'itbis_percibido', 0, 'isr_retenido', 0, 'isr_percibido', 0,
      'isc', 0, 'otros_impuestos', 0, 'propina', 0,
      'efectivo',      case when f.estado = 'pendiente' then 0 when f.metodo = 'EFECTIVO' then f.total else 0 end,
      'cheque_transf', case when f.estado = 'pendiente' then 0 when f.metodo in ('TRANSFERENCIA', 'CHEQUE') then f.total else 0 end,
      'tarjeta',       case when f.estado = 'pendiente' then 0 when f.metodo = 'TARJETA' then f.total else 0 end,
      'credito',       case when f.estado = 'pendiente' then f.total else 0 end,
      'bonos', 0, 'permuta', 0,
      'otras',         case when f.estado = 'pendiente' then 0 when f.metodo in ('EFECTIVO', 'TRANSFERENCIA', 'CHEQUE', 'TARJETA') then 0 else f.total end,
      'aviso', case when f.estado <> 'pendiente' and f.metodo not in ('EFECTIVO', 'TRANSFERENCIA', 'CHEQUE', 'TARJETA')
                    then 'Forma de pago «' || coalesce(f.metodopago, '') || '» no reconocida: va en «Otras formas». Revísala.' end,
      'propietario', coalesce(f.propietario, ''), 'factura_numero', f.numero
    ) as fila
      from fac f where f.estado <> 'anulada'
    union all
    select n.fecha, n.ncf, jsonb_build_object(
      'rnc', coalesce(n.rnccliente, ''),
      'tipo_id', case length(coalesce(n.rnccliente, '')) when 9 then '1' when 11 then '2' else '' end,
      'ncf', n.ncf, 'ncf_modificado', n.ncf_modificado, 'tipo_ingreso', '01',
      'fecha', to_char(n.fecha, 'YYYYMMDD'), 'fecha_retencion', '',
      'monto', n.subtotal, 'itbis', n.itbis,
      'itbis_retenido', 0, 'itbis_percibido', 0, 'isr_retenido', 0, 'isr_percibido', 0,
      'isc', 0, 'otros_impuestos', 0, 'propina', 0,
      'efectivo', 0, 'cheque_transf', 0, 'tarjeta', 0, 'credito', 0, 'bonos', 0, 'permuta', 0, 'otras', 0,
      'aviso', null, 'propietario', coalesce(n.propietario, ''), 'motivo', n.motivo
    )
      from public.pc_notas_credito n
     where n.negocio_id = ctx.negocio and n.fecha between v_desde and v_hasta
  )
  select jsonb_build_object(
    'periodo', p_periodo, 'desde', v_desde, 'hasta', v_hasta,
    'rnc_emisor', coalesce((select regexp_replace(coalesce(c.rnc, ''), '[^0-9]', '', 'g') from public.negocios c where c.id = ctx.negocio), ''),
    'filas', coalesce((select jsonb_agg(fila order by orden_fecha, orden_ncf) from filas), '[]'::jsonb),
    'anuladas_608', coalesce((select jsonb_agg(jsonb_build_object('ncf', f.ncf, 'fecha', to_char(public.pc_fecha(f.fecha), 'YYYYMMDD'),
                                                                  'factura_numero', f.numero, 'total', f.total) order by f.ncf)
                                from fac f where f.estado = 'anulada'), '[]'::jsonb),
    'sin_ncf', (select jsonb_build_object('cantidad', count(*), 'total', coalesce(sum(f.total), 0))
                  from public.pc_facturas f
                 where f.negocio_id = ctx.negocio and f.ncf is null and f.estado <> 'anulada'
                   and public.pc_fecha(f.fecha) between v_desde and v_hasta)
  ) into v;
  return v;
end $$;

-- ─── 5. Permisos y envoltorios ──────────────────────────────────────────────
revoke all on function private.emitir_nota_credito_impl(text, numeric, text, uuid) from public, anon, authenticated;
revoke all on function private.reporte_607_impl(text) from public, anon, authenticated;
grant execute on function private.emitir_nota_credito_impl(text, numeric, text, uuid) to authenticated, service_role;
grant execute on function private.reporte_607_impl(text) to authenticated, service_role;

create or replace function public.emitir_nota_credito(p_factura_ref text, p_total numeric, p_motivo text, p_operacion_id uuid)
returns jsonb language sql set search_path = '' as $$
  select private.emitir_nota_credito_impl(p_factura_ref, p_total, p_motivo, p_operacion_id); $$;
create or replace function public.reporte_607(p_periodo text)
returns jsonb language sql stable set search_path = '' as $$ select private.reporte_607_impl(p_periodo); $$;

revoke all on function public.emitir_nota_credito(text, numeric, text, uuid) from public, anon;
revoke all on function public.reporte_607(text) from public, anon;
grant execute on function public.emitir_nota_credito(text, numeric, text, uuid) to authenticated;
grant execute on function public.reporte_607(text) to authenticated;
