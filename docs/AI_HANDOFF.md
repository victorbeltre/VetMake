# Relevo entre Codex y Claude Code

Este archivo resume el estado comprobable del trabajo activo. El repositorio y
el historial remoto de Supabase son la fuente de verdad.

## Relevo de Claude — módulos nuevos de PetColinas (2026-10-23)

- Agente que entrega: Claude Code.
- Rama: `claude/modulos-petcolinas-oct`, creada desde
  `codex/import-catalog-duplicates` en `c61ad08` (no desde `main`: `main` sigue en
  `5b26bad` y el candidato vigente es esa rama). Commits `3430ee5`, `42dd4f6` y
  el de NCF (ver abajo).
- Objetivo: traer a VetMake lo que PetColinas ganó en octubre, sin datos ni
  marca de PetColinas, separado por clínica.
- Resultado:
  1. **Recordatorios de desparasitación por producto** (`3430ee5`): el catálogo
     `ANTIPARASITARIOS` lleva `cobertura` y `meses` (NexGard Spectra: dentro y
     fuera, 35 días, tipo `desparasitacion`; Ferox: solo fuera, 3 meses de
     calendario, tipo `antipulgas`). Incluye el modal `ProgramarDesparasitacion`
     (Seguimientos y Ventas), la pregunta 1 mes / 3 meses al vender un
     desparasitante sin plazo conocido, y `mensajeRecordatorioParasitos` con el
     nombre de la clínica. Se añadió `fechaLocal()`: `hoy()` ya no usa UTC, que
     desde las 8:00 p.m. de RD marcaba el día siguiente. Sin cambios de esquema:
     usa `pc_seguimientos` como antes.
  2. **Hemogramas en la Evolución** (`42dd4f6`): `LabResultados` y
     `ModalLabPreparar`. El informe del laboratorio se usa como IMAGEN: los
     resultados no se leen ni se reescriben (en PetColinas una versión con IA/OCR
     cambió valores). El PDF lleva logo (`negocios.logo_url`), color principal,
     nombre y contacto de la clínica; nada del laboratorio. Subidas y enlaces
     firmados van por `vetmakeAuthedFetch`.
  3. **Comprobantes fiscales (NCF)**: botón «Asignar NCF» en el detalle de la
     factura (`ModalNCF`: B02 Consumo o B01 Crédito Fiscal con RNC/cédula del
     cliente), NCF y RNC impresos en la factura, el PDF y el texto de WhatsApp,
     y sección **Configuración → Comprobantes NCF** (`RangosNCF`) donde el admin
     registra los rangos autorizados por la DGII. El RNC de la clínica sale de
     `negocios.rnc`; se retiró `window._petcolinasRNC`, que se perdía al
     recargar. Se trajo también `avisar(mensaje, tipo)` (avisos en pantalla):
     el hemograma y la desparasitación lo llamaban y VetMake no lo tenía.
     - `asignar_ncf_factura(p_factura, p_tipo, p_rnc_cliente)`: toma el número
       y lo graba en la factura en UNA transacción, idempotente (si ya tenía NCF
       devuelve el mismo). Si la factura solo existía armada desde ventas
       (`venta_...`), la crea con `private.crear_factura` y guarda ese id en
       `origen_ref` (único por clínica), así un reintento no duplica. El
       frontend no pasa la factura por `setFacturas` (dispararía otro
       `crear_factura`): llama la RPC y hace `refetch`.
     - `guardar_secuencia_ncf(p_secuencia)`: solo admin; si el rango incluye
       números ya emitidos continúa donde iba y rechaza cualquier solapamiento.
  4. **Caja diaria y cuentas** (M18/M19/M20 de PetColinas): la pestaña Caja
     reemplaza el `CierreCaja` viejo por cinco modos (Día, Semana, Mes, Rango y
     Cuentas). Incluye el arqueo con saldo inicial y efectivo contado,
     movimientos que no son venta ni gasto, el reporte de periodo con el
     desglose «dónde cayó el dinero», cuentas, traslados (la comisión de
     tarjeta se mide, no se estima) y saldos de banco declarados.
     - El libro (`pc_caja_libro`) es una VISTA sobre ventas, abonos, gastos y
       movimientos; excluye ventas y gastos anulados, ventas pendientes o sin
       cobro y gastos «pendiente de pago».
     - Los bancos ya no están escritos en el código: cada clínica los da de
       alta en «🏦 Bancos de la clínica» con palabras clave (`alias`) que se
       buscan en la forma de pago. Con UN banco activo, una transferencia sin
       banco anotado cae en él; con dos o más va a «Sin asignar».
     - Cada clínica nace con gaveta, tarjetas por liquidar, tarjeta de crédito
       de la empresa (CREDITO) y sin asignar (trigger en `negocios` + backfill).
     - Todo se escribe por RPC: `caja_abrir_dia`, `caja_cerrar_dia` (el
       servidor calcula el teórico de la foto), `caja_reabrir_dia` (solo
       admin), `caja_registrar_movimiento` (rechaza días cerrados),
       `cuentas_guardar`, `cuentas_registrar_traslado`, `cuentas_declarar_saldo`
       (solo admin). Lecturas agregadas: `pc_caja_resumen`, `pc_caja_reporte`
       (misma firma de 4 argumentos que PetColinas), `pc_cuentas_estado`.
     - Gastos: las opciones de método dejan de incluir «Reservas» (de
       PetColinas) y suman «Tarjeta de crédito de la empresa», «Cheque» y
       «Pendiente de pago».
