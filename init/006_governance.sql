-- Requerimientos v1.0, sección 01: gobierno del servicio y alcance. Idempotente.
BEGIN;

-- Perfiles internos (GOV-02, GOV-03, GOV-05). Un usuario interno puede tener varios; el contratista ninguno.
ALTER TABLE users ADD COLUMN IF NOT EXISTS roles text[] NOT NULL DEFAULT '{}';
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_roles_valid;
ALTER TABLE users ADD CONSTRAINT users_roles_valid CHECK (
 roles <@ ARRAY['leankey','administrador','supervisor']::text[] AND (kind = 'admin' OR roles = '{}')
);
-- Cuentas internas anteriores: con alcance total son LeanKey; con mandantes asignados, administradores de esa mandante.
UPDATE users
SET roles = CASE WHEN 'all_clients' = ANY(capabilities) THEN ARRAY['leankey'] ELSE ARRAY['administrador'] END
WHERE kind = 'admin' AND roles = '{}';

-- Alcance por mandante (GOV-01). «completo»: ve toda la mandante. «asignado»: pertenece a la mandante,
-- pero solo ve los servicios que supervisa. En un usuario contratista limita las mandantes de su empresa.
ALTER TABLE user_client_scopes ADD COLUMN IF NOT EXISTS access text NOT NULL DEFAULT 'completo';
ALTER TABLE user_client_scopes DROP CONSTRAINT IF EXISTS user_client_scopes_access;
ALTER TABLE user_client_scopes ADD CONSTRAINT user_client_scopes_access CHECK (access IN ('completo','asignado'));

