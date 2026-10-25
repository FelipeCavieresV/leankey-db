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

### Permisos independientes de modificación y aprobación (028)

`init/028_independent_actions.sql`, después de 027, incorpora `edit` y `approve` a las cuentas existentes que ya realizaban esas acciones. La conversión se registra en `schema_migrations` y se ejecuta una sola vez: repetir el SQL no repone un permiso revocado. Contratistas y trabajadores no pueden recibir `approve`; los perfiles y el alcance siguen siendo obligatorios.

Requiere el backend/frontend que exigen estos permisos. Preparar respaldo y promover desde `dev` antes de aplicarla en un despliegue expresamente autorizado. La creación de cuentas demo no ejecuta esta migración en producción.

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

### 016 — Turnos y holguras

`init/016_shifts.sql` agrega programación y versiones inmutables vinculadas a decisiones, plantillas recurrentes, políticas de holguras y excepciones horarias. Los movimientos reales referencian la versión evaluada y conservan su evaluación. Las propuestas no sustituyen versiones aprobadas; los registros históricos no se actualizan ni eliminan. Los avisos externos de excepciones se registran pendientes de proveedor, sin afirmar entrega. Aplicar después de 015; validar primero en una base desechable. No ejecutar en producción sin autorización.

### 017 — Marcaciones y control de acceso

`init/017_access_control.sql` agrega políticas por instalación, QR dinámicos, identidad de persona, hora del evento, método, puerta e idempotencia al libro de movimientos. Conserva declaraciones de salida, resoluciones identificadas, incidencias y contingencias sincronizadas con revisiones inmutables. Completa metadatos de movimientos anteriores sin alterar su dirección, resultado ni fecha original. Aplicar después de 016; validar primero en PostgreSQL desechable. El registro no certifica asistencia ni transforma permanencia en horas trabajadas. No ejecutar en producción sin autorización.

### 018 — Seguridad del recinto y reporte de dotación

`init/018_security_staffing.sql` agrega vigencias de exigencia opcional por servicio, propuestas de dotación por función/franja, validaciones de mandante y reportes mensuales versionados con corte y fuentes conservadas. Todas las filas son inmutables; corregir crea nuevas propuestas o versiones. No agrega descuentos ni calcula jornadas u horas trabajadas. Aplicar después de 017 y validar primero en PostgreSQL desechable. No ejecutar en producción sin autorización.

## Vehículos, maquinaria y operadores (VEH-01 a VEH-05)

`init/019_equipment.sql`, posterior a 018, agrega identidades únicas por patente/serie, relaciones de uso con propietario y fechas, cierres, requisitos por mandante, matrices por tipo/uso con vigencia, versiones documentales privadas por mandante/contratista, revisión exclusiva de LeanKey, propuestas/resoluciones de aplicabilidad y vínculos explícitos con operadores. El libro de movimientos de equipos es independiente de marcaciones personales: una entrada sigue abierta hasta una salida registrada, aunque venza la documentación. Las tablas son de solo inserción; no se sustituyen ni eliminan evidencias anteriores.

Las matrices y funciones autorizadas se configuran mediante la aplicación; la migración no inventa documentos obligatorios ni habilita equipos por defecto. El transporte de personas no pertenece a los cuatro tipos de alcance inicial. Los cortes documentales existentes conservan su contenido; solo los nuevos cortes incorporan el universo de equipos. Aplicar primero en PostgreSQL desechable; producción requiere autorización expresa.

## Seguridad y desempeño preventivo (PRE-01 a PRE-08)

`init/020_preventive_performance.sql`, posterior a 019, separa evento consolidado y expedientes por contratista. Migra los expedientes previos a eventos individuales sin asumir investigación terminada. Agrega políticas de reportantes, antecedentes e investigación versionados, participantes y sus correcciones, evidencia privada, clasificación respaldada por emisor, revisión de investigación, ampliaciones fundadas con plazos/demora anterior, historial de acciones, correcciones revisadas, reposos iniciales/prórrogas y metadata de reportes externos ya cargados en documentos de empresa.

Las tablas nuevas son de solo inserción. Las medidas existentes conservan responsable y admiten ejecución en curso; su plazo original no se sustituye al ampliar. Los reposos vinculan restricciones existentes de dotación para conservar habilitación y programación afectada, pero los conteos preventivos solo usan sus propios respaldos, sin mezclar licencias comunes. La aplicación une fechas inclusivas por identidad de persona y deduplica eventos comunes dentro del alcance permitido. No se crean tasas, calificaciones de riesgo ni porcentajes documentales preventivos.

