# Relevo entre Codex y Claude Code

Este archivo resume el estado comprobable del trabajo activo. El repositorio y
el historial remoto de Supabase son la fuente de verdad.

## Estado actual

- Agente activo: Codex.
- Rama: `codex/import-catalog-duplicates`, creada desde
  `codex/p0-auth-localstorage` en `ffb698a`.
- El commit vigente del candidato es siempre el `HEAD` de esta rama.
- Objetivo: endurecimiento de VetMake para producción, una solución completa a
  la vez.
- No se fusionó ni desplegó el candidato y no se aplicaron migraciones nuevas.

## Cambio actual — navegación guiada del tutorial

- `index.html` añade una barra reutilizable de avance sobre cada función incluida
  en los 19 pasos del tutorial, con el número de paso, el nombre de la tarea y
  los botones **Paso comprobado** y **Siguiente paso**.
- El botón **Siguiente paso** conserva el paso actual, guarda el avance en
  `vetmake_tutorial_completados` y abre automáticamente la siguiente función;
  también funciona para pasos consecutivos que comparten pestaña, como
  configuración, inventario y seguimientos.
- Al comprobar un paso aparece una tarjeta con brillo animado y el texto de la
  próxima tarea para llamar la atención del usuario sobre el siguiente botón.
- El estado permanece en el navegador y se sincroniza con la navegación interna
  existente del tutorial. No hubo cambios de esquema ni migraciones de
  Supabase.
- Prueba Playwright local: en Servicios apareció `Paso 4 de 19`; **Paso
  comprobado** mostró `¡Paso completado!` y `Siguiente paso →`; al pulsarlo se
  abrió Inventario con `Paso 5 de 19`.

## Cambio actual — duplicados al importar catálogo

- `index.html` ahora conserva las filas repetidas durante la revisión de
  importación, en vez de ocultarlas al agruparlas.
- Detecta nombres equivalentes ignorando mayúsculas, acentos, signos y espacios,
  además de coincidencias exactas con servicios o inventario ya existentes.
- Los duplicados aparecen en un bloque separado con las acciones **Conservar**,
  **Quitar** y **Quitar todos los duplicados**; también hay filtros para ver
  todos, solo los listos o solo los duplicados.
- Una fila marcada como duplicada no puede integrarse hasta que el usuario la
  quite o la conserve explícitamente. La protección final vuelve a verificarlo
  antes de guardar y evita repetir productos ya existentes en inventario.
- La lectura de CSV usa UTF-8 explícito para conservar nombres con acentos.
- No hubo cambios de esquema ni migraciones de Supabase.

## Bloque P0 en curso

- Los hooks `useSupabase` ahora salen sin consultar ni mostrar datos cuando no
  hay sesión válida; los fallos de carga muestran estado vacío en vez de usar
  seeds o copias operativas locales.
- Se eliminó la persistencia local de eliminaciones y el seed local de citas.
- El sondeo periódico de ventas/clientes solo se monta con sesión autenticada
  y se desmonta al cerrar sesión.
- Se retiró la limpieza global que leía ventas, facturas y citas de
  `localStorage` antes del login.
- Validación local: 2 scripts inline, 39 migraciones y 21 RPC correctas;
  `git diff --check` limpio. Persisten 65 referencias históricas a
  `localStorage` y deben retirarse por bloques antes del GO.
- Prueba Playwright local del commit actual: login renderizado, validación de
  campos vacíos, favicon sin 404 y formulario público con token inválido
  muestra el error esperado; no hubo excepciones JavaScript de la aplicación.

## Recuperación realizada

- El workspace anterior fue retirado por mantenimiento antes de que sus cambios
  locales se publicaran.
- Se recuperó desde `supabase_migrations.schema_migrations` el SQL de las 29
  migraciones que no existen en `origin/main`.
- También se restauró el contenido aplicado de
  `20260825030000_logos_negocios.sql` y
  `20260825040000_inteligencia_vetmake.sql`.
- El repositorio vuelve a contener 39 archivos de migración. Sus versiones y
  nombres coinciden exactamente con las 39 entradas actuales de `vetmake-dev`.
- `git diff --check` queda limpio después de la recuperación.

## Estado remoto comprobado

