create table pc_clientes (
  id numeric primary key,
  nombremascota text,
  especie text,
  raza text,
  sexo text,
  fechanacimiento text,
  color text,
  tamano text,
  esterilizado boolean default false,
  nombrepropietario text,
  telefono text,
  email text,
  direccion text,
  instagram text,
  alergias text,
  medicamentos text,
  condiciones text,
  veterinarioexterno text,
  notas text,
  fecharegistro text,
  ultimavisita2025 text,
  created_at timestamptz default now(),
  cedula text,
  alertamedica text
);

alter table pc_clientes enable row level security;

create policy "pc_auth_all" on pc_clientes for all to authenticated using (true) with check (true);
create policy "pc_clientes insert formulario web" on pc_clientes for insert to anon with check (true);
