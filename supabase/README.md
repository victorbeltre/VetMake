# Base de datos de VetMake — Fase 1

## Estado: aplicado y probado en un proyecto de Supabase separado

`vetmake-dev` (`couzqdicmxrypacgrqcn`) — proyecto nuevo, plan gratuito
($0/mes, confirmado antes de crearlo), en la misma organización de
Victor pero **completamente separado** del de PetColinas
(`ulrzzddovkioxeaarnjk`), que sigue sin tocarse.

Ahí se aplicaron `0001`, `0002`, `0003`, `0004`, `0005`, `0006` y `0007`. `0003` agregó la
estructura vacía de las seis tablas operativas, `0004` cerró los permisos
explícitos de `anon` y `0005` agregó las siete tablas auxiliares necesarias
para el MVP; `0006` agrega los planes prepagados y `0007` agrega el perfil
comercial por negocio, el equipo configurable y las políticas admin-only para
la configuración, empleados y tarifas. No se copiaron datos reales de
PetColinas — solo se leyó su estructura para que la prueba fuera fiel.

También está desplegada en `vetmake-dev` la Edge Function `vetmake-admin`
(JWT obligatorio, versión activa 2). Su acción `link_employee` permite que un
administrador invite o vincule por correo a un empleado, cree su membresía en
`usuarios_negocio` y actualice `pc_empleados.usuario_id`. La clave de servidor
solo existe en el entorno de la función; nunca se envía al navegador.

## Los archivos

| Archivo | Qué hace |
|---|---|
| `migrations/0001_negocios_y_membresia.sql` | La fundación: tabla `negocios`, tabla `usuarios_negocio`, función `mi_negocio()`. Se aplica una sola vez. |
| `migrations/0002_negocio_id_pc_clientes_ejemplo.sql` | El patrón completo — agregar `negocio_id`, quitar las políticas de un solo negocio, crear las 4 políticas multi-tenant (select/insert/update/delete) — aplicado a `pc_clientes` como ejemplo trabajado. |
| `migrations/0003_negocio_id_pc_tablas_restantes.sql` | Completa la estructura vacía de esas seis tablas si aún no existe, endurece la fundación RLS y aplica el patrón multi-tenant a `pc_ventas`, `pc_facturas`, `pc_inventario`, `pc_empleados` (nómina), `pc_gastos` y `pc_citas`. |
| `migrations/0004_restringe_acceso_anonimo.sql` | Revoca los permisos explícitos de `anon` sobre las tablas de VetMake y conserva solo los permisos necesarios para la aplicación autenticada. |
| `migrations/0005_negocio_id_tablas_auxiliares.sql` | Crea y tenantiza `pc_seguimientos`, `pc_pagos`, `pc_tarifas`, `pc_historias`, `pc_fichas_clinicas`, `pc_depositos` y `pc_auditoria`, con RLS y permisos explícitos para `authenticated`. |
| `migrations/0006_negocio_id_pc_paquetes.sql` | Crea y tenantiza `pc_paquetes`, la tabla de planes prepagados usada por Ventas y Planes. |
| `migrations/0007_configuracion_negocio_y_empleados.sql` | Agrega datos comerciales a `negocios`, campos de contacto/rol/comisión a `pc_empleados` y restringe las escrituras de configuración, empleados y tarifas al rol `admin`. |
| `functions/vetmake-admin/index.ts` | Edge Function protegida con JWT para invitar/vincular empleados a Auth; valida que el llamante sea `admin` del mismo negocio y usa la clave de servidor solo en backend. |

## Onboarding Auth

El panel de Configuración guarda primero el empleado con su correo y rol. El
botón `✉️ Invitar` llama a `vetmake-admin` con el JWT de la sesión actual. La
función:

1. Comprueba la sesión con `auth.getUser()`.
2. Resuelve la clínica del llamante desde `usuarios_negocio` y exige rol
   `admin`.
3. Comprueba que el empleado pertenece a esa clínica y que el rol es uno de
   `admin`, `veterinario`, `groomer` o `caja`.
