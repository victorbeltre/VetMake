-- Anulación de comprobantes fiscales y reporte 608, por clínica.
--
-- Antes, «borrar» una factura la marcaba anulada con un motivo libre, aunque
-- tuviera NCF. Ante la DGII eso no basta:
--   * si el cliente YA recibió la factura y la operación se revierte, lo que
--     corresponde es una nota de crédito (B04), no anularla;
--   * si el comprobante no llegó a entregarse o salió con errores, se anula y
--     se reporta en el 608 con su tipo de anulación (códigos 01 a 10).
--
-- Por eso:
--   * private.anular_factura (de Codex) rechaza ahora las facturas con NCF:
--     esas pasan por anular_factura_fiscal, que exige el código del 608;
--   * una factura que ya tiene nota de crédito no se anula: ya fue modificada;
--   * anular NO borra las ventas: la venta ocurrió. Si el problema fue de
--     impresión o de datos, la misma venta puede volver a facturarse con un NCF
--     nuevo. Para eso la factura anulada suelta su origen_ref (lo guarda en
--     origen_ref_anulado) y la factura armada desde ventas vuelve a aparecer.
--
-- El 608 se arma como el 607: columnas en el orden oficial para copiarlas en
-- la herramienta de envío de la DGII. Entran los comprobantes anulados en el
-- mes (por la fecha de la anulación), con la fecha del comprobante.

alter table public.pc_facturas add column if not exists anulacion_608      text;
alter table public.pc_facturas add column if not exists anulada_en         timestamptz;
alter table public.pc_facturas add column if not exists origen_ref_anulado text;
alter table public.pc_facturas drop constraint if exists pc_facturas_anulacion_608_check;
alter table public.pc_facturas add constraint pc_facturas_anulacion_608_check
  check (anulacion_608 is null or anulacion_608 in ('01','02','03','04','05','06','07','08','09','10'));

