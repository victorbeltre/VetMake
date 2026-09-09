-- VetMake · Índice de auditoría para correcciones de gastos.
-- Cubre la clave foránea añadida por 20260903180000_gastos_atomicos.sql.

create index if not exists pc_gastos_ultima_correccion_por_idx
  on public.pc_gastos (ultima_correccion_por);
