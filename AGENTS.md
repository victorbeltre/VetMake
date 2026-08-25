# VetMake — instrucciones permanentes para agentes

Estas reglas se aplican a cualquier agente que trabaje en este repositorio.

## Fuente de verdad

- El repositorio y su historial Git son la fuente de verdad. No confíes en recuerdos de conversaciones anteriores.
- Antes de trabajar, ejecuta `git status`, revisa la rama actual, lee este archivo y lee `docs/AI_HANDOFF.md`.
- Conserva cambios ajenos o sin confirmar. No los sobrescribas, reviertas ni mezcles sin entenderlos.
- VetMake está en desarrollo en GitHub Pages. No tratarlo todavía como el despliegue definitivo de producción.

## Coordinación Codex ↔ Claude

- Codex integra y publica en `main` salvo que el usuario indique otra cosa.
- Claude trabaja en una rama `claude/<tarea-corta>` y no modifica ni fusiona directamente `main`.
- Antes de crear una rama, actualiza la referencia remota y parte del último `origin/main` cuando el árbol de trabajo lo permita.
- Un agente no debe rehacer trabajo del otro. Primero inspecciona commits, diferencias y `docs/AI_HANDOFF.md`.
- Al terminar una tarea, actualiza `docs/AI_HANDOFF.md` con resultado, rama, commit, pruebas, migraciones y asuntos pendientes.
- Si se cambia de agente a mitad de una tarea, el agente saliente deja el código en un estado comprobable y documenta exactamente cómo continuar.

## Seguridad y arquitectura

- VetMake es un SaaS multiempresa. Toda información de clientes debe quedar aislada por negocio.
- En Supabase, toda tabla con datos de negocios requiere RLS y políticas verificadas. Nunca expongas claves de servicio en el navegador.
- Las migraciones de base de datos deben guardarse en `supabase/migrations/` y documentarse en el relevo.
- No presentes orientación veterinaria automatizada como diagnóstico médico. Incluye revisión humana cuando corresponda.
- No publiques, fusiones ramas ni hagas cambios externos destructivos sin estar dentro del encargo del usuario.

## Criterio de entrega

- Implementa el cambio completo, comprueba la sintaxis y prueba el flujo afectado en proporción al riesgo.
- Informa archivos modificados, pruebas realizadas, riesgos conocidos y cualquier paso manual pendiente.
- Mantén `docs/AI_HANDOFF.md` breve y actual; reemplaza el estado anterior en vez de acumular un diario interminable.