-- ─── 1. La anulación vieja ya no toca comprobantes fiscales ─────────────────
create or replace function private.anular_factura(factura_id text, motivo text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  usuario uuid := (select auth.uid());
  negocio uuid;
  rol text;
  motivo_limpio text := btrim(coalesce(motivo, ''));
  fila public.pc_facturas%rowtype;
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Se requiere una sesión autenticada.';
  end if;

  if nullif(btrim(coalesce(factura_id, '')), '') is null then
    raise exception using errcode = '22023', message = 'Falta identificar la factura.';
  end if;

  if char_length(motivo_limpio) < 5 or char_length(motivo_limpio) > 500 then
    raise exception using errcode = '22023', message = 'Indica un motivo de anulación de 5 a 500 caracteres.';
  end if;

  select membresia.negocio_id, membresia.rol
  into negocio, rol
  from public.usuarios_negocio as membresia
  join public.negocios as clinica on clinica.id = membresia.negocio_id
  where membresia.usuario_id = usuario
    and membresia.activo = true
    and clinica.activo = true;

  if negocio is null or rol <> 'admin' then
    raise exception using errcode = '42501', message = 'Solo un administrador puede anular facturas.';
  end if;

  select factura_actual.*
  into fila
  from public.pc_facturas as factura_actual
  where factura_actual.id = factura_id
    and factura_actual.negocio_id = negocio
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'La factura no existe en este negocio.';
  end if;

  if fila.estado = 'anulada' then
    return to_jsonb(fila);
  end if;

  -- Un comprobante fiscal se anula con su código del 608 (o se modifica con una
  -- nota de crédito si ya se entregó): nunca por esta vía.
  if fila.ncf is not null then
    raise exception using errcode = '22023',
      message = 'Esta factura tiene NCF: anúlala indicando el tipo de anulación del 608, o emite una nota de crédito si el cliente ya la recibió.';
  end if;

  update public.pc_facturas
  set estado = 'anulada',
      anulada_en = now(),
      notas = left(concat_ws(E'\n', nullif(notas, ''), '[ANULADA ' || current_date::text || '] ' || motivo_limpio), 2000)
  where id = factura_id
    and negocio_id = negocio
  returning * into fila;

  return to_jsonb(fila);
end;
$$;

-- ─── 2. Anulación fiscal (solo admin) ───────────────────────────────────────
create or replace function private.anular_factura_fiscal_impl(p_factura_ref text, p_tipo text, p_motivo text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ctx record; fila public.pc_facturas%rowtype; motivo_limpio text := btrim(coalesce(p_motivo, ''));
begin
  select * into ctx from private.caja_contexto(array['admin']);
  if p_tipo is null or p_tipo not in ('01','02','03','04','05','06','07','08','09','10') then
    raise exception using errcode = '22023', message = 'Elige el tipo de anulación del 608.';
  end if;
  if char_length(motivo_limpio) < 5 or char_length(motivo_limpio) > 500 then
    raise exception using errcode = '22023', message = 'Indica un motivo de anulación de 5 a 500 caracteres.';
  end if;

  select f.* into fila from public.pc_facturas f
   where f.negocio_id = ctx.negocio and (f.id = p_factura_ref or f.origen_ref = p_factura_ref)
   order by (f.id = p_factura_ref) desc limit 1
   for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'La factura no existe en esta clínica.';
  end if;
  if fila.ncf is null then
    raise exception using errcode = '22023', message = 'La factura no tiene NCF: se anula por la vía normal.';
  end if;
  if fila.estado = 'anulada' then
    return to_jsonb(fila);
  end if;
  if exists (select 1 from public.pc_notas_credito n where n.negocio_id = ctx.negocio and n.factura_id = fila.id) then
    raise exception using errcode = '22023',
      message = 'Esta factura ya tiene nota de crédito: fue modificada y no se puede anular. Si falta acreditar algo, emite otra nota.';
  end if;

  update public.pc_facturas
     set estado = 'anulada', anulacion_608 = p_tipo, anulada_en = now(),
         origen_ref_anulado = origen_ref, origen_ref = null,
         notas = left(concat_ws(E'\n', nullif(notas, ''),
                   '[ANULADA ' || current_date::text || ' · 608 tipo ' || p_tipo || '] ' || motivo_limpio), 2000)
   where id = fila.id and negocio_id = ctx.negocio
  returning * into fila;
  return to_jsonb(fila);
end $$;

-- ─── 3. Reporte 608 de un mes (solo admin) ──────────────────────────────────
create or replace function private.reporte_608_impl(p_periodo text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare ctx record; v_desde date; v_hasta date; v jsonb;
begin
  select * into ctx from private.caja_contexto(array['admin']);
  if p_periodo is null or p_periodo !~ '^\d{6}$' then
    raise exception using errcode = '22023', message = 'El periodo va como AAAAMM, por ejemplo 202610.';
  end if;
  v_desde := to_date(p_periodo || '01', 'YYYYMMDD');
  v_hasta := (v_desde + interval '1 month' - interval '1 day')::date;

  select jsonb_build_object(
    'periodo', p_periodo,
    'rnc_emisor', coalesce((select regexp_replace(coalesce(c.rnc, ''), '[^0-9]', '', 'g') from public.negocios c where c.id = ctx.negocio), ''),
    'filas', coalesce(jsonb_agg(jsonb_build_object(
        'ncf', f.ncf,
        'fecha', to_char(public.pc_fecha(f.fecha), 'YYYYMMDD'),
        'tipo_anulacion', coalesce(f.anulacion_608, ''),
        'factura_numero', f.numero,
        'aviso', case when f.anulacion_608 is null then 'Anulada antes de pedir el tipo de anulación: complétalo en la herramienta de la DGII.' end
      ) order by f.ncf), '[]'::jsonb)
  ) into v
  from public.pc_facturas f
  where f.negocio_id = ctx.negocio and f.ncf is not null and f.estado = 'anulada'
    and (coalesce(f.anulada_en, f.actualizada_at) at time zone 'America/Santo_Domingo')::date between v_desde and v_hasta;
  return v;
end $$;

-- ─── 4. Permisos y envoltorios ──────────────────────────────────────────────
revoke all on function private.anular_factura_fiscal_impl(text, text, text) from public, anon, authenticated;
revoke all on function private.reporte_608_impl(text) from public, anon, authenticated;
grant execute on function private.anular_factura_fiscal_impl(text, text, text) to authenticated, service_role;
grant execute on function private.reporte_608_impl(text) to authenticated, service_role;

create or replace function public.anular_factura_fiscal(p_factura_ref text, p_tipo text, p_motivo text)
returns jsonb language sql set search_path = '' as $$
  select private.anular_factura_fiscal_impl(p_factura_ref, p_tipo, p_motivo); $$;
create or replace function public.reporte_608(p_periodo text)
returns jsonb language sql stable set search_path = '' as $$ select private.reporte_608_impl(p_periodo); $$;

revoke all on function public.anular_factura_fiscal(text, text, text) from public, anon;
revoke all on function public.reporte_608(text) from public, anon;
grant execute on function public.anular_factura_fiscal(text, text, text) to authenticated;
grant execute on function public.reporte_608(text) to authenticated;