- `vetmake-dev`: saludable, 39 migraciones.
- RLS: 21/21 tablas públicas y 13/13 privadas.
- `pc_depositos`, `pc_fichas_clinicas`, `pc_historias`, `pc_paquetes` y
  `pc_seguimientos` todavía permiten DML directo para `authenticated`.
- Gastos, nómina, empleados, clientes, inventario, tarifas, ventas, citas,
  cobros y facturas conservan sus migraciones de endurecimiento en la base.

## Frontend reconstruido

- Se reaplicó localmente a `index.html` la limpieza heredada ya revisada y se
  reconstruyó la capa de sesión, reintento de 401, RPC y estado confirmado por
  servidor.
- Ventas, citas, facturas, clientes, inventario, tarifas, nómina, empleados y
  gastos se enrutan por sus RPC existentes; el Data API genérico rechaza DML
  directo sobre esas tablas.
- Inventario ya no hace doble guardado, no actualiza la interfaz antes de la
  respuesta, bloquea acciones repetidas por producto y no fabrica existencias
  desde gastos o `localStorage`.
- Gastos ya espera confirmación del servidor para alta y corrección, anula sin
  borrado físico, usa UUID temporal, bloquea reenvíos y exige responsable real
  y motivos de auditoría.
- Prueba SQL reversible de Inventario aprobada: alta con stock 2, actualización
  a 0 y retiro (`activo=false`). El `ROLLBACK` dejó cero filas de prueba.
- Prueba SQL reversible de Gastos aprobada: alta RD$100, reintento idempotente,
  corrección a RD$125.50 y anulación auditada. El `ROLLBACK` dejó cero filas de
  prueba; `authenticated` conserva solo `SELECT` sobre `pc_gastos`.
- Se restauró `.github/workflows/main.yml` y se añadió
  `scripts/validate.mjs` para comprobar el candidato en cada push o PR.
- El CI remoto de la rama quedó aprobado en el commit `d20d02c`. El workflow
  usa `fetch-depth: 2` para revisar únicamente los cambios del candidato y no
  tratar todo el historial anterior como un commit raíz.
- Validación local: 2 scripts inline con sintaxis correcta, 39 migraciones con
  versión única, 21 RPC del frontend declaradas en SQL y `git diff --check`
  limpio.
- Prueba de navegador sobre el archivo exacto de `d20d02c`: login renderizado,
  validación de campos vacíos, control mostrar/ocultar contraseña, recuperación
  sin envío y rechazo correcto de un token público inválido.
- Prueba SQL reversible posterior al push: gasto creado por RPC, reintento
  idempotente, una sola fila y operación, visibilidad por RLS y DML directo
  bloqueado. El `ROLLBACK` dejó cero filas y operaciones de prueba.
- Prueba Playwright local de esta rama: CSV con cinco filas produjo dos
  duplicados separados; el botón **Quitar** actualizó el contador y el botón
  **Conservar** reactivó la fila. Los nombres con `ñ` se conservaron.

## Pendientes conocidos

- GitHub Pages continúa desactualizado; esta rama no activa su workflow.
- El validador identifica todavía 93 referencias a `localStorage`, lógica
  ejecutable heredada de PetColinas y llamadas a `vapi-trigger`,
  `calendar-sync` y `pagadito-cobro`, integraciones que no están versionadas ni
  desplegadas en `vetmake-dev`.
- La prueba sin sesión detectó que el frontend intenta cargar diez tablas antes
  de autenticar y después anuncia fallbacks locales. No impide mostrar el
  login, pero bloquea la aprobación para producción hasta retirar ese arranque
  prematuro y cualquier respaldo operativo sensible.
- Las vistas autenticadas todavía requieren una cuenta de prueba dedicada para
  una validación completa por rol; este bloque no utilizó credenciales reales.
- No debe revocarse todavía el DML de depósitos, fichas clínicas, historias,
  paquetes o seguimientos: sus flujos de interfaz aún no están reconstruidos.

## Próxima solución, una sola

Retirar los respaldos de ventas, facturas, citas, inventario y clientes que aún
quedan en componentes legacy (manteniendo únicamente preferencias visuales).
El segundo bloque ya eliminó los lectores de ventas, facturas, citas,
inventario y pagos; queda retirar los escritores y los estados derivados que
siguen en componentes legacy. Después se repite el smoke test sin sesión antes
de continuar con depósitos, historias, fichas, paquetes y seguimientos.
