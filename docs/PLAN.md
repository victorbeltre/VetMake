# De PetColinas a SaaS — plan estratégico y técnico

> Rama dedicada al producto SaaS. La implementación vive en `raiz/` y
> **no toca el código de PetColinas en vivo** (`index.html`,
> `supabase/functions/`, `form-to-crm.gs`).

Preparado para Victor Ballas · 23 ago 2026

**Nombre de marca: VetMake.** Verificado sin choques contra software
veterinario existente, ni dominio ni redes sociales ocupadas. Descartados
antes de llegar aquí: VetBase (tres productos ya lo usan), Clinvet (clínicas
reales en España y Colombia más una CRO internacional desde 1999), MiVet
(media docena de productos), VetPal (colisión directa: un producto en
Sudáfrica con el mismo set de funciones — facturación, WhatsApp, Google
Calendar). Pendiente: registro formal de dominio y verificación de marca
antes de invertir en identidad visual.

## Decisiones ya tomadas

1. **Arquitectura: copia separada.** El SaaS se construye en un repo/rama
   aparte. PetColinas en vivo no se toca hasta que la versión multi-negocio
   esté probada y lista para su propia migración.
2. **Recursos: bootstrapped.** Solo Victor + Claude. Sin equipo de
   desarrollo ni presupuesto de infraestructura pesado.
3. **Mercado inicial: veterinarias en República Dominicana.** Mismo idioma,
   moneda y huso horario que ya existen en el código.
4. **Sin llamadas de voz (Vapi).** El SaaS sale con WhatsApp como único
   canal de mensajería/automatización. Vapi "Sofía" sigue viva en
   PetColinas en producción, pero **no forma parte del producto que se
   vende** — ni en el MVP ni en el roadmap actual. Motivo: es la línea de
   costo variable más cara por cliente (minuto de llamada + número propio),
   y no es indispensable para validar el producto con las primeras
   veterinarias piloto. Se puede reconsiderar más adelante, no ahora.

---

## 1. Qué vendes realmente

Inventario de las funciones ya construidas y probadas en PetColinas,
marcando qué se reutiliza tal cual, qué necesita generalizarse, y qué es
específico de PetColinas y no debe salir de ahí.

Leyenda: ✅ reutilizable · 🔧 generalizar · 🔒 específico de PetColinas (no sale)

### Cobros y facturación
- 🔧 Cobro con tarjeta (protocolo SOAP de Pagadito)
- ✅ Pestaña Cobros — facturas vencidas + WhatsApp graduado
- ✅ Abonos a plazos, devuelta en efectivo, fondo de depósito
- ✅ Blindaje de facturas (triggers de auditoría inmutable)

### CRM y retención
- ✅ Planes prepagados, lealtad, mascotas de la casa
- ✅ Próxima cita automática + Google Calendar
- ✅ Reactivación, chequeo gratis, seguimientos por área
- 🔒 Filtro histórico "todo lo de Aylein hasta marzo"

### Integraciones
- 🔧 Bot de WhatsApp con Claude + bandeja de entrada
- ✅ Google Calendar bidireccional, Meta Lead Ads, Realtime
- 🔧 Google Forms → CRM (el puente que se arregló hoy en PetColinas)
- ❌ Vapi "Sofía" — **fuera de alcance del SaaS**, ver decisión 4 arriba

### Operación interna
- ✅ 16 pestañas, portales por rol, cierre de caja, nómina
- 🔧 Boost Engine (lun 2X, mié 3X, vie suerte, sáb 1.5X)
- 🔒 Usuarios y comisiones de Naylan / Valentina / Alexander

La mayoría de las funciones son reutilizables casi tal cual. El trabajo real
no es reescribir el producto — es sacarle los supuestos de "hay una sola
clínica y se llama PetColinas" que quedaron enterrados en el código.

---

## 2. Copia separada del código

Se congela una copia de `index.html` tal como está hoy — validada, 16
pestañas, funcionando — como semilla de un repo/rama nuevo. PetColinas
sigue viviendo donde vive, sirviendo a Naylan, Valentina, Alexander y caja
sin que este trabajo la toque.

