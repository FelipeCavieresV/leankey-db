-- Requerimientos v1.0, sección 07: operación de revisión y correcciones. Idempotente.
BEGIN;

-- Versiones archivadas (REV-04, REV-05): cancelada antes de iniciar su revisión, reemplazada por una versión nueva
-- o retirada (aprobada) por LeanKey. Conservan archivo e historial y dejan de contar desde `archived_at`;
-- `archived_status` guarda el estado que tenían para reconstruir fechas pasadas.
ALTER TABLE document_versions DROP CONSTRAINT IF EXISTS document_versions_status_check;
ALTER TABLE document_versions ADD CONSTRAINT document_versions_status_check
 CHECK (status IN ('borrador','en_revision','aprobado','rechazado','cancelado','reemplazado','retirado'));
ALTER TABLE document_versions ADD COLUMN IF NOT EXISTS archived_at timestamptz;
ALTER TABLE document_versions ADD COLUMN IF NOT EXISTS archived_status text;
ALTER TABLE document_versions ADD COLUMN IF NOT EXISTS archive_reason text;
ALTER TABLE document_versions ADD COLUMN IF NOT EXISTS archived_by bigint REFERENCES users(id);
-- La versión nueva queda vinculada a la que reemplaza o corrige (REV-04).
ALTER TABLE document_versions ADD COLUMN IF NOT EXISTS replaces_version_id bigint REFERENCES document_versions(id);
ALTER TABLE document_versions DROP CONSTRAINT IF EXISTS document_versions_archived;
ALTER TABLE document_versions ADD CONSTRAINT document_versions_archived CHECK (
 (status IN ('cancelado','reemplazado','retirado')) = (archived_at IS NOT NULL)
 AND (archived_at IS NULL OR (archived_status IN ('borrador','en_revision','aprobado','rechazado')
  AND length(trim(coalesce(archive_reason,''))) > 0)));
CREATE INDEX IF NOT EXISTS document_versions_replaces ON document_versions(replaces_version_id)
 WHERE replaces_version_id IS NOT NULL;

-- Inicio de la revisión (REV-05: antes se puede cancelar el envío) y plazo comunicado de revisión (REV-02).
ALTER TABLE document_versions ADD COLUMN IF NOT EXISTS review_started_at timestamptz;
ALTER TABLE document_versions ADD COLUMN IF NOT EXISTS review_due_on date;
-- Mecanismo de la revisión y derivación a revisión humana (REV-01). Solo los ve LeanKey.
ALTER TABLE document_versions ADD COLUMN IF NOT EXISTS review_mechanism text;
ALTER TABLE document_versions DROP CONSTRAINT IF EXISTS document_versions_review_mechanism;
ALTER TABLE document_versions ADD CONSTRAINT document_versions_review_mechanism
 CHECK (review_mechanism IS NULL OR review_mechanism IN ('humano','automatico'));
ALTER TABLE document_versions ADD COLUMN IF NOT EXISTS human_review_reason text;

-- Plazo ordinario de revisión de LeanKey: tres días hábiles, configurable hacia arriba (REV-02).
ALTER TABLE client_policies ADD COLUMN IF NOT EXISTS review_business_days integer NOT NULL DEFAULT 3;
ALTER TABLE client_policies DROP CONSTRAINT IF EXISTS client_policies_review_business_days;
ALTER TABLE client_policies ADD CONSTRAINT client_policies_review_business_days
 CHECK (review_business_days BETWEEN 3 AND 60);

