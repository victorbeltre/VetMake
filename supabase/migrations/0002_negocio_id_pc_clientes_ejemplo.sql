-- VetMake · Fase 1: patrón multi-tenant aplicado a pc_clientes (ejemplo)
--
-- Este es el PATRÓN COMPLETO a repetir, tabla por tabla, para el resto de
-- pc_ventas, pc_facturas, pc_inventario, pc_empleados, pc_gastos, pc_citas...
-- Se eligió pc_clientes como ejemplo trabajado porque es la tabla que se
-- diagnosticó a fondo el 23 ago 2026 (el bug de RLS del formulario) — su
-- estructura ya se conoce con certeza.
--
-- Requiere que 0001_negocios_y_membresia.sql ya se haya aplicado, y que
-- pc_clientes ya exista (portada solo en estructura desde PetColinas, sin
-- datos — este archivo no crea la tabla desde cero a propósito, para no
-- arriesgar que la copia del esquema aquí quede desincronizada de la real
-- si PetColinas le agrega una columna después).

-- ─── 1. Agregar negocio_id ────────────────────────────────────────────────
alter table pc_clientes
  add column negocio_id uuid references negocios(id);

-- En un proyecto con datos reales (nunca el caso para el VetMake de
-- pruebas, que arranca vacío): aquí va el backfill — por ejemplo, si
-- todos los clientes existentes pertenecen a un solo negocio ya conocido:
--   update pc_clientes set negocio_id = '<uuid-del-negocio>' where negocio_id is null;
-- Solo después del backfill se puede forzar NOT NULL:
alter table pc_clientes
  alter column negocio_id set not null;

create index on pc_clientes (negocio_id);

-- ─── 2. Quitar las políticas de un solo negocio ──────────────────────────
-- Estos son los nombres reales de las políticas en PetColinas hoy (ver
-- docs/traspaso/HANDOFF.md) — se listan para que quede claro qué se
-- reemplaza, no porque este archivo vaya a tocar el proyecto real.
drop policy if exists "pc_auth_all" on pc_clientes;
drop policy if exists "pc_clientes insert formulario web" on pc_clientes;

-- ─── 3. Políticas multi-tenant ─────────────────────────────────────────────
create policy "negocio_lee_su_clientes"
  on pc_clientes
  for select
  to authenticated
  using (negocio_id = (select mi_negocio()));

create policy "negocio_escribe_su_clientes"
  on pc_clientes
  for insert
  to authenticated
  with check (negocio_id = (select mi_negocio()));

create policy "negocio_actualiza_su_clientes"
  on pc_clientes
  for update
  to authenticated
  using (negocio_id = (select mi_negocio()))
  with check (negocio_id = (select mi_negocio()));

create policy "negocio_borra_su_clientes"
  on pc_clientes
  for delete
  to authenticated
  using (negocio_id = (select mi_negocio()));

-- ─── 4. Pendiente, sin resolver aquí a propósito ─────────────────────────
-- El puente Form → CRM (form-to-crm.gs) inserta como rol "anon", que no
-- tiene forma de probar negocio_id = mi_negocio() porque anon no tiene
-- identidad. En PetColinas de un solo negocio esto se resolvió con una
-- política de INSERT sin condición. En multi-tenant, cada clínica
-- necesita su propio Apps Script con su propio negocio_id fijo en el
-- código — y probablemente una política más estricta que valide contra
-- una lista de negocios activos, no un INSERT abierto. No se diseña esa
-- política todavía: el bot de WhatsApp y el bridge de formularios siguen
-- marcados "generalizar" (no urgentes) en docs/saas/PLAN.md sección 1.