4. Busca el usuario por correo; si no existe, usa `inviteUserByEmail`.
5. Crea o actualiza la membresía y vincula `pc_empleados.usuario_id`.
6. El frontend recibe el enlace `invite` o `recovery`, valida el token y pide
   crear una contraseña antes de mostrar el sistema.

Un usuario ya vinculado a otra clínica o a otro empleado se rechaza. La
función se despliega con verificación JWT activa y responde correctamente a
CORS para el frontend hospedado. La pantalla de login también permite pedir
un enlace de recuperación de contraseña.

Antes del primer piloto hay que configurar en **Authentication → URL
Configuration** la `Site URL` y la URL exacta de VetMake (más la URL de preview
si se usa), y habilitar un proveedor SMTP propio para que las invitaciones y
recuperaciones sean confiables. La función usa la `Site URL` de Supabase si no
se define `VETMAKE_SITE_URL`.

## El patrón a repetir

`0002` se hizo sobre `pc_clientes` porque es la tabla que ya se conoce a
fondo (el diagnóstico del bug de RLS del 23 ago). Para el resto de las
tablas operativas incluidas en esta fase (`pc_ventas`, `pc_facturas`,
`pc_inventario`, `pc_empleados` —la tabla de nómina—, `pc_gastos` y
`pc_citas`) el patrón es mecánico:

1. `alter table X add column negocio_id uuid references negocios(id);`
2. Backfill si hay datos, luego `set not null`.
3. `create index on X (negocio_id);`
4. `drop policy` de la política de un solo negocio que exista hoy.
5. Crear las políticas `select` / `insert` / `update` / `delete` con
   `using (negocio_id = (select mi_negocio()))` (y `with check` en
   insert/update).

`0003` también crea las seis tablas vacías cuando no existen en
`vetmake-dev`, porque el baseline aplicado originalmente solo contenía
`pc_clientes`. Copia únicamente columnas, tipos y defaults de PetColinas;
no copia datos reales.

`0005` repite el mismo patrón para las siete tablas auxiliares que el frontend
usa para seguimiento, nómina, tarifas, historia clínica, fichas, depósitos y
auditoría. `0006` hace lo mismo con `pc_paquetes`, que soporta los planes
prepagados. `0007` deja el perfil comercial editable solo por el administrador
del negocio y separa la configuración de empleados y tarifas de la lectura
operativa: cualquier miembro autenticado puede consultarlos dentro de su
tenant, pero solo `admin` puede crearlos, modificarlos o eliminarlos.
`pc_candidatos`, `pc_llamadas` y otras tablas ligadas a operaciones específicas
de PetColinas no se habilitan en el MVP de VetMake.

La misma migración endurece `mi_negocio()` como `SECURITY INVOKER`, revoca
su ejecución a `anon`, conserva la ejecución para `authenticated` y
`service_role`, agrega el índice de membresía que faltaba y otorga a
`authenticated` los permisos explícitos del Data API sobre las tablas
nuevas. Esto evita depender de la exposición implícita que Supabase está
retirando para tablas nuevas.

Después de aplicarla, `0004` elimina también los permisos de tabla que el
proyecto había heredado para `anon`. RLS sigue habilitado en todas las tablas;
la revocación evita depender únicamente de una política vacía para bloquear
el acceso anónimo.

El patrón se validó primero con `pc_clientes` usando dos negocios ficticios
y después se repitió sobre las seis tablas operativas. La verificación
estructural de `0005` confirmó que las catorce tablas tenantizadas tenían
`negocio_id` no nulo, RLS habilitado y cuatro políticas por tabla. `0006`
dejó la misma frontera aplicada a `pc_paquetes`, para un total de quince
tablas tenantizadas.

## La prueba obligatoria antes de vender nada

Esto es lo que dice `docs/saas/PLAN.md` sección 3, hecho concreto: crear
dos negocios de prueba y confirmar que ninguno ve datos del otro. No es
opcional ni se reemplaza con una revisión de código.

