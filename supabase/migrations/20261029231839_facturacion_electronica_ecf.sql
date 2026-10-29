-- VetMake · Facturación electrónica (e-CF) — Ley 32-23
--
-- Pequeños, micro y no clasificados deben emitir e-CF desde el 15 nov 2026;
-- desde entonces el NCF tipo B queda para contingencias.
--
-- Decisión de Victor (29 oct 2026): VetMake NO firma ni habla con la DGII.
-- Cada factura se manda por API a un Proveedor de Servicios de Facturación
-- Electrónica (PSFE) autorizado, que firma con el certificado de la clínica y
-- la envía a la DGII. Primer proveedor: eCF MSeller (API JSON con la misma
-- estructura del XML oficial de la DGII, modelo multi-empresa). Respaldo: la
-- clínica emite en el Facturador Gratuito de la DGII y anota aquí el e-NCF.
--
-- Qué hace esta migración:
--   1. Rangos e-NCF por clínica: E31 (crédito fiscal), E32 (consumo),
--      E34 (nota de crédito). 13 caracteres: E + tipo (2) + 10 dígitos.
--   2. Columnas de estado e-CF en facturas y notas de crédito.
--   3. asignar_ncf_factura acepta E31/E32; emitir_nota_credito usa E34 cuando
--      la factura es electrónica.
--   4. registrar_ecf_manual: anotar un e-CF emitido en el Facturador Gratuito.
--   5. Una factura con e-CF ya enviado no cambia montos, líneas ni fecha
--      (se corrige con nota de crédito).
--   6. Configuración y credenciales del proveedor por clínica. Contraseña y
--      API key van en Supabase Vault; la app nunca las vuelve a leer.
--   7. Funciones solo-servidor para la Edge Function vetmake-ecf: contexto,
--      documento JSON DGII, tokens y resultado del envío.

-- ─── 1. Rangos e-NCF ────────────────────────────────────────────────────────
alter table public.pc_ncf_secuencias drop constraint if exists pc_ncf_secuencias_tipo_check;
alter table public.pc_ncf_secuencias add constraint pc_ncf_secuencias_tipo_check
  check (tipo in ('B01', 'B02', 'B04', 'B14', 'B15', 'E31', 'E32', 'E34'));
alter table public.pc_ncf_secuencias drop constraint if exists pc_ncf_secuencias_hasta_check;
alter table public.pc_ncf_secuencias add constraint pc_ncf_secuencias_hasta_check
  check (hasta <= case when tipo like 'E%' then 9999999999 else 99999999 end);

create or replace function private.ncf_formatear(p_tipo text, p_numero bigint)
returns text language sql immutable set search_path = '' as $$
  select p_tipo || lpad(p_numero::text, case when p_tipo like 'E%' then 10 else 8 end, '0');
$$;
revoke all on function private.ncf_formatear(text, bigint) from public, anon, authenticated;

-- ─── 2. Estado e-CF en facturas y notas ─────────────────────────────────────
alter table public.negocios add column if not exists razon_social text;
comment on column public.negocios.razon_social is
  'Nombre o razón social tal como está registrado en la DGII (va en el e-CF como RazonSocialEmisor).';

do $$
declare t text;
begin
  foreach t in array array['pc_facturas', 'pc_notas_credito'] loop
    execute format('alter table public.%I add column if not exists ecf_estado text', t);
    execute format('alter table public.%I add column if not exists ecf_origen text', t);
    execute format('alter table public.%I add column if not exists ecf_codigo_seguridad text', t);
    execute format('alter table public.%I add column if not exists ecf_qr_url text', t);
    execute format('alter table public.%I add column if not exists ecf_fecha_firma text', t);
    execute format('alter table public.%I add column if not exists ecf_track_id text', t);
    execute format('alter table public.%I add column if not exists ecf_mensaje text', t);
    execute format('alter table public.%I add column if not exists ecf_intentos integer not null default 0', t);
    execute format('alter table public.%I add column if not exists ecf_actualizado timestamptz', t);
    execute format('alter table public.%I drop constraint if exists %I', t, t || '_ecf_estado_check');
    execute format($c$alter table public.%I add constraint %I check (ecf_estado is null or ecf_estado in
      ('por_enviar', 'en_proceso', 'aceptado', 'aceptado_condicional', 'rechazado', 'manual'))$c$, t, t || '_ecf_estado_check');
    execute format('alter table public.%I drop constraint if exists %I', t, t || '_ecf_origen_check');
    execute format($c$alter table public.%I add constraint %I check (ecf_origen is null or ecf_origen in
      ('proveedor', 'facturador_gratuito'))$c$, t, t || '_ecf_origen_check');
  end loop;
end $$;

create index if not exists pc_facturas_ecf_pendientes_idx
  on public.pc_facturas (negocio_id, ecf_estado) where ecf_estado in ('por_enviar', 'en_proceso');

