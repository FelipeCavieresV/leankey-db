# PostgreSQL de Leankey

## Iniciar base de datos y API

```bash
cd ~/repos/leankey-db
cp .env.example .env
# Cambia POSTGRES_PASSWORD en .env (usa caracteres seguros para una URL: letras, números, guiones).
docker compose up -d --build --wait
```

PostgreSQL 18 usa un volumen persistente en `/var/lib/postgresql`. Los SQL de `init/` se ejecutan, en orden, automáticamente **solo con un volumen vacío**. `docker compose down` conserva los datos. No uses `down -v` para actualizar: borra el volumen.

API: http://localhost:8000/api/health. Documentación interactiva: http://localhost:8000/docs.

Para ejecutar también el frontend local:

```bash
docker compose --profile web up -d --build --wait
```

Web: http://localhost:8080. Nginx reenvía `/api` al servicio `backend`, manteniendo ese prefijo. Los puertos del host están vinculados a localhost. Toda la API, salvo salud, exige sesión; el reporte importado es solo para administradores.

Para el dominio existente y su proxy externo, primero inicia este Compose (sin perfil web) y después ejecuta `docker compose up -d --build --wait` en `../leankey-front`. Ese Compose conecta el frontend a `proxy` y a `leankey_default`. No es necesario publicar PostgreSQL hacia la LAN.

## Plataforma de acreditación (003 a 012)

`003_platform.sql` crea el modelo transaccional: mandantes, sedes, políticas, contratistas, servicios, usuarios y sesiones, catálogo documental con revisiones, perfiles y matriz con vigencia temporal, trabajadores, asignaciones, versiones de evidencia, responsables de prevención, períodos mensuales, nómina, resoluciones, notificaciones, cortes diarios y auditoría de solo inserción (un trigger impide modificarla). `004_catalog.sql` carga el catálogo documental inicial y feriados 2026 editables. `005_review_fixes.sql` agrega vencimiento obligatorio por documento (`no_expiry`), presentación completa y política por período, e idempotencia de cargas por usuario. `006_governance.sql` (requerimientos v1.0, sección 01) agrega perfiles internos (LeanKey, administrador, supervisor) y alcance completo o por asignación, áreas y supervisores de contrato, módulos contratados con vigencia temporal, hallazgos, delegaciones y decisiones con aceptaciones de personas distintas (versiones y aceptaciones de solo inserción). Clasifica las cuentas internas existentes: con alcance total pasan a LeanKey; con mandantes asignados, a administrador. Las mandantes existentes quedan con la gestión documental y mensual activa desde su creación y el resto de los módulos pendiente. `007_profiles.sql` (sección 02) separa las capacidades (consulta, descarga, revisión de acreditación y de certificación laboral, sensibles médicos y laborales, tickets críticos), clasifica la sensibilidad del catálogo, agrega perfiles de prevención y seguridad, cuentas de trabajador, inhabilitación de empresas por mandante, investigaciones con medidas correctivas, movimientos asistidos (solo inserción) y tickets. La conversión de capacidades conserva lo otorgado y se ejecuta una sola vez (`schema_migrations`). `008_companies.sql` (sección 03) agrega el vínculo empresa–mandante con fecha efectiva (completado desde los servicios existentes) y el teléfono y la verificación de cuentas. `009_workforce.sql` (sección 04) crea la identidad única por RUT con código (`persons`, asignada a los trabajadores existentes), la ficha de la planilla, situaciones de ausencia o licencia, invitaciones al acceso móvil (solo el resumen del token) y el registro de mensajes salientes sin contenido; además, el anexo de traslado deja de exigir el destino (con historial de catálogo). `010_functions.sql` (sección 05) permite exigencias de una función propias de un servicio (`profile_requirements.service_id`, que prevalecen sobre la general del mismo documento), las dualidades de funciones autorizadas por la mandante con vigencia (`profile_compatibilities`), la segunda función de una asignación (`assignments.secondary_profile_id`), el horario de ingreso por servicio con historial (`service_access_schedules`) y las funciones ejercidas en cada movimiento de acceso (`access_movements.profile_ids`). `011_requirements.sql` (sección 06) agrega los mínimos exigibles por documento (`document_types.minimums`), la fecha de aplicación de cada regla de las matrices (`effective_from`/`effective_to`; sin fecha rige desde que se registró), el fundamento de cada revisión (`unmet_minimums`, `review_minimums`), las solicitudes de aplicabilidad con decisión y ejecución trazables (`applicability_requests`), y el PTS versionado con su difusión vinculada (`versioned`, `procedure_type_id`, `version_label`, `procedure_version_id`). EMP-PTS pasa a ser versionado y PTS-ALT-DIF su difusión, que ya no vence sola (con historial de catálogo, una sola vez). `012_review_operations.sql` (sección 07) agrega el archivo trazable de versiones canceladas, reemplazadas o retiradas (`archived_*`, `replaces_version_id`), el inicio y el plazo de revisión (`review_started_at`, `review_due_on`, calculado para los envíos que ya estaban en la cola) con su política configurable hacia arriba (`client_policies.review_business_days`), el mecanismo interno de revisión y la derivación a una persona (`review_mechanism`, `human_review_reason`, historial `document_reviews`), las solicitudes de nueva revisión o retiro con una sola abierta por versión y sus comentarios (`review_requests`, `review_request_comments`) y los archivos de lote pendientes de asociación (`document_staging`).

