-- Requerimientos v1.0, sección 06: exigencias y revisión documental. Idempotente.
BEGIN;

-- Mínimos exigibles comunicados por documento (DOC-01, DOC-03): la revisión solo puede rechazar citándolos.
ALTER TABLE document_types ADD COLUMN IF NOT EXISTS minimums jsonb NOT NULL DEFAULT '[]';
ALTER TABLE document_types DROP CONSTRAINT IF EXISTS document_types_minimums_array;
ALTER TABLE document_types ADD CONSTRAINT document_types_minimums_array CHECK (jsonb_typeof(minimums) = 'array');
-- Procedimientos versionados y difusiones vinculadas (DOC-08). Una difusión (documento del trabajador) apunta al
-- procedimiento de empresa que difunde.
ALTER TABLE document_types ADD COLUMN IF NOT EXISTS versioned boolean NOT NULL DEFAULT false;
ALTER TABLE document_types ADD COLUMN IF NOT EXISTS procedure_type_id bigint REFERENCES document_types(id);

-- Versión declarada del procedimiento, versión difundida y fundamento de la revisión (DOC-03, DOC-08).
ALTER TABLE document_versions ADD COLUMN IF NOT EXISTS version_label text;
ALTER TABLE document_versions ADD COLUMN IF NOT EXISTS procedure_version_id bigint REFERENCES document_versions(id);
ALTER TABLE document_versions ADD COLUMN IF NOT EXISTS unmet_minimums jsonb;
ALTER TABLE document_versions ADD COLUMN IF NOT EXISTS review_minimums jsonb;
CREATE INDEX IF NOT EXISTS document_versions_procedure ON document_versions(procedure_version_id)
 WHERE procedure_version_id IS NOT NULL;

-- Fecha de aplicación de cada regla (DOC-01, DOC-05). Sin fecha, la regla aplica desde que se registró. Un cambio
-- programado agrega la regla nueva con `effective_from` y termina la anterior con `effective_to` (día previo).
ALTER TABLE profile_requirements ADD COLUMN IF NOT EXISTS effective_from date;
ALTER TABLE profile_requirements ADD COLUMN IF NOT EXISTS effective_to date;
ALTER TABLE profile_requirements DROP CONSTRAINT IF EXISTS profile_requirements_effective;
ALTER TABLE profile_requirements ADD CONSTRAINT profile_requirements_effective
 CHECK (effective_to IS NULL OR effective_from IS NULL OR effective_to >= effective_from);
DROP INDEX IF EXISTS profile_requirements_scope_current;
CREATE UNIQUE INDEX IF NOT EXISTS profile_requirements_scope_effective ON profile_requirements
 (profile_id, document_type_id, coalesce(service_id, 0), coalesce(effective_from, '-infinity'::date))
 WHERE valid_to IS NULL;

ALTER TABLE company_requirements ADD COLUMN IF NOT EXISTS effective_from date;
ALTER TABLE company_requirements ADD COLUMN IF NOT EXISTS effective_to date;
ALTER TABLE company_requirements DROP CONSTRAINT IF EXISTS company_requirements_effective;
ALTER TABLE company_requirements ADD CONSTRAINT company_requirements_effective
 CHECK (effective_to IS NULL OR effective_from IS NULL OR effective_to >= effective_from);
DROP INDEX IF EXISTS company_requirements_current;
CREATE UNIQUE INDEX IF NOT EXISTS company_requirements_effective_current ON company_requirements
 (client_id, document_type_id, coalesce(effective_from, '-infinity'::date))
 WHERE valid_to IS NULL;

-- Solicitudes de aplicabilidad (DOC-06, DOC-07): el contratista pide con motivo y respaldo, el administrador de la
-- mandante decide (permanente o hasta una fecha) y LeanKey ejecuta. Solo una ejecutada deja fuera la exigencia,
-- y solo entre sus fechas: al terminar vuelve al denominador.
CREATE TABLE IF NOT EXISTS applicability_requests (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 contractor_id bigint NOT NULL REFERENCES contractors(id),
 service_id bigint REFERENCES services(id),
 worker_id bigint REFERENCES workers(id),
 document_type_id bigint NOT NULL REFERENCES document_types(id),
 subject text NOT NULL CHECK (subject IN ('persona','empresa','servicio')),
 reason text NOT NULL CHECK (length(trim(reason)) >= 5),
 file_id bigint NOT NULL REFERENCES files(id),
 requested_by bigint NOT NULL REFERENCES users(id),
 requested_at timestamptz NOT NULL DEFAULT now(),
 state text NOT NULL DEFAULT 'pendiente' CHECK (state IN ('pendiente','rechazada','aprobada','ejecutada')),
 decided_by bigint REFERENCES users(id),
 decided_at timestamptz,
 decision_note text NOT NULL DEFAULT '',
 starts_on date,
 ends_on date,
 executed_by bigint REFERENCES users(id),
 executed_at timestamptz,
 CHECK ((subject = 'persona') = (worker_id IS NOT NULL)),
 CHECK (subject <> 'servicio' OR service_id IS NOT NULL),
 CHECK (ends_on IS NULL OR starts_on IS NULL OR ends_on >= starts_on),
 CHECK (state = 'pendiente' OR (decided_by IS NOT NULL AND length(trim(decision_note)) >= 5)),
 CHECK (state NOT IN ('aprobada','ejecutada') OR starts_on IS NOT NULL),
 CHECK (state <> 'ejecutada' OR (executed_by IS NOT NULL AND executed_by <> decided_by))
);
CREATE INDEX IF NOT EXISTS applicability_requests_client ON applicability_requests(client_id, state);
CREATE INDEX IF NOT EXISTS applicability_requests_contractor ON applicability_requests(contractor_id, state);

-- El PTS se conserva como documento de empresa versionado; su difusión al trabajador se vincula a una versión y
-- deja de vencer por sí sola: queda desactualizada cuando rige una versión nueva del procedimiento (DOC-08).
-- Como todo cambio de catálogo, se guarda la regla anterior en el historial.
DO $$
DECLARE
  t record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE name = '011_pts') THEN
    FOR t IN SELECT * FROM document_types WHERE code IN ('EMP-PTS', 'PTS-ALT-DIF') LOOP
      INSERT INTO document_type_revisions (document_type_id, version, data, valid_from)
      VALUES (t.id, t.version, jsonb_build_object(
        'code', t.code, 'name', t.name, 'scope', t.scope, 'description', t.description, 'evidence', t.evidence,
        'review_criteria', t.review_criteria, 'validity_months', t.validity_months, 'no_expiry', t.no_expiry,
        'monthly_condition', t.monthly_condition, 'sensitive', t.sensitive, 'sensitivity', t.sensitivity,
        'active', t.active, 'minimums', t.minimums, 'versioned', t.versioned,
        'procedure_type_id', t.procedure_type_id), t.updated_at)
      ON CONFLICT DO NOTHING;
    END LOOP;
    UPDATE document_types
    SET versioned = true, version = version + 1, updated_at = now()
    WHERE code = 'EMP-PTS';
    UPDATE document_types d
    SET procedure_type_id = p.id, no_expiry = true, version = d.version + 1, updated_at = now()
    FROM document_types p
    WHERE d.code = 'PTS-ALT-DIF' AND p.code = 'EMP-PTS';
    INSERT INTO schema_migrations (name) VALUES ('011_pts');
  END IF;
END $$;

COMMIT;