- Archivos principales: `index.html`, `scripts/validate.mjs`,
  `supabase/migrations/20261023180000_resultados_laboratorio.sql`,
  `supabase/migrations/20261023190000_comprobantes_fiscales_ncf.sql`,
  `supabase/migrations/20261023200000_caja_diaria_y_cuentas.sql`.
- Caja en Supabase (aplicado y registrado como `20261023200000
  caja_diaria_y_cuentas`): `pc_cuentas`, `pc_caja_dia`, `pc_caja_movimientos`,
  `pc_traslados`, `pc_cuenta_saldos` con `negocio_id` en la clave, RLS solo de
  lectura (caja y movimientos: admin/caja/veterinario; cuentas, traslados y
  saldos: admin) y sin DML para `authenticated`. Vistas `pc_caja_libro`,
  `pc_cuenta_libro`, `pc_cuenta_declarado` con `security_invoker`. Las
  funciones `SECURITY DEFINER` viven en `private` y filtran a mano por
  `private.caja_contexto()` (dentro de ellas la RLS no aplica). El groomer no
  usa la caja: solo ve sus propias ventas y su libro saldría incompleto.
- NCF en Supabase (aplicado y registrado como `20261023190000
  comprobantes_fiscales_ncf`): `pc_ncf_secuencias` con clave `(negocio_id,
  tipo)`, solo SELECT por RLS; `pc_facturas` gana `ncf`, `ncftipo`,
  `rnccliente`, `origen_ref` con índices únicos por clínica; funciones en
  `private` con envoltorio público invoker; `anon` sin EXECUTE.
- Cambios de Supabase (`vetmake-dev`, ya aplicados y registrados en
  `schema_migrations` como `20261023180000 resultados_laboratorio`):
  `pc_lab_resultados` con clave `(negocio_id, id)`, RLS por `mi_negocio()` +
  `tiene_rol(admin, veterinario)`, solo SELECT/INSERT; bucket privado
  `laboratorios` con políticas que exigen la carpeta `<negocio_id>/`.
