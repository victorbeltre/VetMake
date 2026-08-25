# Relevo entre Codex y Claude Code

Este archivo es la memoria operativa compartida. El agente que termina o pausa una tarea debe actualizarlo; el siguiente debe leerlo antes de trabajar.

## Estado actual

- Agente que entrega: Claude Code
- Rama: `claude/limpieza-seeds-legacy` (creada desde `origin/main` en `5b26bad`, sin fusionar a `main`)
- Commit: ver `git log -1 claude/limpieza-seeds-legacy`
- Objetivo: limpiar los datos semilla de PetColinas y el código legacy deshabilitado identificados en el diagnóstico previo, sin tocar módulos activos.

## Trabajo realizado

- **Semillas de PetColinas vaciadas** (quedaron como `const NOMBRE_SEED = [];`, ya gestionadas por el flag `VETMAKE_USE_LOCAL_SEEDS = false` que ya las anulaba en `useSupabase`): `VENTAS_SEED`, `GASTOS_SEED`, `CLIENTES_SEED`, `SEGUIMIENTOS_SEED`, `FACTURAS_SEED`, `INVENTARIO_SEED`.
- **Hooks huérfanos eliminados**: `useClientesConSeed` y `useSeguimientosConSeed` — no tenían ninguna llamada en todo el archivo; incluían además una lista adicional de mascotas de PetColinas embebida directamente en el `return`.
- **Bloque legacy completo eliminado** (todo detrás de `VETMAKE_ENABLE_LEGACY_INTEGRATIONS = false`, que también se eliminó por quedar sin usos): funciones `Candidatos`, `AvisoCandidatosNuevos`, `AvisoLlamadasSofia`, `Llamadas`, `WhatsAppInbox`, `VozIA`, el parser/sincronizador de la hoja de Google de reclutamiento (`parseCSVCand`, `leerHojaCandidatos`, `sincronizarCandidatosSheet`, con la URL de la hoja de PetColinas hardcodeada), sus datos de candidatos fijos (`CANDIDATOS_VET`, `CANDIDATOS_GROOMER`, preguntas de entrevista) y el `useEffect` que releía esa hoja cada 2 minutos en segundo plano. Las tres pestañas correspondientes (`vozia`, `llamadas`, `candidatos`) desaparecieron de `TABS` y de la lógica de render.
- **`CatalogoPublico` eliminado**: página con marca, dirección y WhatsApp de PetColinas hardcodeados, inalcanzable en producción (flag + parámetro de URL), pero código muerto de un negocio específico dentro de un SaaS multiempresa.
- **Corrección incidental encontrada durante la limpieza**: `Facturas` usaba `FACTURAS_SEED.length` (132, el conteo histórico de facturas de PetColinas) como piso para el próximo número de factura autogenerado (`Math.max(allNums, facturas_hist_count, regMax)`). Cualquier negocio nuevo con menos de 132 facturas propias saltaba su numeración hasta 133+. Al vaciar `FACTURAS_SEED`, `facturas_hist_count` pasa a ser `0` y la numeración vuelve a partir del historial real de cada negocio.
- **`RESPALDO_TABLAS` depurada**: se quitaron `pc_candidatos` y `pc_llamadas` de la lista de tablas que `descargarRespaldo()` intenta exportar — esas tablas no existen en `vetmake-dev`, así que cada respaldo intentaba leerlas y solo guardaba `{error: ...}` en el JSON exportado.
- **No se tocó**: `MASCOTAS_CASA` (lógica activa del programa de lealtad, específica de PetColinas pero en uso — fuera del alcance pedido), `abrirWA`/`WAPreviewModal`/`dispararCalendarSync` (usados por WhatsApp/Calendar activos, viven cerca del código eliminado pero no dependen de él).
- `index.html`: 19.764 → 16.665 líneas.

## Verificación

- `node --check` sobre los dos bloques `<script>` inline extraídos del HTML: sintaxis válida antes y después de cada tanda de cambios.
- Búsqueda exhaustiva (`grep`) de cada identificador eliminado (`VETMAKE_ENABLE_LEGACY_INTEGRATIONS`, `Candidatos`, `Llamadas`, `VozIA`, `WhatsAppInbox`, `CatalogoPublico`, `AvisoLlamadasSofia`, `AvisoCandidatosNuevos`, constantes `CAND_*`, `useClientesConSeed`, `useSeguimientosConSeed`, `pc_candidatos`, `pc_llamadas`, las seis `_SEED`): cero referencias colgantes.
- Revisión manual de los 9 puntos de edición en el diff (`git diff index.html`) para confirmar que las listas JSX y de `TABS` quedaron sin comas ni corchetes rotos.
- **No pude probar la app cargada en navegador**: la sandbox de red de este entorno bloquea las CDNs de React/jspdf/xlsx/mammoth (`ERR_TUNNEL_CONNECTION_FAILED`), así que un smoke test con Playwright headless no pudo cargar React. Recomiendo que el siguiente agente con acceso a esas CDNs (o Victor en GitHub Pages) abra la app, entre a Dashboard/Ventas/Facturas/Configuración y confirme visualmente que todo carga igual que antes.

## Supabase

- Sin cambios de base de datos, RLS, Storage ni Edge Functions en esta tarea. Es limpieza de frontend únicamente.

## Riesgos o pendientes

- El fix de numeración de facturas (`facturas_hist_count`) es un cambio de comportamiento real, aunque correctivo: cualquier negocio que ya haya generado más de 132 facturas automáticas no verá diferencia; uno con menos sí notará que el próximo número baja a su secuencia real en vez de saltar a 133+. Vale la pena que Codex o Victor lo confirmen con los negocios actuales en `vetmake-dev` antes de dar por cerrado.
- No se validó visualmente en navegador por la razón de red explicada arriba — solo verificación estática.
- Quedan sin tocar (fuera del alcance de esta tarea, con nombres reales de PetColinas): `MASCOTAS_CASA` (cortesías de dueños) y comentarios/textos sueltos con datos de PetColinas en otras partes del archivo que no eran semillas ni código legacy deshabilitado.

## Próximo agente

1. Ejecutar `git status` y revisar el historial reciente.
2. Leer `AGENTS.md`, `CLAUDE.md` si aplica, y este archivo.
3. Si Codex revisa esta rama: confirmar visualmente en navegador (Dashboard, Ventas, Facturas, Configuración, Importar) y luego decidir si la fusiona a `main`.
4. Atender la siguiente petición del usuario sin rehacer funcionalidades ya publicadas.

## Plantilla para el siguiente relevo

- Agente que entrega:
- Rama:
- Commit:
- Objetivo:
- Resultado:
- Archivos principales:
- Pruebas ejecutadas:
- Cambios de Supabase:
- Riesgos o pendientes:
- Instrucción exacta para continuar:
