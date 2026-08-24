# VetMake

SaaS independiente para la gestión de clínicas veterinarias.

Este repositorio es el código propio de VetMake. No comparte despliegue ni
historial con PetColinas.

## Estructura

- `index.html`: aplicación web de VetMake.
- `supabase/migrations/`: esquema multi-tenant versionado.
- `supabase/functions/vetmake-admin/`: onboarding protegido para invitar y
  vincular empleados.
- `docs/PLAN.md`: decisiones, estado y próximos pasos.
- `PROVENANCE.md`: procedencia de la semilla y controles de aislamiento.

## Backend

VetMake utiliza el proyecto Supabase separado `vetmake-dev`
(`couzqdicmxrypacgrqcn`). El navegador usa únicamente la clave publicable;
las claves administrativas permanecen en el entorno de Edge Functions.

## Desarrollo

La aplicación es estática y puede publicarse como un sitio de GitHub Pages.
La URL prevista para el sitio de proyecto es:

https://victorbeltre.github.io/VetMake/

Antes del primer piloto deben configurarse en Supabase Authentication → URL
Configuration la URL final, los redirects exactos y un proveedor SMTP propio.