- Pruebas ejecutadas:
  - `node scripts/validate.mjs`: OK. Ahora espera 40 migraciones y falla si
    reaparece `ocrLab`, `parsearFilasLab`, `tesseract`, etc.; con NCF y caja
    espera 42 migraciones y 33 RPC declaradas (comprobado
    inyectando `ocrLab`).
  - SQL reversible con dos clínicas (Clínica de Prueba B y PetLand): B ve su
    fila; PetLand ve 0; insertar con el `negocio_id` ajeno da 42501; subir a la
    carpeta ajena da 42501; subir a la propia funciona. `ROLLBACK` completo.
  - `get_advisors(security)`: sin hallazgos nuevos.
  - Lógica de desparasitación en Node: Spectra 35 d, Ferox 3 meses, 31 ene +
    1 mes = 28 feb, mensaje con el nombre de la clínica.
  - PDF de hemograma generado en Node con un negocio de prueba: nombre, color y
    contacto correctos, sin "PetColinas".
  - Playwright: carga el login sin errores JS.
  - NCF, SQL reversible con Clínica de Prueba B y PetLand: rango B02 1–3 da
    B0200000001/2/3; repetir la misma factura devuelve el mismo NCF y una sola
    fila; el cuarto da «Se acabaron los NCF B02»; B01 sin RNC se rechaza;
    re-registrar 1–10 sigue en 4; PetLand ve 0 rangos y no puede asignar.
    `ROLLBACK` completo. `get_advisors(security)` sin hallazgos nuevos.
  - NCF, Playwright con Supabase simulado: `RangosNCF` lista y registra (llama
    `guardar_secuencia_ncf` con los argumentos correctos), `ModalNCF` devuelve
    tipo y RNC, y el PDF lleva RNC de la clínica, NCF, tipo y RNC del cliente.
  - Caja, SQL reversible con ventas, abono, gastos y movimiento de prueba en
    Clínica de Prueba B y PetLand: efectivo 1.400 entradas / 300 salidas,
    teórico 1.600; tras depositar 1.000 en el banco el teórico baja a 600 y el
    flujo del negocio no cambia (4.900 / 1.000); cierre con 590 da −10; no se
    puede registrar en un día cerrado; «Transferencia BHD» cae en la cuenta con
    alias `bhd`; liquidación POS 1.500 → 1.447,50 deja tarjetas en 0 y la
    comisión en 52,50; venta anulada, venta pendiente y gasto pendiente no
    entran. PetLand solo ve su venta y no puede usar cuentas de B; un usuario
    con rol caja recibe totales correctos, `por_cuenta` nulo y «No autorizado»
    en cuentas y al reabrir. `ROLLBACK` completo; `get_advisors(security)` sin
    hallazgos nuevos (`pc_cuenta_de` pasó a envoltorio invoker sobre
    `private.cuenta_de_impl` por el aviso de SECURITY DEFINER expuesto).
  - Caja, Playwright con Supabase simulado: los cinco modos se dibujan sin
    errores; cerrar manda `caja_cerrar_dia` solo con lo contado; agregar banco
    manda `cuentas_guardar` con sus palabras clave; el traslado propone el banco
    de la clínica como destino.
- Riesgos o pendientes:
  - NCF: editar una factura derivada de ventas (`venta_...`) que ya tiene NCF
    pasa por el flujo heredado de `setFacturas`, que intenta `crear_factura`
    con ese id y puede crear otra fila sin NCF. Es el mismo problema que ya
    tenía cualquier factura `venta_...` guardada; conviene que la edición use
    `origen_ref` igual que `asignar_ncf_factura`.
  - NCF: falta la nota de crédito (B04) para anular una factura con NCF, el
    reporte 607 desde la app y la facturación electrónica (e-CF), que la DGII
    va haciendo obligatoria por etapas.
  - `generar_respaldo_negocio_impl` no incluye todavía `pc_ncf_secuencias`,
    `pc_lab_resultados` ni las tablas de caja y cuentas.
  - Caja: un gasto pagado por «Transferencia» en una clínica con dos o más
    bancos cae en «Sin asignar»; el formulario de gastos todavía no pregunta el
    banco. Un gasto «pendiente de pago» entra al libro con la fecha del gasto
    cuando se le pone el método real (pc_gastos guarda una sola fecha).
  - No se probó el flujo con sesión real (faltan credenciales de prueba por rol).
  - `vetmake-dev` está ACTIVO otra vez (se restauró el 2026-10-23).
  - El proyecto `vetmake-dev` contiene tablas `fit13_*` de otra aplicación
    (migraciones `fit13_init` del 26 sep). No son de VetMake; conviene moverlas.
  - Queda por traer de PetColinas el menú lateral agrupado.
