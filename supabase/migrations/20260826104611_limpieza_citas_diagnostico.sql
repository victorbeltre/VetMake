-- Retira de la agenda filas técnicas que una sincronización heredada insertó
-- como si fueran citas. La firma es deliberadamente estricta: no toca ninguna
-- cita que tenga paciente, cliente, servicio, empleado, precio o una hora real.
-- Se archiva el JSON completo antes de borrar para que la operación sea
-- recuperable incluso después de aplicar la migración.

create table if not exists private.pc_citas_diagnostico_archivo (
  negocio_id uuid not null,
  cita_id bigint not null,
  datos jsonb not null,
  motivo text not null,
  archivado_en timestamptz not null default now(),
  primary key (negocio_id, cita_id)
);

revoke all on table private.pc_citas_diagnostico_archivo from public, anon, authenticated;

insert into private.pc_citas_diagnostico_archivo (
  negocio_id,
  cita_id,
  datos,
  motivo
)
select
  cita.negocio_id,
  cita.id,
  to_jsonb(cita),
  'Fila técnica heredada: resultado de sincronización guardado en pc_citas'
from public.pc_citas as cita
where cita.tipo in ('✅ SYNC OK', '❌ PARSE ERROR', '❌ CLAUDE ERROR')
  and cita.estado = 'pendiente'
  and nullif(btrim(cita.nombremascota), '') is null
  and nullif(btrim(cita.nombrecliente), '') is null
  and nullif(btrim(cita.servicio), '') is null
  and nullif(btrim(cita.empleado), '') is null
  and cita.clienteid is null
  and coalesce(cita.precio, 0) = 0
  and nullif(btrim(cita.notas), '') is null
  and nullif(btrim(cita.motivocancelacion), '') is null
  and coalesce(cita.enespera, false) = false
  and cita.hora like '%GMT-0400%'
on conflict (negocio_id, cita_id) do nothing;

delete from public.pc_citas as cita
using private.pc_citas_diagnostico_archivo as archivo
where archivo.negocio_id = cita.negocio_id
  and archivo.cita_id = cita.id
  and cita.tipo in ('✅ SYNC OK', '❌ PARSE ERROR', '❌ CLAUDE ERROR')
  and cita.estado = 'pendiente'
  and nullif(btrim(cita.nombremascota), '') is null
  and nullif(btrim(cita.nombrecliente), '') is null
  and nullif(btrim(cita.servicio), '') is null
  and nullif(btrim(cita.empleado), '') is null
  and cita.clienteid is null
  and coalesce(cita.precio, 0) = 0
  and cita.hora like '%GMT-0400%';