```sql
-- 1. Dos negocios de prueba
insert into negocios (nombre, slug) values
  ('Clínica de Prueba A', 'prueba-a'),
  ('Clínica de Prueba B', 'prueba-b');

-- 2. Dos usuarios de Supabase Auth (crear desde el dashboard o la API,
--    no por SQL) — luego membresía de cada uno a SU negocio:
-- insert into usuarios_negocio (usuario_id, negocio_id, rol) values
--   ('<uuid-usuario-A>', '<uuid-negocio-A>', 'admin'),
--   ('<uuid-usuario-B>', '<uuid-negocio-B>', 'admin');

-- 3. Un cliente en cada negocio
-- (autenticado como usuario A) insert into pc_clientes (..., negocio_id) values (..., '<uuid-negocio-A>');
-- (autenticado como usuario B) insert into pc_clientes (..., negocio_id) values (..., '<uuid-negocio-B>');

-- 4. La prueba real: autenticado como usuario A, esto DEBE devolver
--    solo el cliente del negocio A, nunca el de B.
select * from pc_clientes;
```

Si el usuario A ve, edita o borra algo del negocio B con esto puesto,
**no se avanza al piloto** hasta arreglarlo — es exactamente el tipo de
bug que el 23 ago costó horas de diagnóstico en un solo negocio; acá
significaría una fuga de datos médicos entre clínicas de verdad.

## Resultado — 23 ago 2026, corridas reales contra `vetmake-dev`

Dos negocios de prueba, dos usuarios de `auth.users`, un cliente en cada
uno (Firulais → Clínica A, Michi → Clínica B). Autenticado como el usuario
de la Clínica A:

| Prueba | Resultado |
|---|---|
| `select` sobre `pc_clientes` | Solo ve a Firulais, nunca a Michi |
| `insert` marcando una fila como de la Clínica B | Bloqueado por RLS (`42501`) |
| `update` sobre el cliente de la Clínica B | 0 filas afectadas |
| `delete` sobre el cliente de la Clínica B — **corrido con `commit` real, no revertido**, para que la prueba fuera inequívoca | Michi sobrevive intacto, con su `negocio_id` correcto |
| `select` sobre `negocios` | Solo ve el suyo (1 fila) |
| `select` sobre `usuarios_negocio` | Solo ve su propia membresía (1 fila) |

**✅ Pasó. Aislamiento confirmado con datos reales, no solo revisión de
código.** El patrón (`negocio_id` + 4 políticas usando
`(select mi_negocio())`) está
validado y listo para replicarse al resto de las tablas `pc_*` siguiendo
el patrón mecánico de la sección de arriba.

Para las seis tablas operativas nuevas, autenticado como el usuario A, la
prueba transaccional devolvió lo siguiente en cada tabla:

| Operación | Resultado |
|---|---|
| `select` | Solo la fila del negocio A (`OWN_ONLY`) |
| `insert` con `negocio_id` del negocio B | Bloqueado por RLS |
| `update` sobre una fila del negocio B | 0 filas afectadas |
| `delete` sobre una fila del negocio B | 0 filas afectadas |

La transacción se revirtió; las seis tablas siguen vacías y no quedaron
fixtures temporales. `0003`, `0004`, `0005`, `0006` y `0007` están aplicadas en
`vetmake-dev`. La comprobación estructural de `0005` cubre las siete tablas
auxiliares nuevas, `0006` cubre `pc_paquetes` y `0007` fue verificada contra
columnas, grants y políticas RLS de configuración.

Los advisors posteriores quedaron así:

- Seguridad: solo permanece la advertencia preexistente de protección contra
  contraseñas filtradas desactivada; no queda la alerta de `SECURITY DEFINER`.
- Rendimiento: reporta índices sin uso porque las tablas nuevas están vacías;
  se conservan porque cubren las búsquedas por `negocio_id` y las claves
  foráneas.

Los datos de prueba (negocios, usuarios, clientes ficticios) siguen en
`vetmake-dev` a propósito, como fixture reproducible — no se borraron.