- Instrucción para Codex: revisar los commits, rebasar sobre el HEAD vigente
  del candidato si avanzó, correr `node scripts/validate.mjs` y fusionarlos en el
  candidato cuando el flujo con sesión real esté probado.

## Estado actual

- Agente activo: Codex.
- Rama: `codex/import-catalog-duplicates`, creada desde
  `codex/p0-auth-localstorage` en `ffb698a`.
- El commit vigente del candidato es siempre el `HEAD` de esta rama.
- Objetivo: endurecimiento de VetMake para producción, una solución completa a
  la vez.
- PR borrador #1 abierto hacia `main`: https://github.com/victorbeltre/VetMake/pull/1.
- No se fusionó ni desplegó el candidato y no se aplicaron migraciones nuevas.
- En la revisión del 2026-10-11, Supabase reportó `vetmake-dev` como `INACTIVE`.
  El intento de restaurarlo fue rechazado porque la organización gratuita ya
  tiene dos proyectos activos; se necesita pausar uno de esos proyectos o subir
  el plan antes de reintentar.

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

## Continuidad después de refrescar

- La pestaña inicial de `PetColinasApp` ahora recupera
  `vetmake_tutorial_paso` y abre directamente la función asociada al paso
  guardado, en lugar de reiniciar siempre en el tutorial.
- La barra de navegación muestra `Aquí te quedaste. Continúa desde este paso.`
  cuando detecta que la sesión se reanudó desde un paso anterior; el progreso
  completado sigue en `vetmake_tutorial_completados`.
- Prueba Playwright local: después de quedar en Inventario y recargar la página,
  VetMake abrió Inventario automáticamente y mostró `Paso 5 de 19` con el aviso
  de reanudación.

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
  `git diff --check` limpio. Persisten 71 referencias a
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

- `vetmake-dev`: actualmente reportado `INACTIVE` por Supabase; el estado
  anterior `saludable` ya no debe usarse para autorizar un piloto. La consulta
  de migraciones expiró por timeout; no se verificaron en vivo en esta revisión.
- La organización `petcolinasrd@gmail.com's Org` está en plan `free`. Supabase
  rechazó la reactivación indicando que alcanzó el límite de dos proyectos
  activos gratuitos. Los proyectos activos detectados son `PetColinas`
  (`ulrzzddovkioxeaarnjk`) y `anestesioquest` (`llagtkbxykroluaibdle`). No se
  pausó ninguno ni se cambió el plan.
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
- El validador identifica todavía 71 referencias a `localStorage`, lógica
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

## Revisión para piloto — 2026-10-11

- La rama candidata está 10 commits delante de `origin/main`; la validación CI
  del commit `e392078` aprobó. Al crear el PR se inició un nuevo workflow, que
  estaba `in_progress` en la última consulta.
- Se creó el PR #1 en modo borrador para revisar el candidato; no se fusionó ni
  se publicó en Pages.
- Supabase devolvió estado `INACTIVE` para `vetmake-dev`. Los advisors de
  seguridad y rendimiento devolvieron cero findings, pero esto no sustituye
  pruebas del backend activo. La lista de migraciones falló por timeout.
- Próximo paso: el propietario debe elegir entre pausar uno de los dos proyectos
  activos o subir la organización a Pro; después se puede restaurar `vetmake-dev`
  y verificar login, RLS con dos negocios y los flujos completos de operación.
  Mantener el PR en borrador y Pages sin cambios hasta completar esa prueba.
