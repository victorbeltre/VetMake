-- Conserva quién realizó el gasto. La interfaz ya solicitaba este dato, pero
-- antes se descartaba al normalizar la fila y se perdía después de recargar.

alter table public.pc_gastos
  add column if not exists pagadopor text;

do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_constraint
    where conname = 'pc_gastos_pagadopor_valido_chk'
      and conrelid = 'public.pc_gastos'::regclass
  ) then
    alter table public.pc_gastos
      add constraint pc_gastos_pagadopor_valido_chk
      check (
        pagadopor is null
        or (
          btrim(pagadopor) <> ''
          and char_length(pagadopor) <= 180
        )
      )
      not valid;
  end if;
end
$$;

comment on column public.pc_gastos.pagadopor is
  'Nombre visible del usuario o responsable que realizó el gasto.';

notify pgrst, 'reload schema';
