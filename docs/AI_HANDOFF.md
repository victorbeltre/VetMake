# Relevo entre Codex y Claude Code

Este archivo es la memoria operativa compartida. El agente que termina o pausa una tarea debe actualizarlo; el siguiente debe leerlo antes de trabajar.

## Estado actual

- Agente que entrega: Codex
- Rama de referencia: `main`
- Último commit conocido antes de este protocolo: `22f5b1e`
- Estado: protocolo permanente de colaboración añadido; no hay una tarea de producto activa en este relevo.

## Trabajo realizado

- Se añadieron instrucciones automáticas para Codex en `AGENTS.md`.
- Se añadieron instrucciones automáticas para Claude Code en `CLAUDE.md`.
- Se creó esta memoria común de relevo.

## Verificación

- Archivos revisados con `git diff --check`. El commit del protocolo es el commit más reciente que modifica este archivo (`git log -1 -- docs/AI_HANDOFF.md`).

## Supabase

- Sin cambios de base de datos, RLS, Storage ni Edge Functions en este relevo.

## Próximo agente

1. Ejecutar `git status` y revisar el historial reciente.
2. Leer `AGENTS.md`, `CLAUDE.md` si aplica, y este archivo.
3. Atender la siguiente petición del usuario sin rehacer funcionalidades ya publicadas.

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
