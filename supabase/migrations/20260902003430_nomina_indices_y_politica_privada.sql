-- Completa el endurecimiento de nómina señalado por los asesores después de
-- aplicar la migración principal. No modifica pagos ni otros datos.

create index if not exists pc_pagos_registrado_por_idx
  on public.pc_pagos (registrado_por);

create index if not exists pc_pagos_anulado_por_idx
  on public.pc_pagos (anulado_por);

drop policy if exists vetmake_nomina_operaciones_sin_acceso_cliente
  on private.vetmake_nomina_operaciones;

create policy vetmake_nomina_operaciones_sin_acceso_cliente
  on private.vetmake_nomina_operaciones
  for all
  to public
  using (false)
  with check (false);

notify pgrst, 'reload schema';
