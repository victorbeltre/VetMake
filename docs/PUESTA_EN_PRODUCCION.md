# VetMake — puesta en producción (dominio, correo y Auth)

Pasos que hace Victor con sus cuentas. Lo que está en el código ya funciona con
cualquier dominio: la app arma sus enlaces con `window.location.origin`.

Propuesta de direcciones:

| Dirección | Qué sirve |
| --- | --- |
| `vetmake.com` (o el dominio que se compre) | Página de ventas (landing) |
| `app.vetmake.com` | La app (este repositorio, GitHub Pages) |
| `hola@vetmake.com` | Remitente de invitaciones y recuperación de contraseña |

## 1. Comprar el dominio

- Opción barata: un `.com` en Cloudflare Registrar (precio de costo, sin
  recargo de renovación). Comprobar primero que el nombre esté libre.
- `.do` / `.com.do`: se compra en NIC.do; da presencia local pero el trámite es
  más lento y no todos los proveedores de DNS lo manejan.
- Usar Cloudflare como DNS (gratis) en cualquiera de los dos casos.

## 2. La app en `app.vetmake.com` (GitHub Pages)

1. En el DNS: registro `CNAME` `app` → `victorbeltre.github.io` (en Cloudflare,
   nube GRIS: «DNS only», si no GitHub no puede emitir el certificado).
2. GitHub → repo VetMake → Settings → Pages → Custom domain: `app.vetmake.com`
   → Save. GitHub crea el archivo `CNAME` en la rama publicada.
3. Esperar el certificado y marcar **Enforce HTTPS**.
4. Comprobar que `https://app.vetmake.com` abre la app y que la vieja
   `https://victorbeltre.github.io/VetMake/` redirige sola.

## 3. Supabase Auth (proyecto `vetmake-dev`)

Authentication → URL Configuration:

- **Site URL:** `https://app.vetmake.com`
- **Redirect URLs:** `https://app.vetmake.com`, `https://app.vetmake.com/**` y,
  mientras dure la transición, `https://victorbeltre.github.io/VetMake/**`.

Edge Functions → Secrets: `VETMAKE_SITE_URL = https://app.vetmake.com` (lo usa
`vetmake-admin` para el enlace de las invitaciones).

## 4. Correo propio para invitaciones (gratis)

Sin SMTP propio, Supabase solo manda unos pocos correos por hora y desde una
dirección genérica: las invitaciones a empleados fallan o caen en spam.

Con Resend (plan gratis: 3,000 correos al mes, 100 por día, 1 dominio):

1. Crear cuenta en resend.com → Domains → Add domain → `vetmake.com`.
2. Copiar al DNS los registros que da Resend (SPF/MX y DKIM) y esperar
   «Verified».
3. API Keys → crear una con permiso «Sending access».
4. Supabase → Authentication → Emails → SMTP Settings → Enable custom SMTP:
   - Sender email: `hola@vetmake.com` · Sender name: `VetMake`
   - Host: `smtp.resend.com` · Port: `465` · Username: `resend`
   - Password: la API key de Resend
5. Authentication → Rate Limits: subir «emails per hour» (ej. 60).
6. Plantillas (Authentication → Emails → Templates): poner en español la de
   invitación y la de recuperación.
7. Probar: invitar un empleado de la Clínica Demo y recuperar una contraseña.

## 5. Antes de la primera clínica real

- [ ] Desplegar la Edge Function `vetmake-admin` (comprueba el cupo del plan).
- [ ] Escribir los datos bancarios en Panel VetMake → «Datos para transferir».
- [ ] Prueba con sesión real por cada rol (`docs/PRUEBA_ROLES.md`).
- [ ] Generar y probar un respaldo: `probar_respaldo_negocio()` debe dar
      `exito: true` y `tablas_sin_respaldo: []`.
- [ ] Las tablas `fit13_*` de otra aplicación siguen en `vetmake-dev`: moverlas
      a su propio proyecto (no se borraron por ser datos ajenos).
- [ ] Protección de contraseñas filtradas (Auth → Passwords): Supabase la
      ofrece en planes de pago; activarla al pasar a plan Pro.
