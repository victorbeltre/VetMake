import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const root = path.resolve(import.meta.dirname, "..");
const failures = [];
const warnings = [];

function check(condition, message) {
  if (!condition) failures.push(message);
}

function warn(condition, message) {
  if (condition) warnings.push(message);
}

const htmlPath = path.join(root, "index.html");
check(fs.existsSync(htmlPath), "Falta index.html.");
const html = fs.readFileSync(htmlPath, "utf8");

check(/^\s*<!doctype html>/i.test(html), "index.html no declara DOCTYPE.");
check(/<html\b[^>]*\blang=["']es["']/i.test(html), "index.html no declara lang=es.");
check(/<div\s+id=["']root["']/.test(html), "Falta el contenedor #root.");
check(!/^(?:<{7}|={7}|>{7})/m.test(html), "index.html contiene marcadores de conflicto.");

const scriptTags = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)];
const inlineScripts = scriptTags.filter((match) => !/\bsrc\s*=/.test(match[1]));
const externalScripts = scriptTags.filter((match) => /\bsrc\s*=/.test(match[1]));
check(inlineScripts.length === 2, `Se esperaban 2 scripts inline y se encontraron ${inlineScripts.length}.`);

inlineScripts.forEach((match, index) => {
  try {
    new vm.Script(match[2], { filename: `index.inline-${index + 1}.js` });
  } catch (error) {
    failures.push(`Error de sintaxis en script inline ${index + 1}: ${error.message}`);
  }
});

for (const match of externalScripts) {
  const src = match[1].match(/\bsrc\s*=\s*["']([^"']+)["']/i)?.[1] || "";
  check(src.startsWith("https://"), `Dependencia externa sin HTTPS: ${src || "desconocida"}.`);
}

check(/projectRef:\s*["']couzqdicmxrypacgrqcn["']/.test(html), "El frontend no apunta al proyecto VetMake esperado.");
check(/publishableKey:\s*["']sb_publishable_/.test(html), "Falta una clave publicable moderna de Supabase.");
check(!/sb_secret_/i.test(html), "index.html contiene una clave secreta de Supabase.");
check(!/service[_-]?role/i.test(html), "index.html contiene una referencia a service role.");
check(!/gh[opsu]_[A-Za-z0-9_]{20,}/.test(html), "index.html contiene un token de GitHub.");

const migrationDir = path.join(root, "supabase", "migrations");
const migrations = fs.readdirSync(migrationDir)
  .filter((name) => name.endsWith(".sql"))
  .sort();

check(migrations.length === 39, `Se esperaban 39 migraciones y se encontraron ${migrations.length}.`);
const versions = new Set();
for (const name of migrations) {
  const match = name.match(/^(\d{14})_(.+)\.sql$/);
  check(Boolean(match), `Nombre de migración no reproducible: ${name}.`);
  if (match) {
    check(!versions.has(match[1]), `Versión de migración duplicada: ${match[1]}.`);
    versions.add(match[1]);
  }
  const sql = fs.readFileSync(path.join(migrationDir, name), "utf8");
  check(sql.trim().length > 20, `Migración vacía o incompleta: ${name}.`);
  check(!/^(?:<{7}|={7}|>{7})/m.test(sql), `Migración con marcadores de conflicto: ${name}.`);
}

const requiredMigrations = [
  "20260823141305_baseline_pc_clientes_como_petcolinas.sql",
  "20260825155630_roles_rls_auditoria.sql",
  "20260825161904_facturacion_atomica.sql",
  "20260826104606_ventas_atomicas.sql",
  "20260826104616_citas_atomicas.sql",
  "20260828151655_inventario_atomico.sql",
  "20260830212553_tarifas_atomicas.sql",
  "20260831041058_respaldo_restauracion_verificable.sql",
  "20260902003310_nomina_atomica.sql",
  "20260902173445_empleados_atomicos.sql",
  "20260903114200_gastos_atomicos.sql"
];
for (const name of requiredMigrations) {
  check(migrations.includes(name), `Falta migración crítica: ${name}.`);
}

const allSql = migrations
  .map((name) => fs.readFileSync(path.join(migrationDir, name), "utf8"))
  .join("\n");
const rpcCalls = [...html.matchAll(/supaRpc\(\s*["']([A-Za-z0-9_]+)["']/g)]
  .map((match) => match[1]);
for (const rpc of new Set(rpcCalls)) {
  const declaration = new RegExp(`create\\s+(?:or\\s+replace\\s+)?function\\s+public\\.${rpc}\\s*\\(`, "i");
  check(declaration.test(allSql), `El frontend llama la RPC ${rpc}, pero ninguna migración declara public.${rpc}().`);
}

for (const file of [
  path.join(root, "supabase", "functions", "vetmake-admin", "index.ts"),
  path.join(root, "supabase", "functions", "vetmake-intake", "index.ts")
]) {
  check(fs.existsSync(file), `Falta Edge Function versionada: ${path.relative(root, file)}.`);
  if (!fs.existsSync(file)) continue;
  const source = fs.readFileSync(file, "utf8");
  check(!/^(?:<{7}|={7}|>{7})/m.test(source), `${path.relative(root, file)} contiene marcadores de conflicto.`);
  check(!/sb_secret_[A-Za-z0-9_-]+/.test(source), `${path.relative(root, file)} contiene una clave secreta literal.`);
}

warn(/PetColinas|MASCOTAS_CASA|PETCOLINAS_RNC/.test(html), "Persisten referencias ejecutables heredadas de PetColinas.");
warn(/\/functions\/v1\/(?:vapi-trigger|calendar-sync|pagadito-cobro)/.test(html), "Persisten llamadas a integraciones no versionadas/desplegadas.");
warn((html.match(/localStorage/g) || []).length > 0, `Persisten ${(html.match(/localStorage/g) || []).length} referencias a localStorage.`);

console.log(`OK: ${inlineScripts.length} scripts inline con sintaxis válida.`);
console.log(`OK: ${migrations.length} migraciones con versiones únicas.`);
console.log(`OK: ${new Set(rpcCalls).size} RPC del frontend declaradas en SQL.`);
console.log(`OK: ${externalScripts.length} dependencias externas usan HTTPS.`);
for (const message of warnings) console.warn(`ADVERTENCIA: ${message}`);

if (failures.length) {
  for (const message of failures) console.error(`ERROR: ${message}`);
  process.exit(1);
}

console.log("Validación VetMake completada.");