**Costo real de esta decisión:** mantener dos códigos duplica el trabajo de
cada bug real. El fix del 23 ago en `form-to-crm.gs` (tres causas distintas
para un mismo error 401) le hubiera costado a Victor el mismo diagnóstico
dos veces si el SaaS ya hubiera existido como copia. Es un costo aceptado,
no uno que desaparece por elegir "copia separada" — solo se traslada de
"arriesgar producción" a "trabajo repetido".

**Mitigación realista** dado el punto de partida (bootstrapped, sin
equipo): no sincronizar los dos códigos automáticamente. Cuando un fix en
PetColinas sea genuinamente genérico, se portea a mano. Cuando sea
específico de PetColinas, se queda ahí.

**Nombre: VetMake.** "PetColinas" es la marca de la clínica de Victor — no
podía ser el nombre del producto. Ver el proceso de descarte al inicio del
documento.

---

## 3. Multi-tenancy: el cambio de fondo

Hoy cada tabla de Supabase tiene una sola política: `for all to
authenticated`. Cualquier empleado que inicia sesión ve todo. Correcto para
una clínica. Catastrófico para dos.

**Modelo de datos:** tabla `negocios` (id, nombre, slug,
plan, moneda, zona horaria, colores, fecha de alta, activo) + columna
`negocio_id` en cada tabla existente (clientes, ventas, facturas,
inventario, nómina, gastos, citas). Tabla `usuarios_negocio` que mapea cada
`auth.uid()` a su `negocio_id` y su rol.

**Las políticas RLS cambian de forma, no de espíritu:** de `using (true)` a
`using (negocio_id = (select mi_negocio()))`. El patrón "todas las tablas usan RLS +
`authenticated`" que ya es la convención de PetColinas se mantiene — solo
se le agrega la dimensión de negocio.

> **Por qué esto no es opcional ni se apura.** En la sesión del 23 ago, un
> solo bug de RLS mal diagnosticado — una política de INSERT en apariencia
> perfecta que un `Prefer: resolution=merge-duplicates` tumbaba por la
> puerta de atrás — costó horas de diagnóstico para **una** tabla, en
> **un** negocio. En multi-tenant, un bug equivalente no significa "el
> formulario no inserta": significa que la Clínica A puede llegar a leer o
> escribir sobre los datos de la Clínica B. Antes de aceptar el primer
> cliente de pago: crear un segundo "negocio" de prueba en el mismo
> proyecto Supabase y verificar, con datos reales de dos negocios
> distintos, que ningún rol cruza la frontera.

**Edge Functions también son multi-tenant.** Las funciones de Deno
(WhatsApp, Pagadito, Calendar) hoy usan un secret fijo por función porque
solo hay un negocio. En el SaaS, cada webhook que llega (un mensaje de
WhatsApp) tiene que resolver primero a qué negocio pertenece — el número de
WhatsApp de destino se vuelve la clave para encontrar el negocio correcto.

**Estado (23 ago, después de aplicar `0001`–`0007`): ✅ fundación aplicada y
aislamiento validado; frontend en integración.** En `vetmake-dev`
(`couzqdicmxrypacgrqcn`) ya están la fundación multi-tenant, `pc_clientes`,
las seis tablas operativas (`pc_ventas`, `pc_facturas`, `pc_inventario`,
`pc_empleados`, `pc_gastos` y `pc_citas`), las siete auxiliares
(`pc_seguimientos`, `pc_pagos`, `pc_tarifas`, `pc_historias`,
`pc_fichas_clinicas`, `pc_depositos` y `pc_auditoria`) y `pc_paquetes` para
planes prepagados. Las quince tablas tienen `negocio_id` no nulo, RLS
habilitado y cuatro políticas cada una;
el aislamiento entre dos usuarios y dos negocios ficticios ya pasó las
pruebas de select, insert, update y delete en las tablas operativas.
También se revocó el acceso explícito de `anon` y `mi_negocio()` quedó como
`SECURITY INVOKER`. PetColinas (`ulrzzddovkioxeaarnjk`) no se tocó. Detalle
completo en `raiz/supabase/README.md`. `0007` agrega perfil comercial por
negocio, equipo configurable y permisos de escritura exclusivos para
administradores sobre configuración, empleados y tarifas. Tablas específicas
de PetColinas como candidatos y llamadas quedan fuera del MVP; `pc_paquetes`
sí forma parte de la base de VetMake.

