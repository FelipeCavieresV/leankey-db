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

## Plataforma de acreditación (003 y 004)

`003_platform.sql` crea el modelo transaccional: mandantes, sedes, políticas, contratistas, servicios, usuarios y sesiones, catálogo documental con revisiones, perfiles y matriz con vigencia temporal, trabajadores, asignaciones, versiones de evidencia, responsables de prevención, períodos mensuales, nómina, resoluciones, notificaciones, cortes diarios y auditoría de solo inserción (un trigger impide modificarla). `004_catalog.sql` carga el catálogo documental inicial y feriados 2026 editables.

Ambos son idempotentes. En una base **existente** (volumen ya inicializado) no se ejecutan solos; aplícalos una vez:

```bash
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U leanley -d leankey < init/003_platform.sql
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U leanley -d leankey < init/004_catalog.sql
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
