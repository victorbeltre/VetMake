# VetMake — procedencia

`index.html` es la semilla congelada que se generalizó desde el
`index.html` de PetColinas. En este repositorio ocupa la raíz y funciona como
la aplicación independiente de VetMake.

| Campo | Valor |
|---|---|
| Copiado el | 23 ago 2026 |
| Commit de origen (`main` de PetColinas) | `71f59aeb90db72d0a2c27fc5768667ce178a94b0` |
| Validación de origen | Frontend original validado: 16 pestañas, 5 componentes y sintaxis JavaScript OK |
| SHA-256 actual de `index.html` | `5af57dd2d47c30ae29bac4eec4e94b31e4cc9c6881b6bf9fcc5b59806146e581` |
| Tamaño actual | 1,668,493 bytes |
| Identidad | No es idéntico al `index.html` de PetColinas; contiene la implementación de VetMake |

## Frontera de repositorios

VetMake tiene repositorio, historial y despliegue propios. PetColinas conserva
su aplicación en producción y no forma parte de este despliegue. Los cambios
de VetMake se realizan aquí, sin sincronización automática con PetColinas.

El navegador solo contiene la clave publicable de Supabase del proyecto
`vetmake-dev`; ninguna clave `service_role` o secreta se incorpora al
frontend. La función `vetmake-admin` conserva las operaciones administrativas
en el backend protegido.

Estado de la semilla: identidad generalizada, configuración por negocio,
catálogos propios, aislamiento multi-tenant, onboarding Auth con invitación y
recuperación de contraseña, y Edge Function protegida con JWT.