La migración se valida primero en PostgreSQL desechable. Repetirla no duplica los eventos migrados. Su aplicación en producción requiere autorización expresa.

## Reporte preventivo mensual (RPM-01 a RPM-05)

`init/021_preventive_monthly.sql`, después de 020, agrega vigencias de exigencia por servicio, políticas preventivas de días hábiles por mandante/período, borradores con revisión optimista, versiones mensuales enviadas y decisiones de Prevención. Exigencias, políticas, envíos y revisiones son de solo inserción. Solo el borrador puede actualizarse, sin alterar versiones enviadas o aceptadas.

La declaración del borrador puede ser nula: preparar registros no presume ausencia de eventos. Un envío conserva cifras y fuentes de eventos, personas, reposos y gestión; la aplicación consolida por identidad de evento/persona para evitar dobles conteos. Sin actividad requiere confirmación y contraste; falta de envío se informa con cifras desconocidas, no cero. Los calendarios preventivos son independientes de los SLA documentales y conservan feriados y parámetros usados por el período. La migración no crea declaraciones históricas ni reportes aceptados.

Validar primero en PostgreSQL desechable inicializado hasta 021. Su ejecución en producción requiere autorización expresa.

## Reposos, reincorporación y rectificaciones (REP-01 a REP-06)

`init/022_rest_reinstatement.sql`, después de 021, separa el flujo documental y de habilitación del reposo de la investigación del accidente. Agrega a `worker_situations` el origen (`dotacion` o `reposo_preventivo`, completado para los reposos existentes) y el levantamiento trazable (`voided_at`, `voided_by`, `void_reason`): una restricción nunca se borra ni se recorta en silencio. `prevention_rests` admite `nuevo_periodo` (prórroga y nuevo período referencian el respaldo previo) y marca `reinstatement_required`: los reposos registrados antes de 022 no exigen alta, para no bloquear ingresos de forma retroactiva.

Crea, todas de solo inserción: `rest_rectifications` y `rest_rectification_decisions` (acortar, ampliar, anular, corregir persona o datos, con motivo, respaldo, plazo prioritario y la situación que aplicaron), `rest_reinstatements` y `rest_reinstatement_reviews` (declaración o respaldo del alta, ligados al término del período que cierran, con fecha de emisión, reincorporación indicada y plazo de carga por separado), `leankey_attention_schedules` (horario de atención aprobado de LeanKey, versionado; la versión inicial es lunes a viernes de 09:00 a 18:00 sin feriados registrados) y `rest_policies` (uso de la declaración sin verificación independiente por mandante, sujeto a DEP-01; sin registro rige el acuerdo de producto). La evidencia preventiva acepta el propósito `alta`.

La migración es idempotente y no crea altas, rectificaciones ni decisiones. Validar primero en PostgreSQL desechable inicializado hasta 022. Su ejecución en producción requiere autorización expresa.

## Reportes, exportaciones y notificaciones (NOT-01 a NOT-05)

`init/023_notifications_reports.sql`, después de 022, agrega `notice_policies` (días de aviso anticipado por mandante, versionados; base 30, 15, 7 y el día del vencimiento), `notifications.resolved_at/resolution/payload` (la acción resuelta deja de recordarse y el resumen semanal conserva sus cifras) y amplía `outbound_messages` con contenido sin secretos, reintentos (`attempts`, `next_attempt_at`), `contact_issue`, la referencia del proveedor y lo que el canal verificó (`verified`: `entrega`, `lectura`). Los estados `entregada` y `leida` existen pero solo los puede fijar un evento del proveedor: `delivery_events` impide por restricción que el sistema los registre. También crea `export_jobs` (preparación en segundo plano, vencen a los 7 días), `availability_incidents` y `deadline_adjustments` (ajustes auditables de plazos de corrección por indisponibilidad). Elimina el índice único `outbound_shift_notice`: la trazabilidad por solicitud ahora usa `dedupe_key`.

Las tablas nuevas, salvo `notifications`, `outbound_messages` y `export_jobs`, son de solo inserción. La migración es idempotente y no crea avisos, ajustes ni exportaciones. Validar primero en PostgreSQL desechable inicializado hasta 023. Su ejecución en producción requiere autorización expresa.

## Atención humana y continuidad operativa (SOP-01 a SOP-04)