-- Historial interno de cada revisión (REV-01): mecanismo, motor y evidencia. Al exterior solo sale el resultado.
CREATE TABLE IF NOT EXISTS document_reviews (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 version_id bigint NOT NULL REFERENCES document_versions(id),
 kind text NOT NULL CHECK (kind IN ('ordinaria','nueva_revision')),
 mechanism text NOT NULL CHECK (mechanism IN ('humano','automatico')),
 decision text NOT NULL CHECK (decision IN ('aprobado','rechazado','confirmado','derivado')),
 reviewer_id bigint NOT NULL REFERENCES users(id),
 engine text,
 confidence numeric(4,3) CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
 evidence jsonb NOT NULL DEFAULT '{}',
 minimums jsonb,
 unmet jsonb,
 reason text,
 expires_on date,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS document_reviews_version ON document_reviews(version_id, created_at);

-- Solicitudes sobre una versión: nueva revisión con fundamento (REV-03) o retiro de un aprobado (REV-05).
-- Una sola abierta por versión: dos solicitudes simultáneas no conviven.
CREATE TABLE IF NOT EXISTS review_requests (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 version_id bigint NOT NULL REFERENCES document_versions(id),
 kind text NOT NULL CHECK (kind IN ('nueva_revision','retiro')),
 ground text NOT NULL CHECK (ground IN ('inconsistencia','caso_complejo','lectura_erronea','retiro')),
 justification text NOT NULL CHECK (length(trim(justification)) >= 10),
 state text NOT NULL DEFAULT 'abierta'
  CHECK (state IN ('abierta','acogida','confirmada','rechazada','cerrada_por_reemplazo')),
 prior_status text NOT NULL,
 due_on date NOT NULL,
 requested_by bigint NOT NULL REFERENCES users(id),
 resolved_by bigint REFERENCES users(id),
 resolved_at timestamptz,
 resolution text,
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK ((kind = 'retiro') = (ground = 'retiro')),
 CHECK (state = 'abierta' OR resolved_at IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS review_requests_one_open ON review_requests(version_id) WHERE state='abierta';
CREATE INDEX IF NOT EXISTS review_requests_open_due ON review_requests(due_on) WHERE state='abierta';

-- Comentarios de una solicitud: agregarlos no reinicia el plazo (REV-03).
CREATE TABLE IF NOT EXISTS review_request_comments (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 request_id bigint NOT NULL REFERENCES review_requests(id),
 author_id bigint NOT NULL REFERENCES users(id),
 body text NOT NULL CHECK (length(trim(body)) > 0),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS review_request_comments_request ON review_request_comments(request_id, created_at);

-- Archivos de un lote pendientes de asociación (REV-06): no son versiones, no cuentan ni inician plazos.
CREATE TABLE IF NOT EXISTS document_staging (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 contractor_id bigint NOT NULL REFERENCES contractors(id),
 client_id bigint NOT NULL REFERENCES clients(id),
 service_id bigint NOT NULL REFERENCES services(id),
 document_type_id bigint REFERENCES document_types(id),
 worker_id bigint REFERENCES workers(id),
 period date CHECK (period IS NULL OR extract(day FROM period) = 1),
 issued_on date,
 expires_on date,
 version_label text,
 file_id bigint NOT NULL REFERENCES files(id),
 issues jsonb NOT NULL DEFAULT '[]',
 created_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 resolved_version_id bigint REFERENCES document_versions(id),
 resolved_at timestamptz,
 discarded_at timestamptz,
 CHECK (resolved_at IS NULL OR discarded_at IS NULL)
);
CREATE INDEX IF NOT EXISTS document_staging_pending ON document_staging(contractor_id, client_id)
 WHERE resolved_at IS NULL AND discarded_at IS NULL;
-- Reintentar un lote no duplica archivos pendientes (misma clave de idempotencia por archivo).
ALTER TABLE document_staging ADD COLUMN IF NOT EXISTS idempotency_key text;
CREATE UNIQUE INDEX IF NOT EXISTS document_staging_idempotency ON document_staging(created_by, idempotency_key)
 WHERE idempotency_key IS NOT NULL;

-- Envíos que ya estaban en la cola: su plazo se cuenta desde el día hábil siguiente al envío (REV-02).
CREATE OR REPLACE FUNCTION leankey_add_business_days(start_day date, days integer) RETURNS date
 LANGUAGE plpgsql STABLE AS $$
DECLARE
 cursor_day date := start_day;
 counted integer := 0;
BEGIN
 WHILE counted < days LOOP
  cursor_day := cursor_day + 1;
  IF extract(isodow FROM cursor_day) < 6 AND NOT EXISTS (SELECT 1 FROM holidays h WHERE h.day = cursor_day) THEN
   counted := counted + 1;
  END IF;
 END LOOP;
 RETURN cursor_day;
END $$;
UPDATE document_versions v
SET review_due_on = leankey_add_business_days(
 (v.submitted_at AT TIME ZONE coalesce(
   (SELECT p.timezone FROM client_policies p WHERE p.client_id = v.client_id), 'America/Santiago'))::date,
 coalesce((SELECT p.review_business_days FROM client_policies p WHERE p.client_id = v.client_id), 3))
WHERE v.status = 'en_revision' AND v.review_due_on IS NULL AND v.submitted_at IS NOT NULL;

COMMIT;
