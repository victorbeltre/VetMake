# VetMake — instrucciones para Claude Code

Lee y obedece `AGENTS.md` y `docs/AI_HANDOFF.md` antes de analizar o modificar código. Esos archivos contienen el protocolo permanente y el estado del relevo entre Claude Code y Codex.

Reglas específicas:

1. No trabajes directamente en `main` y no la fusiones. Usa una rama `claude/<tarea-corta>` creada desde el `origin/main` más reciente cuando sea seguro hacerlo.
2. No asumas que el contexto de una conversación está actualizado: comprueba Git, el código y las migraciones.
3. Al entregar, deja un commit claro y actualiza `docs/AI_HANDOFF.md` con la información necesaria para que Codex revise e integre.
4. Tu respuesta final debe indicar rama, hash del commit, archivos principales, pruebas, cambios de Supabase, riesgos y pasos exactos para Codex.
5. Si encuentras cambios locales que no son tuyos, no los elimines ni los sobrescribas; detente en la parte conflictiva y repórtala.