Ambos son idempotentes. En una base **existente** (volumen ya inicializado) no se ejecutan solos; aplícalos una vez:

```bash
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U leanley -d leankey < init/003_platform.sql
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U leanley -d leankey < init/004_catalog.sql
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U leanley -d leankey < init/005_review_fixes.sql
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U leanley -d leankey < init/006_governance.sql
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U leanley -d leankey < init/007_profiles.sql
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U leanley -d leankey < init/008_companies.sql
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U leanley -d leankey < init/009_workforce.sql
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U leanley -d leankey < init/010_functions.sql
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U leanley -d leankey < init/011_requirements.sql
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U leanley -d leankey < init/012_review_operations.sql
docker compose exec backend python -m app.cli create-admin correo@empresa.cl "Nombre"
```

Los archivos de evidencia se guardan en el volumen `files_data` (`/data/files` del backend). Respáldalo junto con PostgreSQL: uno sin el otro no permite restaurar.

## Tablas y datos

- `reports`: corte, archivo fuente, resumen y encabezados originales.
- `ksec_contractors`: indicadores por contratista y corte.
- `ksec_packages`: trabajadores, RUT, estado, prioridad y métricas de sus paquetes.
- `ksec_documents`: exigencias documentales, estados, fechas, comentarios y origen.
- `ksec_gaps`: brechas y acciones sugeridas del corte.
- `ksec_history`: evolución global del reporte.
- `ksec_sources`: archivos procesados.
- `ksec_criteria`: reglas y definiciones del reporte.
- `requests`: solicitudes operativas con estado y fechas.

Las siete tablas KSEC tienen columnas tipadas, clave por reporte y posición, claves foráneas y índices por contratista. Representan instantáneas del Excel, no un sistema de edición documental. Paquetes y documentos conservan sus valores originales; no se recalculan ni se inventan estados de habilitación. El seed contiene las 3.932 filas de las siete hojas del JSON existente (incluidas 297 filas de paquetes y 2.356 documentos). Solicitudes comienza vacía: las tres solicitudes anteriores eran ejemplos de interfaz, no registros reales.

`001_schema.sql` crea las tablas; `002_seed.sql` importa el corte 23/09/2026. Ambos pueden repetirse sin duplicar filas. El seed no sobrescribe un corte ya existente.

## Importar otro corte

Primero utiliza el importador Excel existente del frontend. Luego:

```bash
python3 scripts/generate_seed.py ../leankey-front/src/data/ksec.json
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U leanley -d leankey < init/001_schema.sql
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U leanley -d leankey < init/002_seed.sql
```

El reporte más reciente se selecciona por fecha; puedes consultar otro usando `?cutoff=YYYY-MM-DD`. El generador presupone las mismas columnas del importador original. No hay sincronización automática con KSEC. Las actualizaciones futuras del esquema requieren migraciones: `CREATE TABLE IF NOT EXISTS` no altera tablas existentes.

Documentación de referencia: [imagen oficial PostgreSQL](https://hub.docker.com/_/postgres) y [conexiones Psycopg](https://www.psycopg.org/psycopg3/docs/basic/usage.html).

## Documentos colectivos (013)

`init/013_collective_documents.sql` agrega originales restringidos, asignaciones confirmadas, extractos verificados y versiones individuales. Aplicar después de 012 en una base existente, con respaldo previo. No se aplica automáticamente sobre un volumen existente.

```bash
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U leanley -d leankey < init/013_collective_documents.sql
```

## Certificación laboral y decisiones de pago (014)

`init/014_labor_certification.sql` crea calendarios mensuales por servicio con matriz, validación legal, aceptación y versiones inmutables; vincula cada período a su calendario y permite fechas de carga aún no configuradas. Los períodos existentes conservan sus datos y política histórica (`calendar_legacy`); no se les inventa una fecha legal. Los nuevos períodos requieren matriz y calendario aceptados. También crea las comunicaciones inmutables de decisiones de pago y las solicitudes de revisión con una sola abierta por comunicación. Los montos y términos de retención/liberación se conservan en el detalle de las versiones de decisiones existentes.

La migración es idempotente. Aplicar después de 013, con respaldo previo, únicamente cuando se autorice el despliegue:

```bash
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U leanley -d leankey < init/014_labor_certification.sql
```

## Indicadores y universos del dashboard (015)

`init/015_compliance_kpis.sql` agrega declaraciones históricas de necesidad de equipos por servicio (`service_equipment_scopes`) y cortes documentales íntegros por servicio y día (`compliance_cuts`). Ambos son de solo inserción. Los cortes incluyen sus universos para distinguir variaciones de dotación/aplicabilidad de cumplimiento documental. La migración no inventa registros de equipos ni rellena cortes históricos anteriores con datos actuales.

Aplicar después de 014, con respaldo previo y al autorizar el despliegue:

```bash
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U leanley -d leankey < init/015_compliance_kpis.sql
```

La migración es idempotente. Las consultas históricas comprueban el alcance actual del usuario antes de cargar los cortes guardados.