-- ─── 3. Configuración y credenciales del proveedor ──────────────────────────
create table if not exists public.vetmake_ecf_config (
  negocio_id      uuid primary key references public.negocios(id) on delete cascade,
  proveedor       text not null default 'mseller' check (proveedor in ('mseller')),
  ambiente        text not null default 'TesteCF' check (ambiente in ('TesteCF', 'CerteCF', 'eCF')),
  activo          boolean not null default false,
  email           text,
  password_id     uuid,
  api_key_id      uuid,
  id_token        text,
  refresh_token   text,
  token_sub       text,
  token_expira    timestamptz,
  ultima_prueba   timestamptz,
  ultima_prueba_ok boolean,
  actualizado     timestamptz not null default now()
);
comment on table public.vetmake_ecf_config is
  'Conexión de cada clínica con su PSFE. password_id y api_key_id apuntan a Supabase Vault. Solo service_role lee esta tabla.';
alter table public.vetmake_ecf_config enable row level security;
revoke all on public.vetmake_ecf_config from public, anon, authenticated;

-- Vista segura para la app (sin secretos ni tokens).
create or replace function private.ecf_config_impl()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_negocio uuid := public.mi_negocio(); c public.vetmake_ecf_config; n public.negocios;
begin
  if v_negocio is null then
    raise exception using errcode = '42501', message = 'No autorizado.';
  end if;
  select * into c from public.vetmake_ecf_config where negocio_id = v_negocio;
  select * into n from public.negocios where id = v_negocio;
  return jsonb_build_object(
    'proveedor', coalesce(c.proveedor, 'mseller'),
    'ambiente', coalesce(c.ambiente, 'TesteCF'),
    'activo', coalesce(c.activo, false),
    'email', c.email,
    'tiene_password', c.password_id is not null,
    'tiene_api_key', c.api_key_id is not null,
    'ultima_prueba', c.ultima_prueba,
    'ultima_prueba_ok', c.ultima_prueba_ok,
    'rnc', regexp_replace(coalesce(n.rnc, ''), '[^0-9]', '', 'g'),
    'razon_social', coalesce(nullif(btrim(n.razon_social), ''), n.nombre),
    'direccion', n.direccion,
    'secuencias', (select coalesce(jsonb_agg(jsonb_build_object('tipo', s.tipo, 'desde', s.desde, 'hasta', s.hasta,
                     'siguiente', s.siguiente, 'vence', s.vence, 'activa', s.activa) order by s.tipo), '[]'::jsonb)
                     from public.pc_ncf_secuencias s where s.negocio_id = v_negocio and s.tipo like 'E%')
  );
end $$;