**Estado de frontend (24 ago): ✅ identidad, configuración y acceso inicial
generalizados.** Paneles, mensajes, agenda, caja, CRM, facturas PDF, carnet y
reportes toman el nombre/tagline/logo del negocio; las semillas y empleados
demo de PetColinas no se cargan. El panel de Configuración permite editar el
perfil comercial, equipo, roles, estado, mensualidad y comisión predeterminada;
Servicios permite crear el catálogo propio sin restaurar defaults heredados.
La Edge Function `vetmake-admin` ya está desplegada con JWT obligatorio: un
administrador puede invitar o vincular por correo a cada empleado sin exponer
la clave administrativa en el navegador. El frontend ya recibe los enlaces de
invitación/recuperación, permite crear la contraseña y conserva la sesión. Las
comisiones nuevas se leen de los registros configurados y no se inventan
porcentajes históricos. Pendiente para el MVP comercial: configurar
correo/dominio de Auth, probar el primer alta real y completar las
integraciones por negocio.

---

## 4. Lo que hoy está quemado para PetColinas

| Qué está fijo hoy | Dónde vive | Se vuelve |
|---|---|---|
| Nombre, logo, colores de marca | Decenas de lugares en `index.html` | Campo en `negocios` |
| Moneda (RD$) | Formato de precios en toda la app | Campo en `negocios` |
| Zona horaria (America/Santo_Domingo) | Visto hoy mismo en `form-to-crm.gs` | Campo en `negocios` |
| Boost Engine (lun 2X, mié 3X…) | Constantes fijas en el motor de comisiones | Tabla configurable por negocio |
| Reglas con nombres de empleados | `CLAUDE.md`, lógica de reportes | No se generaliza — se queda en PetColinas |
| Cuenta comercial de Pagadito | Credenciales de Victor en Edge Function | Cada clínica trae la suya |

---

## 5. Costos reales por cliente nuevo

| Servicio | Quién lo paga | Naturaleza del costo |
|---|---|---|
| Supabase (proyecto compartido, multi-tenant) | El negocio del SaaS | Fijo, crece por escalón de uso |
| WhatsApp Business Cloud API | Cada clínica, con margen | Número propio + costo por conversación |
| Google Calendar | El negocio del SaaS | Gratis hasta volumen alto |
| Pagadito u otra pasarela | Cada clínica, cuenta propia | Comisión por transacción — no la paga el SaaS |
| Dominio / hosting | El negocio del SaaS | GitHub Pages: gratis |

Sin Vapi, la única línea de costo variable por uso real es WhatsApp Cloud
API — verificar tarifas vigentes antes de fijar precio.

---

## 6. Modelo de precios sugerido

| Capa | Incluye | Cómo se cobra |
|---|---|---|
| Plan base | CRM, facturación, inventario, nómina, reportes, cobros, planes prepagados, WhatsApp | Mensual fijo por clínica |
| Add-on: cobros con tarjeta | Integración Pagadito | La clínica trae su cuenta; el SaaS solo integra |

Con Vapi fuera de alcance, WhatsApp entra al plan base en vez de ser un
add-on — su costo variable es manejable y es la integración que más valor
percibido da desde el día uno.

---

## 7. Dar de alta un cliente nuevo (checklist manual)

1. Alta en la tabla de negocios — nombre, moneda, zona horaria, colores y
   perfil comercial.
2. Configurar el equipo, roles, estado y comisiones desde el panel de
   Configuración.
3. Desde Configuración, enviar la invitación de Supabase Auth y vincular cada
   usuario al registro de su empleado.
4. Migrar su base de clientes existente si vienen de Excel u otro sistema.
5. Google Calendar propio si quieren sincronización de citas.
6. WhatsApp Business — número propio, webhook, prompt del bot ajustado a
   su clínica.
7. Pagadito u otra pasarela — cuenta comercial propia de la clínica.
8. Capacitación — material de onboarding para las 16 pestañas.