`init/024_support_continuity.sql`, después de 023, agrega a `leankey_attention_schedules` la zona horaria y la mandante (cobertura adicional contratada por separado) e inserta una vez la versión SOP-01: lunes a viernes de 08:30 a 17:30, hora de Santiago, sin feriados aplicables y con cobertura de colación. Los plazos ya calculados conservan la versión anterior. A `tickets` le agrega destino (`leankey` o reporte a la `mandante`), elevación (`escalated_from`), inicio del cómputo y plazo de primera respuesta con la versión del horario usada, y la primera respuesta (fecha, autor y si fue recepción o respuesta). Crea `ticket_messages`, `monitor_state`, `platform_incidents`, `platform_incident_events` y `oncall_shifts`.

Mensajes, eventos de incidentes y turnos de guardia son de solo inserción. Un incidente abierto por componente. La migración es idempotente. El Compose incluye el servicio `watchdog` (proceso aparte con la imagen del backend) que vigila API y base de datos. Validar primero en PostgreSQL desechable inicializado hasta 024. Su ejecución en producción requiere autorización expresa.

## Puesta en marcha y conservación (CIC-01 a CIC-07)

`init/025_onboarding_retention.sql`, después de 024, separa la activación por apartado y la custodia de la información. Agrega turnos de prueba (`shifts.is_test`) y el resultado `prueba` en `access_movements`: una marcación de prueba o anterior a la exigencia del control de acceso no genera presencia. Turnos y control de acceso pasan a tener fecha propia: las mandantes que ya los usaban quedan activas desde su primer uso real (primer turno aprobado o primer movimiento registrado), sin cambiar su operación; las demás siguen pendientes.

Crea `onboarding_preparations` (LeanKey prepara, el administrador confirma), `retention_terms` y `retention_terms_approvals` (términos contractuales versionados con aceptación del cliente y validación legal; plazos finitos y rotación de respaldos), `retention_cases` (expediente por persona y mandante tras la baja efectiva), `client_exits`, `retention_packages`, `retention_claims` y `retention_events` (constancia). Agrega `document_versions.disposed_at` y `files.purged_at`: la disposición elimina el contenido del archivo y conserva la constancia.

Términos, aprobaciones y eventos son de solo inserción. La migración es idempotente y no crea expedientes, entregas ni eliminaciones: los expedientes los registra el proceso diario. Validar primero en PostgreSQL desechable inicializado hasta 025. Su ejecución en producción requiere autorización expresa.

## Requisitos no funcionales (sección 21)

`init/026_nonfunctional.sql`, después de 025: desafíos TOTP, políticas por mandante, segundo factor de sesión, enlaces temporales, claves de idempotencia, bitácora de eliminaciones y simulacros inmutables. Triggers revocan sesiones ante cambios de permisos/alcance y capturan fecha local/zona IANA en cada marcación. Migración repetible; no inicia respaldos ni cambia producción. `ops/leankey-backup.*` son plantillas de servicio/temporizador que requieren configurar rutas, custodia externa, alertas y autorización antes de instalarlas. Plan y verificación en `leankey-back/docs/RNF-21.md`.

## Aceptación por etapa (ACE-01 a ACE-06)

`init/027_acceptance.sql`, después de 026: actas versionadas, evidencias, resultados, defectos/eventos y firmas de solo inserción. Relaciona módulos y preparaciones con su acta. Un trigger impide que la misma persona firme técnicamente y por la mandante, y otro bloquea la activación con defectos críticos abiertos bajo exclusión mutua por mandante/módulo. No fabrica aceptaciones para módulos históricos, no activa módulos ni despliega. Aplicación y operación: `leankey-back/docs/ACE-22.md`.

## Ayuda de acceso sin sesión (029)

`init/029_public_support.sql` agrega una bandeja independiente para solicitudes de ayuda anteriores al ingreso. Es idempotente y no modifica usuarios ni credenciales. En bases existentes, respaldar y ejecutar esta migración desde las fuentes publicadas de `main` antes de levantar el backend actualizado.

## Requerimientos por tipo de servicio y función (030)

`init/030_service_type_requirements.sql` agrega los tipos de servicio de la mandante (`service_types`, con `profiles.service_type_id` y `services.service_type_id`), la modalidad «opcional» y el detalle exigible por función en la matriz (`profile_requirements.detail`), los 15 documentos de trabajador de la planilla de requerimientos (IRL, DPS, EPP, RRI, EXO, CVA, CTE, SEC, CDS, DMP, RCX, CUC, RCE, OS1, CPS) y el visto bueno del administrador de la mandante para que Prevención consulte documentos de trabajadores (`prevention_document_access`). El nombre de una función pasa a ser único dentro de su tipo de servicio. Es idempotente; en bases existentes, respaldar y ejecutarla desde `main` antes de levantar el backend actualizado.