-- Áreas de la mandante, opcionalmente dentro de una instalación (GOV-02).
CREATE TABLE IF NOT EXISTS areas (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 site_id bigint REFERENCES sites(id),
 name text NOT NULL CHECK (length(trim(name)) > 0),
 description text NOT NULL DEFAULT '',
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS areas_unique ON areas (client_id, coalesce(site_id, 0), lower(name));
ALTER TABLE services ADD COLUMN IF NOT EXISTS area_id bigint REFERENCES areas(id);
CREATE INDEX IF NOT EXISTS services_area ON services(area_id);

-- Supervisores de contrato. Una asignación terminada se conserva; el acceso termina con ella (GOV-02).
CREATE TABLE IF NOT EXISTS service_supervisors (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 service_id bigint NOT NULL REFERENCES services(id),
 user_id bigint NOT NULL REFERENCES users(id),
 is_primary boolean NOT NULL DEFAULT false,
 assigned_at timestamptz NOT NULL DEFAULT now(),
 assigned_by bigint REFERENCES users(id),
 ended_at timestamptz,
 ended_by bigint REFERENCES users(id),
 CHECK (ended_at IS NULL OR ended_at >= assigned_at)
);
CREATE UNIQUE INDEX IF NOT EXISTS service_supervisors_current ON service_supervisors(service_id, user_id) WHERE ended_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS service_supervisors_primary ON service_supervisors(service_id) WHERE is_primary AND ended_at IS NULL;
CREATE INDEX IF NOT EXISTS service_supervisors_user ON service_supervisors(user_id) WHERE ended_at IS NULL;

-- Módulos contratados con vigencia temporal: un cambio cierra la fila anterior (GOV-04).
-- «activo» exige fecha de exigencia; antes de esa fecha el módulo está programado y no es exigible.
CREATE TABLE IF NOT EXISTS client_modules (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 module text NOT NULL CHECK (module IN ('documentacion_empresa','documentacion_trabajadores','certificacion_laboral',
   'turnos','control_acceso','seguridad_recinto','vehiculos','desempeno_preventivo')),
 status text NOT NULL CHECK (status IN ('activo','pendiente','no_aplica')),
 enforced_from date,
 note text NOT NULL DEFAULT '',
 valid_from timestamptz NOT NULL DEFAULT now(),
 valid_to timestamptz,
 changed_by bigint REFERENCES users(id),
 CHECK (status <> 'activo' OR enforced_from IS NOT NULL),
 CHECK (valid_to IS NULL OR valid_to >= valid_from)
);
CREATE UNIQUE INDEX IF NOT EXISTS client_modules_current ON client_modules(client_id, module) WHERE valid_to IS NULL;
-- Mandantes existentes: la gestión documental y mensual ya operaba desde su creación; el resto queda pendiente.
INSERT INTO client_modules (client_id, module, status, enforced_from, note, valid_from)
SELECT c.id, m.module,
       CASE WHEN m.operating THEN 'activo' ELSE 'pendiente' END,
       CASE WHEN m.operating THEN (c.created_at AT TIME ZONE 'America/Santiago')::date END,
       'Estado inicial al incorporar módulos', c.created_at
FROM clients c
CROSS JOIN (VALUES ('documentacion_empresa', true), ('documentacion_trabajadores', true),
                   ('certificacion_laboral', true), ('turnos', false), ('control_acceso', false),
                   ('seguridad_recinto', false), ('vehiculos', false), ('desempeno_preventivo', false))
           AS m(module, operating)
WHERE NOT EXISTS (SELECT 1 FROM client_modules x WHERE x.client_id = c.id AND x.module = m.module);

-- Hallazgos de LeanKey: comunican criterios incumplidos y acciones; no retienen ni autorizan (GOV-03).
CREATE TABLE IF NOT EXISTS findings (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 service_id bigint NOT NULL REFERENCES services(id),
 contractor_id bigint NOT NULL REFERENCES contractors(id),
 period_id bigint REFERENCES periods(id),
 kind text NOT NULL CHECK (kind IN ('laboral','preventivo')),
 summary text NOT NULL CHECK (length(trim(summary)) > 0),
 criteria text[] NOT NULL CHECK (cardinality(criteria) > 0),
 actions text NOT NULL CHECK (length(trim(actions)) > 0),
 created_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS findings_service ON findings(service_id, created_at DESC);

-- Delegaciones con ámbito y fechas, siempre entre cuentas personales distintas (GOV-05).
CREATE TABLE IF NOT EXISTS delegations (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 delegator_id bigint NOT NULL REFERENCES users(id),
 delegate_id bigint NOT NULL REFERENCES users(id),
 role text NOT NULL CHECK (role IN ('supervisor','administrador')),
 client_id bigint NOT NULL REFERENCES clients(id),
 service_id bigint REFERENCES services(id),
 starts_on date NOT NULL,
 ends_on date NOT NULL,
 reason text NOT NULL CHECK (length(trim(reason)) > 0),
 created_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 revoked_at timestamptz,
 revoked_by bigint REFERENCES users(id),
 CHECK (delegator_id <> delegate_id),
 CHECK (ends_on >= starts_on),
 CHECK (role = 'administrador' OR service_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS delegations_delegate ON delegations(delegate_id) WHERE revoked_at IS NULL;

-- Decisiones que requieren aceptaciones (GOV-05) y propuestas de cambio de exigencias (GOV-03).
CREATE TABLE IF NOT EXISTS decision_requests (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 service_id bigint REFERENCES services(id),
 kind text NOT NULL CHECK (kind IN ('turno','excepcion','retencion','cambio_exigencia')),
 title text NOT NULL CHECK (length(trim(title)) > 0),
 proposal text NOT NULL DEFAULT '',
 detail jsonb NOT NULL DEFAULT '{}',
 version integer NOT NULL DEFAULT 1,
 state text NOT NULL DEFAULT 'pendiente' CHECK (state IN ('pendiente','aprobada','rechazada','retirada')),
 finding_id bigint REFERENCES findings(id),
 created_by bigint REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 decided_at timestamptz,
 closing_note text NOT NULL DEFAULT '',
 CHECK (kind = 'cambio_exigencia' OR service_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS decision_requests_client ON decision_requests(client_id, state);
CREATE INDEX IF NOT EXISTS decision_requests_service ON decision_requests(service_id);

-- Contenido de cada versión: una aceptación se refiere siempre a una versión concreta.
CREATE TABLE IF NOT EXISTS decision_request_versions (
 request_id bigint NOT NULL REFERENCES decision_requests(id),
 version integer NOT NULL,
 title text NOT NULL,
 proposal text NOT NULL,
 detail jsonb NOT NULL,
 changed_by bigint REFERENCES users(id),
 changed_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (request_id, version)
);

CREATE TABLE IF NOT EXISTS decision_approvals (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 request_id bigint NOT NULL,
 version integer NOT NULL,
 role text NOT NULL CHECK (role IN ('supervisor','administrador')),
 user_id bigint NOT NULL REFERENCES users(id),
 on_behalf_of bigint NOT NULL REFERENCES users(id),
 delegation_id bigint REFERENCES delegations(id),
 decision text NOT NULL CHECK (decision IN ('aceptada','rechazada')),
 note text NOT NULL DEFAULT '',
 at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY (request_id, version) REFERENCES decision_request_versions(request_id, version),
 UNIQUE (request_id, version, role),
 UNIQUE (request_id, version, user_id),
 UNIQUE (request_id, version, on_behalf_of),
 CHECK (decision = 'aceptada' OR length(trim(note)) > 0),
 CHECK ((delegation_id IS NULL) = (user_id = on_behalf_of))
);

-- Ninguna persona participa en dos aceptaciones de la misma versión, ni directamente ni por delegación.
CREATE OR REPLACE FUNCTION decision_approvals_distinct() RETURNS trigger AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM decision_approvals a
    WHERE a.request_id = NEW.request_id AND a.version = NEW.version
      AND (a.user_id IN (NEW.user_id, NEW.on_behalf_of) OR a.on_behalf_of IN (NEW.user_id, NEW.on_behalf_of))
  ) THEN
    RAISE EXCEPTION 'Las aceptaciones de una misma versión deben ser de personas distintas'
      USING ERRCODE = 'unique_violation';
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS decision_approvals_distinct ON decision_approvals;
CREATE TRIGGER decision_approvals_distinct BEFORE INSERT ON decision_approvals
 FOR EACH ROW EXECUTE FUNCTION decision_approvals_distinct();

-- Versiones y aceptaciones registradas no se modifican ni se eliminan.
CREATE OR REPLACE FUNCTION decision_records_immutable() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION '% es de solo inserción', TG_TABLE_NAME;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS decision_approvals_no_change ON decision_approvals;
CREATE TRIGGER decision_approvals_no_change BEFORE UPDATE OR DELETE ON decision_approvals
 FOR EACH ROW EXECUTE FUNCTION decision_records_immutable();
DROP TRIGGER IF EXISTS decision_request_versions_no_change ON decision_request_versions;
CREATE TRIGGER decision_request_versions_no_change BEFORE UPDATE OR DELETE ON decision_request_versions
 FOR EACH ROW EXECUTE FUNCTION decision_records_immutable();

COMMIT;