---

## 8. Roadmap de fases

| Fase | Qué | Cuándo |
|---|---|---|
| 0 — Congelar | ✅ Nombre de marca (VetMake) · repo/rama limpia (`main`) · ✅ copia semilla de `index.html` validada y congelada en `raiz/` · falta registrar el dominio | Esta semana |
| 1 — Datos | ✅ Fundación multi-tenant aplicada en `vetmake-dev`, patrón replicado a las 15 tablas del MVP, aislamiento confirmado y frontend conectado al negocio actual | En curso: primer alta real/Auth |
| 2 — Generalizar | ✅ Identidad operativa, mensajes, documentos, semillas y empleados demo aislados; ✅ perfil comercial, equipo y tarifas configurables con escritura admin-only en `0007`; ✅ invitación/vinculación Auth mediante `vetmake-admin` | En curso: correo e integraciones por negocio |
| 3 — Piloto | 1–2 veterinarias conocidas, gratis o precio simbólico | Cuando la Fase 1 esté probada con datos reales |
| 4 — Vender | Primeras clínicas de pago, onboarding manual asistido | Tras un piloto sin incidentes de aislamiento |
| 5 — Escalar | Autoservicio, más mercados | Más adelante, no parte de este plan todavía |

---

## 9. Riesgos y decisiones pendientes

- **Seguridad multi-tenant** — se prueba con datos reales de dos negocios
  antes de aceptar el primer cliente de pago.
- ✅ **Nombre de marca** — resuelto: VetMake. Pendiente registrar dominio y
  verificar marca formalmente antes de invertir en identidad visual.
- **Legal: dueño de los datos** — cada clínica es dueña de los datos de sus
  propios clientes y mascotas. Falta un término de servicio simple que lo
  diga explícitamente y una forma de exportar datos si una clínica se va.
- **Mantenimiento dual** — cuantificado en la sección 2.

---

## 10. Siguiente paso inmediato

Fase 0 está prácticamente cerrada: nombre (VetMake), rama propia
(`main`) y semilla validada en `raiz/index.html`. La base
multi-tenant de Supabase, el bloque de identidad y el onboarding comercial
inicial del frontend ya están implementados; cualquier cambio dentro de
`raiz/` pertenece a la Fase 1 de VetMake, no a PetColinas.

El flujo técnico de invitación/vinculación de usuarios de Supabase Auth ya
está implementado en `vetmake-admin` y conectado al panel de Configuración. El
frontend también procesa el enlace recibido y permite establecer o recuperar
la contraseña. El siguiente bloque es configurar el correo y la URL de
redirección de Auth, probar el primer alta real y luego completar las
credenciales de integraciones por negocio. El piloto todavía puede darse de
alta manualmente con el panel.

Solo falta una cosa de la Fase 0, y **no es algo que Claude pueda hacer**:
registrar el dominio de VetMake. Requiere una compra real con datos de pago
de Victor. Ver sección 11.

---

## 11. Registrar el dominio — pendiente, lo hace Victor

La red de esta sesión bloquea el acceso a whois y a los sitios de
registradores (Namecheap, GoDaddy, etc.), así que no hay forma de
confirmar disponibilidad desde aquí — y aunque se pudiera, registrar un
dominio es una compra real con datos de pago de Victor, no algo que Claude
deba hacer por su cuenta.

Señal indirecta a favor: durante la verificación del nombre (sección
inicial), la búsqueda no encontró ningún sitio activo en `vetmake.com`,
`vetmake.app`, ni una cuenta de Instagram `@vetmake` — eso no confirma
disponibilidad (un dominio puede estar registrado y sin usar), pero es
buena señal.

**Qué hacer:**
1. Entrar a un registrador (Namecheap, GoDaddy, o el que Victor ya use
   para dominios de PetColinas) y buscar `vetmake.com`.
2. Si está tomado, alternativas razonables en orden de preferencia:
   `vetmake.app`, `vetmake.io`, `getvetmake.com`.
3. Registrarlo aunque el desarrollo real (Fase 1) todavía no arranque —
   es barato y evita que alguien más lo tome mientras se construye.
