# INNOVANET — Gestión comercial

Aplicación web en **React + Vite + Supabase (PostgreSQL y Auth)**, en español.

## Qué incluye

- Inicio de sesión y alta de cuentas mediante Supabase Auth.
- Módulos visibles según el rol: administrador, operador y consulta.
- Panel con métricas; proformas editables; facturas emitidas y no editables.
- Alta opcional de clientes y productos desde el documento (casillas de verificación).
- Catálogos de clientes, productos, monedas, empresa y autorizaciones CAI.
- Consecutivos de proformas y correlativos fiscales asignados con bloqueo transaccional en PostgreSQL.
- Histórico con búsquedas, filtros por estado/tipo/fechas, vista previa e impresión.
- Imprimir o **Guardar como PDF** usando el diálogo del navegador; compartir resumen usando Web Share / portapapeles.
- Diseño adaptable a PC, tableta y móvil y cambio de tema.

## 1. Crear proyecto Supabase

1. Crea un proyecto en https://supabase.com/ y espera a que esté listo.
2. Abre **SQL Editor** y ejecuta **todo** el archivo `supabase/01_esquema.sql`.
3. En **Authentication → Providers → Email**, habilita el inicio de sesión por correo. Puedes dejar activa la confirmación del correo.
4. Desde **Authentication → Users**, crea el usuario que será administrador (o crea la cuenta desde el registro de INNOVANET).
5. En **SQL Editor**, ejecuta la consulta siguiente, sustituyendo por el correo real de la cuenta admin:

```sql
update public.perfiles
set rol = 'administrador', activo = true
where id = (
  select id from auth.users where lower(email)=lower('ADMIN@TUEMPRESA.COM')
);
```

> El primer administrador **no se crea automáticamente**: esto evita que cualquiera que se registre tome control de la plataforma. Si la consulta actualiza cero filas, verifica que hayas creado primero el usuario en Authentication.

## 2. Conectar React

Requiere Node.js 20+.

```bash
npm install
cp .env.example .env
```

En Windows, también puedes duplicar `.env.example` y renombrarlo a `.env`.

En `.env` coloca los valores desde **Supabase → Project Settings → API**:

```env
VITE_SUPABASE_URL=https://tu-proyecto.supabase.co
VITE_SUPABASE_ANON_KEY=tu-clave-publica
```

Utiliza solamente la **anon / publishable key pública**: jamás incluyas la **service_role**, una secret key ni la contraseña de base de datos dentro de la aplicación o GitHub.

```bash
npm run dev
```

Abre la dirección mostrada (normalmente `http://localhost:5173`). Para una compilación de producción: `npm run build`.

## 3. Primera configuración

1. Inicia sesión con la cuenta administradora.
2. Ve a **Mi empresa**, ingresa razón social, RTN, dirección, teléfono y el impuesto que corresponda a tu actividad. El 15% inicial es una referencia editable, **no una determinación tributaria**.
3. Ve a **Control CAI** y registra un CAI real, rango, fecha límite y siguiente correlativo. Luego actívalo. El sistema bloquea emisión si venció o se agotó el rango.
4. En **Monedas**, actualiza la tasa **USD → HNL**. El valor 1 inicial **es un marcador**, no es el tipo de cambio verdadero. La tasa del documento queda congelada al guardarlo.
5. Revisa **Accesos y roles** antes de permitir el uso a terceros. Las nuevas cuentas nacen como operadores con permisos predeterminados editables.
6. Crea la primera proforma para comprobar impresión y formatos.

## 4. Flujo de documentos

**Proforma:** Nuevo documento → Proforma → agregar cliente/artículos, marcando «Guardar» cuando sea necesario → Guardar → se abre vista previa → Imprimir / PDF o Compartir. Puede reabrirse y editarse desde Historial.

**Factura:** Nuevo documento → Factura fiscal → revisar datos, CAI, rangos, impuesto y moneda → Emitir → se abre vista previa → Imprimir / PDF. Ya emitida, **no se modifica**. El administrador puede anularla y la anulación conserva su correlativo.

**Importante:** El botón «Compartir» comparte el resumen de texto del documento, **no adjunta un PDF**. Para compartir el comprobante completo, selecciona «Imprimir / PDF» y guarda el PDF para enviarlo por el canal que prefieras. No se crea un enlace público que exponga datos fiscales.

## 5. Publicar gratis en GitHub Pages

1. Crea un repositorio GitHub y sube el código **sin el archivo `.env`**.
2. Ajusta `vite.config.js` `base:'./'` ya está configurado para funcionar desde una subcarpeta.
3. Configura en GitHub Actions variables/secretos `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY` para la compilación. La clave anon/publishable es pública, pero se recomienda administrarla de forma ordenada.
4. Puedes usar cualquier despliegue estático compatible con Vite. GitHub Pages **no** aloja la base de datos; Supabase sí.
5. En Supabase Auth configura **Site URL** y las URLs de redirección autorizadas de tu dominio final.

## 6. Reglas y límites importantes

- No es una certificación de cumplimiento fiscal. Antes de emitir facturas legales en Honduras, se deben revisar las exigencias vigentes del SAR, el régimen aplicable, los requisitos del comprobante, la autorización de emisión y demás leyendas/campos exigidos. En particular, valida si el uso de este aplicativo y el formato generado está permitido para tu modalidad autorizada de facturación.
- Se almacena el snapshot de datos de la empresa y CAI al guardar: cambiar después los ajustes no altera la factura guardada.
- Se usa RLS en todas las tablas y una RPC transaccional para crear documentos. Los usuarios no pueden insertar, actualizar ni borrar facturas directamente desde el navegador.
- Los catálogos de clientes y productos son globales para una sola empresa. No hay inventario, firma digital, envío automático de emails, conversión de moneda dentro de documentos, notas de crédito, ni sincronización directa con el SAR.
- Se requiere conexión para operar: esta versión no tiene modo sin conexión.
- Para un lanzamiento comercial real deben añadirse auditoría avanzada, copias de seguridad, ajustes de retenciones/exoneraciones, reglas tributarias revisadas, control de acceso más granular (crear/leer/editar), y pruebas de concurrencia y de cumplimiento fiscal.

## Estructura

```text
INNOVANET/
├── index.html
├── package.json
├── vite.config.js
├── .env.example
├── .gitignore
├── src/
│   ├── main.jsx
│   ├── App.jsx
│   ├── supabase.js
│   └── styles.css
└── supabase/
    └── 01_esquema.sql
```
