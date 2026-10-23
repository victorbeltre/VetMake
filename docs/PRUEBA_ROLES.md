# Prueba por roles — Clínica Demo VetMake

Clínica ficticia en `vetmake-dev` para probar con sesión real los módulos de la
rama `claude/modulos-petcolinas-oct`. Todos los datos son inventados.

## Usuarios

| Rol | Correo | Nombre en la app |
|---|---|---|
| admin | `admin@demo.vetmake.test` | Ana Admin (demo) |
| caja | `caja@demo.vetmake.test` | Carla Caja (demo) |
| veterinario | `vet@demo.vetmake.test` | Dra. Vera Vet (demo) |
| groomer | `groomer@demo.vetmake.test` | Gabo Groomer (demo) |

Las contraseñas no están en el repositorio: se entregaron al propietario.
Los correos `.test` no existen; no llega ningún correo a nadie.

Datos de partida: 3 clientes (Toby, Luna, Rocky), 4 servicios, NexGard
Spectra y Ferox en inventario, y las cuentas base de caja. Sin rangos de NCF:
registrarlos es parte de la prueba.

## Cómo abrir esta versión

GitHub Pages de VetMake no tiene todavía esta rama. Para probarla: descargar
`index.html` de la rama y abrirlo en el navegador de una computadora. La app
habla directo con `vetmake-dev`, igual que publicada.

Cada pestaña guarda su propia sesión: se puede tener admin en una pestaña y
caja en otra. Al terminar con un usuario, «Cerrar sesión».

## Guion

Marcar ✅ o ❌ y anotar lo que se vio. «Debe» es el resultado esperado.

### 1. admin
1. Configuración → Perfil comercial: escribir un RNC ficticio (`000000000`)
   y guardar. Debe salir en las facturas.
2. Configuración → Comprobantes NCF: registrar B02 del 1 al 50 y B04 del 1
   al 20 (rangos de prueba). Debe mostrar «50 disponibles».
3. Ventas: vender a Toby «Consulta general» en efectivo y NexGard Spectra.
   Debe preguntar o programar la próxima desparasitación (35 días).
4. Facturas: abrir la de Toby → «Asignar NCF» B02. Debe mostrar B0200000001.
   Imprimir: debe salir el NCF y el RNC.
5. En la misma factura → «Nota de crédito» → una parte, RD$ 100. Debe abrir
   la nota impresa con B0400000001.
6. Facturar otra venta con NCF y «Borrar» → «No, o salió con errores» → tipo
   04. Debe quedar anulada y la venta volver a aparecer para facturarse.
7. Configuración → Comprobantes NCF: el 607 del mes debe listar las facturas y
   la nota; el 608, la anulada con tipo 04.
8. Caja → Día: abrir con RD$ 500, registrar una salida de RD$ 100, cerrar
   contando lo que dice «Efectivo que debe haber». Debe cuadrar exacto.
9. Caja → Cuentas → «Bancos de la clínica»: agregar «BHD» con palabra clave
   `bhd`. Vender algo por «Transferencia BHD»: el reporte del mes debe ponerlo
   en BHD.
10. Clientes → Toby → Evolución → Resultados de laboratorio: subir una foto o
    PDF de cualquier hemograma y convertirlo. El PDF debe tener el nombre y el
    color de la clínica y nada del laboratorio.

### 2. caja
1. Debe poder vender, facturar y asignar NCF.
2. No debe ver el botón «Nota de crédito». Si intenta borrar una factura con
   NCF, el servidor debe responder que no está autorizada.
3. Caja → Día: abrir, registrar movimiento y cerrar. Debe funcionar.
4. Caja → Cuentas: debe decir que solo las ve el administrador. Reporte del
   mes: sin el bloque «Dónde cayó el dinero».
5. Configuración → Comprobantes NCF: ve los rangos, no puede registrar, no ve
   607 ni 608.

### 3. veterinario
1. Puede vender, facturar y asignar NCF; no ve «Nota de crédito».
2. Caja: igual que caja (abre, cierra, no reabre, no ve cuentas).
3. Hemogramas: puede subir y ver los resultados de laboratorio.

### 4. groomer
1. Puede registrar ventas; solo ve las suyas.
2. Facturas y Caja: el servidor debe rechazar crear facturas y abrir caja.
3. Hemogramas: no puede verlos ni subirlos.

## Resultado de la prueba automática (2026-10-23)

La misma matriz se corrió en SQL simulando la sesión de cada usuario
(transacción revertida, la base quedó como estaba):

| Función | admin | caja | veterinario | groomer |
|---|---|---|---|---|
| Ver clientes / registrar venta | ✅ | ✅ | ✅ | ✅ (solo sus ventas) |
| Crear factura / asignar NCF | ✅ | ✅ | ✅ | ❌ |
| Nota de crédito, anular fiscal, 607, 608 | ✅ | ❌ | ❌ | ❌ |
| Ver rangos NCF / registrar rango | ✅ / ✅ | ✅ / ❌ | ✅ / ❌ | ❌ / ❌ |
| Abrir, mover, resumen y cerrar caja | ✅ | ✅ | ✅ | ❌ |
| Reabrir caja, cuentas, traslados, bancos | ✅ | ❌ | ❌ | ❌ |
| Reporte de caja | ✅ con «por cuenta» | ✅ sin cuentas | ✅ sin cuentas | ❌ |
| Hemogramas (subir / ver) | ✅ | ❌ | ✅ | ❌ |

## Hallazgos para Codex

- El menú muestra todas las pestañas a todos los roles (por ejemplo, caja ve
  Nómina y Configuración); el servidor rechaza, pero la persona ve pantallas
  vacías o errores. Conviene filtrar `TABS` por rol.
- Los gastos solo los leen admin y caja: el veterinario no ve el detalle (los
  totales de caja sí le salen correctos porque se calculan en el servidor).