create or replace function private.ecf_guardar_config_impl(p_config jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_negocio uuid := public.mi_negocio();
  v_ambiente text := nullif(btrim(coalesce(p_config ->> 'ambiente', '')), '');
  v_activo boolean := (p_config ->> 'activo')::boolean;
  v_email text := nullif(lower(btrim(coalesce(p_config ->> 'email', ''))), '');
  v_password text := nullif(p_config ->> 'password', '');
  v_api_key text := nullif(btrim(coalesce(p_config ->> 'api_key', '')), '');
  v_razon text := nullif(btrim(coalesce(p_config ->> 'razon_social', '')), '');
  c public.vetmake_ecf_config;
begin
  if v_negocio is null or not public.tiene_rol(array['admin']) then
    raise exception using errcode = '42501', message = 'Solo el administrador configura la facturación electrónica.';
  end if;
  if v_ambiente is not null and v_ambiente not in ('TesteCF', 'CerteCF', 'eCF') then
    raise exception using errcode = '22023', message = 'Ambiente no válido.';
  end if;
  insert into public.vetmake_ecf_config (negocio_id) values (v_negocio) on conflict (negocio_id) do nothing;
  select * into c from public.vetmake_ecf_config where negocio_id = v_negocio for update;

  if v_password is not null then
    if c.password_id is null then
      c.password_id := vault.create_secret(v_password, 'ecf_password_' || v_negocio::text, 'Contraseña PSFE de la clínica');
    else
      perform vault.update_secret(c.password_id, v_password);
    end if;
  end if;
  if v_api_key is not null then
    if c.api_key_id is null then
      c.api_key_id := vault.create_secret(v_api_key, 'ecf_api_key_' || v_negocio::text, 'API key PSFE de la clínica');
    else
      perform vault.update_secret(c.api_key_id, v_api_key);
    end if;
  end if;

  if v_activo and (coalesce(v_email, c.email) is null or c.password_id is null or c.api_key_id is null) then
    raise exception using errcode = '22023', message = 'Para activar la facturación electrónica faltan el correo, la contraseña o la API key del proveedor.';
  end if;

  update public.vetmake_ecf_config set
    ambiente = coalesce(v_ambiente, ambiente),
    activo = coalesce(v_activo, activo),
    email = coalesce(v_email, email),
    password_id = c.password_id,
    api_key_id = c.api_key_id,
    -- Cambiar de ambiente o de cuenta invalida el token guardado.
    id_token = case when (v_ambiente is not null and v_ambiente <> ambiente) or (v_email is not null and v_email is distinct from email) or v_password is not null then null else id_token end,
    refresh_token = case when (v_ambiente is not null and v_ambiente <> ambiente) or (v_email is not null and v_email is distinct from email) or v_password is not null then null else refresh_token end,
    token_expira = case when (v_ambiente is not null and v_ambiente <> ambiente) or (v_email is not null and v_email is distinct from email) or v_password is not null then null else token_expira end,
    actualizado = now()
  where negocio_id = v_negocio;

  if v_razon is not null then
    update public.negocios set razon_social = left(v_razon, 150) where id = v_negocio;
  end if;
  return private.ecf_config_impl();
end $$;

-- ─── 4. NCF / e-NCF en la factura ───────────────────────────────────────────
create or replace function private.asignar_ncf_factura_impl(p_factura jsonb, p_tipo text, p_rnc_cliente text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
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
  electronico boolean := p_tipo like 'E%';
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

  if p_tipo is null or p_tipo not in ('B01', 'B02', 'B14', 'B15', 'E31', 'E32') then
    raise exception using errcode = '22023', message = 'Tipo de comprobante no válido.';
  end if;
  if p_tipo in ('B01', 'E31') and length(rnc) not in (9, 11) then
    raise exception using errcode = '22023',
      message = format('El Crédito Fiscal (%s) exige el RNC (9 dígitos) o la cédula (11) del cliente.', p_tipo);
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
    creada := private.crear_factura((p_factura - 'id' - 'numero') || jsonb_build_object('origenRef', ref));
    select * into fila from public.pc_facturas where id = creada ->> 'id' and negocio_id = negocio for update;
  end if;

  if fila.estado = 'anulada' then
    raise exception using errcode = '22023', message = 'Una factura anulada no recibe comprobante fiscal.';
  end if;

  if fila.ncf is not null then
    return to_jsonb(fila);
  end if;

  -- Consumo electrónico de RD$250,000 o más: la DGII exige identificar al comprador.
  if p_tipo = 'E32' and coalesce(fila.total, 0) >= 250000 and length(rnc) not in (9, 11) then
    raise exception using errcode = '22023',
      message = 'Una factura de consumo de RD$250,000 o más exige el RNC o la cédula del cliente.';
  end if;

  select s.* into sec
  from public.pc_ncf_secuencias as s
  where s.negocio_id = negocio and s.tipo = p_tipo
  for update;

  if not found then
    raise exception using errcode = 'P0002',
      message = format('No hay un rango de %s %s registrado. El administrador lo carga en Configuración con los números autorizados por la DGII.',
                       case when electronico then 'e-NCF' else 'NCF' end, p_tipo);
  end if;
  if not sec.activa then
    raise exception using errcode = '22023', message = format('El rango de %s está desactivado.', p_tipo);
  end if;
  if sec.siguiente > sec.hasta then
    raise exception using errcode = '22023',
      message = format('Se acabaron los comprobantes %s. Hay que solicitar un rango nuevo a la DGII.', p_tipo);
  end if;
  if sec.vence is not null and sec.vence < private.hoy_rd() then
    raise exception using errcode = '22023',
      message = format('La autorización de los comprobantes %s venció el %s.', p_tipo, to_char(sec.vence, 'DD/MM/YYYY'));
  end if;

  comprobante := private.ncf_formatear(p_tipo, sec.siguiente);

  update public.pc_ncf_secuencias
     set siguiente = siguiente + 1, actualizado = now(), actualizado_por = usuario
   where negocio_id = negocio and tipo = p_tipo;

  update public.pc_facturas
     set ncf = comprobante,
         ncftipo = p_tipo,
         rnccliente = case when p_tipo in ('B01', 'E31') then rnc else nullif(rnc, '') end,
         ecf_estado = case when electronico then 'por_enviar' else null end,
         ecf_origen = case when electronico then 'proveedor' else null end,
         ecf_actualizado = case when electronico then now() else null end
   where id = fila.id and negocio_id = negocio
  returning * into fila;

  return to_jsonb(fila);
end;
$function$;

create or replace function private.guardar_secuencia_ncf_impl(p_secuencia jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  usuario uuid := (select auth.uid());
  negocio uuid;
  rol text;
  v_tipo text := upper(btrim(coalesce(p_secuencia ->> 'tipo', '')));
  v_desde bigint;
  v_hasta bigint;
  v_max bigint;
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

  if v_tipo not in ('B01', 'B02', 'B04', 'B14', 'B15', 'E31', 'E32', 'E34') then
    raise exception using errcode = '22023', message = 'Tipo de comprobante no válido.';
  end if;
  v_max := case when v_tipo like 'E%' then 9999999999 else 99999999 end;

  v_desde := (p_secuencia ->> 'desde')::bigint;
  v_hasta := (p_secuencia ->> 'hasta')::bigint;
  v_vence := nullif(p_secuencia ->> 'vence', '')::date;

  if v_desde is null or v_hasta is null or v_desde < 1 or v_hasta > v_max or v_hasta < v_desde then
    raise exception using errcode = '22023',
      message = format('El rango no es válido: «desde» y «hasta» van de 1 a %s y «hasta» no puede ser menor.', v_max);
  end if;
  if v_tipo = 'E31' and v_vence is null then
    raise exception using errcode = '22023', message = 'Los e-NCF E31 necesitan la fecha de vencimiento que dio la DGII.';
  end if;

  select s.* into actual
  from public.pc_ncf_secuencias as s
  where s.negocio_id = negocio and s.tipo = v_tipo
  for update;

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
    where n.negocio_id = negocio and left(n.ncf, 3) = v_tipo
      and substr(n.ncf, 4)::bigint >= v_siguiente
      and substr(n.ncf, 4)::bigint <= v_hasta
  ) then
    raise exception using errcode = '23505',
      message = 'Ese rango incluye comprobantes que ya se emitieron en esta clínica. Revisa los números autorizados por la DGII.';
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
$function$;

-- Nota de crédito: E34 si la factura es electrónica, B04 si no.
create or replace function private.emitir_nota_credito_impl(p_factura_ref text, p_total numeric, p_motivo text, p_operacion_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare ctx record; fac public.pc_facturas%rowtype; sec public.pc_ncf_secuencias%rowtype;
        previo public.pc_notas_credito%rowtype; ya numeric; v_total numeric; v_sub numeric; v_itbis numeric;
        comprobante text; fila public.pc_notas_credito%rowtype; v_tipo text;
begin
  select * into ctx from private.caja_contexto(array['admin']);
  if p_operacion_id is null then
    raise exception using errcode = '22023', message = 'Falta el identificador de la operación.';
  end if;
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
  if fac.ncf like 'E%' and coalesce(fac.ecf_estado, '') in ('por_enviar', 'rechazado') then
    raise exception using errcode = '22023',
      message = 'El e-CF de esta factura todavía no fue aceptado por la DGII: no se le puede hacer nota de crédito.';
  end if;
  v_tipo := case when fac.ncf like 'E%' then 'E34' else 'B04' end;

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
  if coalesce(fac.itbisamt, 0) > 0 and fac.total > 0 then
    v_itbis := round(v_total * fac.itbisamt / fac.total, 2);
  else
    v_itbis := 0;
  end if;
  v_sub := v_total - v_itbis;

  select s.* into sec from public.pc_ncf_secuencias s
   where s.negocio_id = ctx.negocio and s.tipo = v_tipo
   for update;
  if not found then
    raise exception using errcode = 'P0002',
      message = format('No hay un rango de %s (notas de crédito) registrado. El administrador lo carga en Configuración con los números autorizados por la DGII.', v_tipo);
  end if;
  if not sec.activa then
    raise exception using errcode = '22023', message = format('El rango de %s está desactivado.', v_tipo);
  end if;
  if sec.siguiente > sec.hasta then
    raise exception using errcode = '22023', message = format('Se acabaron los comprobantes %s. Hay que solicitar un rango nuevo a la DGII.', v_tipo);
  end if;
  if sec.vence is not null and sec.vence < private.hoy_rd() then
    raise exception using errcode = '22023',
      message = format('La autorización de los comprobantes %s venció el %s.', v_tipo, to_char(sec.vence, 'DD/MM/YYYY'));
  end if;
  comprobante := private.ncf_formatear(v_tipo, sec.siguiente);
  update public.pc_ncf_secuencias set siguiente = siguiente + 1, actualizado = now(), actualizado_por = (select auth.uid())
   where negocio_id = ctx.negocio and tipo = v_tipo;

  insert into public.pc_notas_credito (negocio_id, operacion_id, ncf, factura_id, ncf_modificado, fecha, motivo,
                                       subtotal, itbis, total, rnccliente, propietario, emitida_por, emitida_nombre,
                                       ecf_estado, ecf_origen, ecf_actualizado)
  values (ctx.negocio, p_operacion_id, comprobante, fac.id, fac.ncf, private.hoy_rd(), left(btrim(p_motivo), 500),
          v_sub, v_itbis, v_total, fac.rnccliente, fac.propietario, (select auth.uid()), ctx.nombre,
          case when v_tipo = 'E34' then 'por_enviar' end, case when v_tipo = 'E34' then 'proveedor' end,
          case when v_tipo = 'E34' then now() end)
  returning * into fila;
  return to_jsonb(fila);
exception
  when numeric_value_out_of_range then
    raise exception using errcode = '22023', message = 'El monto no es válido.';
end $function$;

-- ─── 5. Respaldo: anotar un e-CF del Facturador Gratuito ────────────────────
create or replace function private.registrar_ecf_manual_impl(
  p_factura jsonb, p_encf text, p_codigo_seguridad text, p_fecha_firma text, p_rnc_cliente text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  usuario uuid := (select auth.uid());
  negocio uuid; rol text;
  ref text := nullif(btrim(coalesce(p_factura ->> 'id', '')), '');
  v_encf text := upper(regexp_replace(coalesce(p_encf, ''), '\s', '', 'g'));
  v_codigo text := btrim(coalesce(p_codigo_seguridad, ''));
  rnc text := regexp_replace(coalesce(p_rnc_cliente, ''), '[^0-9]', '', 'g');
  v_tipo text;
  creada jsonb;
  fila public.pc_facturas%rowtype;
begin
  if usuario is null then
    raise exception using errcode = '42501', message = 'Se requiere una sesión autenticada.';
  end if;
  select m.negocio_id, m.rol into negocio, rol
    from public.usuarios_negocio m join public.negocios c on c.id = m.negocio_id
   where m.usuario_id = usuario and m.activo and c.activo;
  if negocio is null or rol not in ('admin', 'caja', 'veterinario') then
    raise exception using errcode = '42501', message = 'Tu rol no puede registrar comprobantes fiscales.';
  end if;
  if v_encf !~ '^E3[12][0-9]{10}$' then
    raise exception using errcode = '22023',
      message = 'El e-NCF tiene 13 caracteres: E31 o E32 seguido de 10 dígitos (ej. E320000000001).';
  end if;
  if v_codigo !~ '^[A-Za-z0-9]{6}$' then
    raise exception using errcode = '22023', message = 'El código de seguridad tiene 6 letras o números (sale en el PDF del Facturador Gratuito).';
  end if;
  v_tipo := left(v_encf, 3);
  if v_tipo = 'E31' and length(rnc) not in (9, 11) then
    raise exception using errcode = '22023', message = 'Un E31 (crédito fiscal) lleva el RNC o la cédula del cliente.';
  end if;
  if ref is null then
    raise exception using errcode = '22023', message = 'Falta identificar la factura.';
  end if;

  select f.* into fila from public.pc_facturas f
   where f.negocio_id = negocio and (f.id = ref or f.origen_ref = ref)
   order by (f.id = ref) desc limit 1 for update;
  if not found then
    creada := private.crear_factura((p_factura - 'id' - 'numero') || jsonb_build_object('origenRef', ref));
    select * into fila from public.pc_facturas where id = creada ->> 'id' and negocio_id = negocio for update;
  end if;
  if fila.estado = 'anulada' then
    raise exception using errcode = '22023', message = 'Una factura anulada no recibe comprobante fiscal.';
  end if;
  if fila.ncf is not null then
    if fila.ncf = v_encf then return to_jsonb(fila); end if;
    raise exception using errcode = '22023', message = format('Esta factura ya tiene el comprobante %s.', fila.ncf);
  end if;

  update public.pc_facturas
     set ncf = v_encf, ncftipo = v_tipo,
         rnccliente = nullif(rnc, ''),
         ecf_estado = 'manual', ecf_origen = 'facturador_gratuito',
         ecf_codigo_seguridad = v_codigo,
         ecf_fecha_firma = nullif(left(btrim(coalesce(p_fecha_firma, '')), 30), ''),
         ecf_actualizado = now()
   where id = fila.id and negocio_id = negocio
  returning * into fila;
  return to_jsonb(fila);
exception
  when unique_violation then
    raise exception using errcode = '23505', message = 'Ese e-NCF ya está anotado en otra factura de esta clínica.';
end $$;

-- ─── 6. Una factura con e-CF no cambia sus montos ───────────────────────────
create or replace function private.proteger_factura_ecf()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.ncf like 'E%' and coalesce(old.ecf_estado, '') <> 'rechazado'
     and (new.items is distinct from old.items or new.total is distinct from old.total
          or new.subtotal is distinct from old.subtotal or new.itbisamt is distinct from old.itbisamt
          or new.fecha is distinct from old.fecha or new.itbis is distinct from old.itbis) then
    raise exception using errcode = '22023',
      message = 'Esta factura ya tiene comprobante electrónico: no se cambian montos, líneas ni fecha. Para corregirla emite una nota de crédito.',
      hint = 'vetmake_ecf_inmutable';
  end if;
  return new;
end $$;
revoke all on function private.proteger_factura_ecf() from public, anon, authenticated;
drop trigger if exists vetmake_proteger_factura_ecf on public.pc_facturas;
create trigger vetmake_proteger_factura_ecf before update on public.pc_facturas
  for each row execute function private.proteger_factura_ecf();

-- ─── 7. Documento e-CF (JSON con la estructura oficial de la DGII) ──────────
create or replace function private.ecf_fecha(p_fecha date)
returns text language sql immutable set search_path = '' as $$ select to_char(p_fecha, 'DD-MM-YYYY'); $$;
revoke all on function private.ecf_fecha(date) from public, anon, authenticated;

create or replace function private.ecf_documento(p_negocio uuid, p_clase text, p_id text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  n public.negocios;
  f public.pc_facturas;
  nc public.pc_notas_credito;
  fo public.pc_facturas;
  sec public.pc_ncf_secuencias;
  v_tipo text; v_encf text; v_fecha date; v_rnc_comp text; v_nombre_comp text;
  v_items jsonb := '[]'::jsonb; v_iddoc jsonb; v_totales jsonb; v_comprador jsonb; v_ref jsonb;
  v_gravado boolean; v_sub numeric; v_itbis numeric; v_total numeric; v_credito boolean;
  linea jsonb; i integer := 0; v_monto numeric; v_bruto numeric; v_item jsonb;
begin
  select * into n from public.negocios where id = p_negocio;
  if regexp_replace(coalesce(n.rnc, ''), '[^0-9]', '', 'g') !~ '^([0-9]{9}|[0-9]{11})$' then
    raise exception using errcode = '22023', message = 'La clínica no tiene RNC válido en Configuración → Perfil comercial.';
  end if;

  if p_clase = 'factura' then
    select * into f from public.pc_facturas where id = p_id and negocio_id = p_negocio;
    if not found or f.ncf is null or f.ncf not like 'E%' then
      raise exception using errcode = 'P0002', message = 'La factura no tiene e-NCF asignado.';
    end if;
    v_tipo := f.ncftipo; v_encf := f.ncf; v_fecha := public.pc_fecha(f.fecha);
    v_rnc_comp := nullif(regexp_replace(coalesce(f.rnccliente, ''), '[^0-9]', '', 'g'), '');
    v_nombre_comp := nullif(btrim(coalesce(f.propietario, f.mascota, '')), '');
    v_gravado := coalesce(f.itbis, false);
    v_credito := f.estado = 'pendiente';
    -- Líneas: el mismo cálculo que crear_factura (redondeo a peso por línea).
    for linea in select * from jsonb_array_elements(coalesce(f.items, '[]'::jsonb)) loop
      i := i + 1;
      v_bruto := coalesce((linea ->> 'precio')::numeric, 0) * coalesce((linea ->> 'cantidad')::numeric, 1);
      v_monto := round(v_bruto * (1 - coalesce((linea ->> 'descuento')::numeric, 0) / 100));
      v_item := jsonb_build_object(
        'NumeroLinea', i,
        'IndicadorFacturacion', case when v_gravado then 1 else 4 end,
        'NombreItem', left(coalesce(nullif(btrim(linea ->> 'descripcion'), ''), 'Servicio'), 80),
        'IndicadorBienoServicio', case when coalesce((linea ->> 'bien')::boolean, false) then 1 else 2 end,
        'CantidadItem', coalesce((linea ->> 'cantidad')::numeric, 1),
        'PrecioUnitarioItem', round(coalesce((linea ->> 'precio')::numeric, 0), 2),
        'MontoItem', v_monto);
      if v_bruto - v_monto > 0 then
        v_item := v_item || jsonb_build_object('DescuentoMonto', round(v_bruto - v_monto, 2));
      end if;
      v_items := v_items || v_item;
    end loop;
    v_sub := coalesce(f.subtotal, 0); v_itbis := coalesce(f.itbisamt, 0); v_total := coalesce(f.total, 0);
  elsif p_clase = 'nota' then
    select * into nc from public.pc_notas_credito where id::text = p_id and negocio_id = p_negocio;
    if not found or nc.ncf not like 'E34%' then
      raise exception using errcode = 'P0002', message = 'La nota de crédito no es electrónica.';
    end if;
    select * into fo from public.pc_facturas where id = nc.factura_id and negocio_id = p_negocio;
    v_tipo := 'E34'; v_encf := nc.ncf; v_fecha := nc.fecha;
    v_rnc_comp := nullif(regexp_replace(coalesce(nc.rnccliente, ''), '[^0-9]', '', 'g'), '');
    v_nombre_comp := nullif(btrim(coalesce(nc.propietario, '')), '');
    v_gravado := coalesce(nc.itbis, 0) > 0;
    v_credito := false;
    v_sub := nc.subtotal; v_itbis := nc.itbis; v_total := nc.total;
    v_items := jsonb_build_array(jsonb_build_object(
      'NumeroLinea', 1,
      'IndicadorFacturacion', case when v_gravado then 1 else 4 end,
      'NombreItem', left('Nota de crédito: ' || coalesce(nc.motivo, ''), 80),
      'IndicadorBienoServicio', 2,
      'CantidadItem', 1,
      'PrecioUnitarioItem', v_sub,
      'MontoItem', v_sub));
    v_ref := jsonb_build_object(
      'NCFModificado', nc.ncf_modificado,
      'FechaNCFModificado', private.ecf_fecha(public.pc_fecha(fo.fecha)),
      'CodigoModificacion', case when nc.total >= coalesce(fo.total, 0) then '1' else '3' end,
      'RazonModificacion', left(coalesce(nc.motivo, ''), 90));
  else
    raise exception using errcode = '22023', message = 'Clase de documento no válida.';
  end if;

  select * into sec from public.pc_ncf_secuencias where negocio_id = p_negocio and tipo = v_tipo;

  v_iddoc := jsonb_build_object('TipoeCF', substr(v_tipo, 2), 'eNCF', v_encf);
  if v_tipo = 'E31' and sec.vence is not null then
    v_iddoc := v_iddoc || jsonb_build_object('FechaVencimientoSecuencia', private.ecf_fecha(sec.vence));
  end if;
  if v_tipo = 'E34' then
    v_iddoc := v_iddoc || jsonb_build_object('IndicadorNotaCredito',
      case when v_fecha - public.pc_fecha(fo.fecha) > 30 then 1 else 0 end);
  end if;
  v_iddoc := v_iddoc || jsonb_build_object('IndicadorMontoGravado', 0, 'TipoIngresos', '01',
                                           'TipoPago', case when v_credito then 2 else 1 end);
  if v_credito then
    v_iddoc := v_iddoc || jsonb_build_object('FechaLimitePago', private.ecf_fecha(v_fecha + 30));
  end if;

  if v_rnc_comp is not null then
    v_comprador := jsonb_build_object('RNCComprador', v_rnc_comp,
                                      'RazonSocialComprador', left(coalesce(v_nombre_comp, 'Cliente'), 150));
  elsif v_tipo = 'E31' then
    raise exception using errcode = '22023', message = 'El E31 necesita el RNC o la cédula del cliente.';
  end if;

  if v_gravado then
    v_totales := jsonb_build_object('MontoGravadoTotal', v_sub, 'MontoGravadoI1', v_sub,
                                    'ITBIS1', 18, 'TotalITBIS', v_itbis, 'TotalITBIS1', v_itbis,
                                    'MontoTotal', v_total);
  else
    v_totales := jsonb_build_object('MontoExento', v_sub, 'MontoTotal', v_total);
  end if;

  return jsonb_build_object('ECF',
    jsonb_strip_nulls(jsonb_build_object(
      'Encabezado', jsonb_strip_nulls(jsonb_build_object(
        'Version', '1.0',
        'IdDoc', v_iddoc,
        'Emisor', jsonb_build_object(
          'RNCEmisor', regexp_replace(n.rnc, '[^0-9]', '', 'g'),
          'RazonSocialEmisor', left(coalesce(nullif(btrim(n.razon_social), ''), n.nombre), 150),
          'DireccionEmisor', left(coalesce(nullif(btrim(n.direccion), ''), 'Santo Domingo'), 100),
          'FechaEmision', private.ecf_fecha(v_fecha)),
        'Comprador', v_comprador,
        'Totales', v_totales)),
      'DetallesItems', jsonb_build_object('Item', v_items),
      'InformacionReferencia', v_ref)));
end $$;
revoke all on function private.ecf_documento(uuid, text, text) from public, anon, authenticated;

-- ─── 8. Funciones solo-servidor (Edge Function vetmake-ecf, service_role) ───
create or replace function public.ecf_servidor_contexto(p_usuario uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare m record; c public.vetmake_ecf_config; e record;
begin
  select u.negocio_id, u.rol into m
    from public.usuarios_negocio u join public.negocios n on n.id = u.negocio_id
   where u.usuario_id = p_usuario and u.activo and n.activo;
  if m.negocio_id is null then
    return jsonb_build_object('ok', false, 'mensaje', 'Tu usuario no pertenece a una clínica activa.');
  end if;
  select * into c from public.vetmake_ecf_config where negocio_id = m.negocio_id;
  select * into e from private.membresia_estado(m.negocio_id);
  return jsonb_build_object(
    'ok', true,
    'negocio_id', m.negocio_id,
    'rol', m.rol,
    'puede_escribir', e.puede_escribir,
    'activo', coalesce(c.activo, false),
    'proveedor', coalesce(c.proveedor, 'mseller'),
    'ambiente', coalesce(c.ambiente, 'TesteCF'),
    'email', c.email,
    'password', (select s.decrypted_secret from vault.decrypted_secrets s where s.id = c.password_id),
    'api_key', (select s.decrypted_secret from vault.decrypted_secrets s where s.id = c.api_key_id),
    'id_token', c.id_token,
    'refresh_token', c.refresh_token,
    'token_sub', c.token_sub,
    'token_expira', c.token_expira);
end $$;

create or replace function public.ecf_servidor_documento(p_negocio uuid, p_clase text, p_id text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select private.ecf_documento(p_negocio, p_clase, p_id);
$$;

create or replace function public.ecf_servidor_guardar_token(
  p_negocio uuid, p_id_token text, p_refresh_token text, p_sub text, p_expira timestamptz, p_prueba_ok boolean default null)
returns void language sql security definer set search_path = '' as $$
  update public.vetmake_ecf_config
     set id_token = p_id_token,
         refresh_token = coalesce(p_refresh_token, refresh_token),
         token_sub = coalesce(p_sub, token_sub),
         token_expira = p_expira,
         ultima_prueba = case when p_prueba_ok is null then ultima_prueba else now() end,
         ultima_prueba_ok = coalesce(p_prueba_ok, ultima_prueba_ok)
   where negocio_id = p_negocio;
$$;

-- Guarda lo que respondió el proveedor. Estados del proveedor → estados VetMake.
create or replace function public.ecf_servidor_resultado(p_negocio uuid, p_clase text, p_id text, p_resultado jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_estado_prov text := lower(coalesce(p_resultado ->> 'status', p_resultado ->> 'estado', ''));
  v_estado text;
  v_error text := nullif(p_resultado ->> 'error', '');
  v_fila jsonb;
begin
  v_estado := case
    when v_error is not null then null
    when v_estado_prov like 'aceptado condicional%' or v_estado_prov = 'aceptado_condicional' then 'aceptado_condicional'
    when v_estado_prov like 'aceptado%' then 'aceptado'
    when v_estado_prov like 'rechazado%' then 'rechazado'
    else 'en_proceso' end;

  -- Columnas iguales en ambas tablas.
  execute format($q$
    update public.%I set
      ecf_estado = coalesce($1, ecf_estado),
      ecf_codigo_seguridad = coalesce(nullif($2 ->> 'securityCode', ''), ecf_codigo_seguridad),
      ecf_qr_url = coalesce(nullif($2 ->> 'qr_url', ''), ecf_qr_url),
      ecf_fecha_firma = coalesce(nullif($2 ->> 'signedDate', ''), ecf_fecha_firma),
      ecf_track_id = coalesce(nullif($2 ->> 'internalTrackId', ''), ecf_track_id),
      ecf_mensaje = left(coalesce($3, nullif($2 ->> 'mensaje', ''), case when $1 = 'rechazado' then 'Rechazado por la DGII' end), 1000),
      ecf_intentos = ecf_intentos + case when $4 then 1 else 0 end,
      ecf_actualizado = now()
    where negocio_id = $5 and id::text = $6
    returning to_jsonb(%I.*)$q$,
    case when p_clase = 'nota' then 'pc_notas_credito' else 'pc_facturas' end,
    case when p_clase = 'nota' then 'pc_notas_credito' else 'pc_facturas' end)
  into v_fila
  using v_estado, p_resultado, v_error, coalesce((p_resultado ->> 'envio')::boolean, false), p_negocio, p_id;
  return v_fila;
end $$;

-- Pendientes de la clínica (para releer estados en lote).
create or replace function public.ecf_servidor_pendientes(p_negocio uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select 'factura' as clase, f.id::text as id, f.ncf from public.pc_facturas f
     where f.negocio_id = p_negocio and f.ecf_estado = 'en_proceso'
    union all
    select 'nota', n.id::text, n.ncf from public.pc_notas_credito n
     where n.negocio_id = p_negocio and n.ecf_estado = 'en_proceso'
    limit 100) x;
$$;

revoke all on function public.ecf_servidor_contexto(uuid) from public, anon, authenticated;
revoke all on function public.ecf_servidor_documento(uuid, text, text) from public, anon, authenticated;
revoke all on function public.ecf_servidor_guardar_token(uuid, text, text, text, timestamptz, boolean) from public, anon, authenticated;
revoke all on function public.ecf_servidor_resultado(uuid, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.ecf_servidor_pendientes(uuid) from public, anon, authenticated;
grant execute on function public.ecf_servidor_contexto(uuid) to service_role;
grant execute on function public.ecf_servidor_documento(uuid, text, text) to service_role;
grant execute on function public.ecf_servidor_guardar_token(uuid, text, text, text, timestamptz, boolean) to service_role;
grant execute on function public.ecf_servidor_resultado(uuid, text, text, jsonb) to service_role;
grant execute on function public.ecf_servidor_pendientes(uuid) to service_role;

-- ─── 9. RPC de la app ───────────────────────────────────────────────────────
revoke all on function private.ecf_config_impl() from public, anon, authenticated;
revoke all on function private.ecf_guardar_config_impl(jsonb) from public, anon, authenticated;
revoke all on function private.registrar_ecf_manual_impl(jsonb, text, text, text, text) from public, anon, authenticated;
grant execute on function private.ecf_config_impl() to authenticated;
grant execute on function private.ecf_guardar_config_impl(jsonb) to authenticated;
grant execute on function private.registrar_ecf_manual_impl(jsonb, text, text, text, text) to authenticated;

create or replace function public.ecf_config()
returns jsonb language sql stable set search_path = '' as $$ select private.ecf_config_impl(); $$;
create or replace function public.ecf_guardar_config(p_config jsonb)
returns jsonb language sql set search_path = '' as $$ select private.ecf_guardar_config_impl(p_config); $$;
create or replace function public.registrar_ecf_manual(
  p_factura jsonb, p_encf text, p_codigo_seguridad text, p_fecha_firma text default null, p_rnc_cliente text default null)
returns jsonb language sql set search_path = '' as $$
  select private.registrar_ecf_manual_impl(p_factura, p_encf, p_codigo_seguridad, p_fecha_firma, p_rnc_cliente);
$$;
revoke all on function public.ecf_config() from public, anon;
revoke all on function public.ecf_guardar_config(jsonb) from public, anon;
revoke all on function public.registrar_ecf_manual(jsonb, text, text, text, text) from public, anon;
grant execute on function public.ecf_config() to authenticated;
grant execute on function public.ecf_guardar_config(jsonb) to authenticated;
grant execute on function public.registrar_ecf_manual(jsonb, text, text, text, text) to authenticated;

-- La configuración e-CF NO va en el respaldo descargable: guarda tokens de
-- sesión del proveedor. Se excluye a propósito de la alerta de tablas sin respaldo.
create or replace function private.respaldo_tablas_faltantes()
returns text[] language sql stable set search_path = '' as $$
  select coalesce(array_agg(c.table_name::text order by c.table_name), '{}'::text[])
    from information_schema.columns c
    join information_schema.tables t
      on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
   where c.table_schema = 'public' and c.column_name = 'negocio_id'
     and c.table_name::text <> 'vetmake_ecf_config'
     and not (c.table_name::text = any(private.respaldo_tablas()));
$$;
