-- Plataforma de acreditación y certificación mensual (requerimientos v0.1).
-- Idempotente: puede aplicarse sobre una base existente sin perder datos.
BEGIN;

CREATE TABLE IF NOT EXISTS clients (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 name text NOT NULL UNIQUE CHECK (length(trim(name)) > 0),
 created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sites (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 name text NOT NULL CHECK (length(trim(name)) > 0),
 UNIQUE (client_id, name)
);

-- Política por mandante. Plazo de corrección mínimo 3 días hábiles (confirmado).
CREATE TABLE IF NOT EXISTS client_policies (
 client_id bigint PRIMARY KEY REFERENCES clients(id),
 correction_business_days integer NOT NULL DEFAULT 3 CHECK (correction_business_days >= 3),
 monthly_due_days integer NOT NULL DEFAULT 15 CHECK (monthly_due_days BETWEEN 1 AND 90),
 monthly_blocking boolean NOT NULL DEFAULT false,
 timezone text NOT NULL DEFAULT 'America/Santiago',
 version integer NOT NULL DEFAULT 1,
 updated_at timestamptz NOT NULL DEFAULT now(),
 updated_by bigint
);

CREATE TABLE IF NOT EXISTS holidays (
 day date PRIMARY KEY,
 name text NOT NULL
);

CREATE TABLE IF NOT EXISTS contractors (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 rut text NOT NULL UNIQUE CHECK (rut ~ '^[0-9]{1,9}-[0-9K]$'),
 legal_name text NOT NULL CHECK (length(trim(legal_name)) > 0),
 trade_name text NOT NULL DEFAULT '',
 contact_name text NOT NULL DEFAULT '',
 contact_email text NOT NULL DEFAULT '',
 contact_phone text NOT NULL DEFAULT '',
 created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS services (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 contractor_id bigint NOT NULL REFERENCES contractors(id),
 client_id bigint NOT NULL REFERENCES clients(id),
 site_id bigint REFERENCES sites(id),
 name text NOT NULL CHECK (length(trim(name)) > 0),
 manager text NOT NULL DEFAULT '',
 starts_on date NOT NULL,
 ends_on date CHECK (ends_on IS NULL OR ends_on >= starts_on),
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE (contractor_id, client_id, name)
);
CREATE INDEX IF NOT EXISTS services_client ON services(client_id);

CREATE TABLE IF NOT EXISTS users (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 email text NOT NULL CHECK (email = lower(email) AND email LIKE '%@%'),
 name text NOT NULL CHECK (length(trim(name)) > 0),
 password_hash text NOT NULL,
 kind text NOT NULL CHECK (kind IN ('admin','contractor')),
 contractor_id bigint REFERENCES contractors(id),
 active boolean NOT NULL DEFAULT false,
 capabilities text[] NOT NULL DEFAULT '{}',
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE (email),
 CHECK ((kind = 'contractor') = (contractor_id IS NOT NULL)),
 -- Un contratista nunca revisa, configura, administra usuarios ni ve todos los mandantes.
 CHECK (kind = 'admin' OR NOT (capabilities && ARRAY['review','configure','manage_users','all_clients']))
);

CREATE TABLE IF NOT EXISTS user_client_scopes (
 user_id bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 client_id bigint NOT NULL REFERENCES clients(id),
 PRIMARY KEY (user_id, client_id)
);

CREATE TABLE IF NOT EXISTS sessions (
 token_hash text PRIMARY KEY,
 user_id bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 created_at timestamptz NOT NULL DEFAULT now(),
 expires_at timestamptz NOT NULL,
 revoked_at timestamptz
);
CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user_id);

CREATE TABLE IF NOT EXISTS login_attempts (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 email text NOT NULL,
 at timestamptz NOT NULL DEFAULT now(),
 success boolean NOT NULL
);
CREATE INDEX IF NOT EXISTS login_attempts_email ON login_attempts(email, at);

-- Catálogo documental. scope: worker (acreditación individual), company (empresa),
-- monthly_worker y monthly_company (certificación mensual).
CREATE TABLE IF NOT EXISTS document_types (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 code text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9][A-Z0-9-]*$'),
 name text NOT NULL CHECK (length(trim(name)) > 0),
 scope text NOT NULL CHECK (scope IN ('worker','company','monthly_worker','monthly_company')),
 description text NOT NULL DEFAULT '',
 evidence text NOT NULL DEFAULT '',
 review_criteria text NOT NULL DEFAULT '',
 validity_months integer CHECK (validity_months IS NULL OR validity_months > 0),
 monthly_condition text NOT NULL DEFAULT 'siempre' CHECK (monthly_condition IN ('siempre','contrato','termino','renuncia','traslado')),
 sensitive boolean NOT NULL DEFAULT false,
 active boolean NOT NULL DEFAULT true,
 version integer NOT NULL DEFAULT 1,
 updated_at timestamptz NOT NULL DEFAULT now()
);

-- Reglas históricas del catálogo: cada cambio guarda la versión anterior.
CREATE TABLE IF NOT EXISTS document_type_revisions (
 document_type_id bigint NOT NULL REFERENCES document_types(id),
 version integer NOT NULL,
 data jsonb NOT NULL,
 valid_from timestamptz NOT NULL,
 valid_to timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (document_type_id, version)
);

CREATE TABLE IF NOT EXISTS profiles (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 name text NOT NULL CHECK (length(trim(name)) > 0),
 description text NOT NULL DEFAULT '',
 UNIQUE (client_id, name)
);

-- Matriz perfil–exigencia con vigencia temporal (no se borra, se cierra con valid_to).
-- Ausencia de fila = No aplica.
CREATE TABLE IF NOT EXISTS profile_requirements (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 profile_id bigint NOT NULL REFERENCES profiles(id),
 document_type_id bigint NOT NULL REFERENCES document_types(id),
 mode text NOT NULL CHECK (mode IN ('obligatorio','condicional')),
 condition text NOT NULL DEFAULT '',
 valid_from timestamptz NOT NULL DEFAULT now(),
 valid_to timestamptz,
 CHECK (mode = 'obligatorio' OR length(trim(condition)) > 0)
);
CREATE UNIQUE INDEX IF NOT EXISTS profile_requirements_current ON profile_requirements(profile_id, document_type_id) WHERE valid_to IS NULL;

-- Exigencias de empresa por mandante, con la misma vigencia temporal.
CREATE TABLE IF NOT EXISTS company_requirements (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 document_type_id bigint NOT NULL REFERENCES document_types(id),
 valid_from timestamptz NOT NULL DEFAULT now(),
 valid_to timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS company_requirements_current ON company_requirements(client_id, document_type_id) WHERE valid_to IS NULL;

CREATE TABLE IF NOT EXISTS workers (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 contractor_id bigint NOT NULL REFERENCES contractors(id),
 rut text NOT NULL CHECK (rut ~ '^[0-9]{1,9}-[0-9K]$'),
 name text NOT NULL CHECK (length(trim(name)) > 0),
 job_title text NOT NULL DEFAULT '',
 employment_status text NOT NULL DEFAULT 'vigente' CHECK (employment_status IN ('vigente','terminado')),
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE (contractor_id, rut)
);

-- Asignación trabajador–servicio con fechas reales (distintas de la creación).
CREATE TABLE IF NOT EXISTS assignments (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 worker_id bigint NOT NULL REFERENCES workers(id),
 service_id bigint NOT NULL REFERENCES services(id),
 profile_id bigint NOT NULL REFERENCES profiles(id),
 tasks text NOT NULL DEFAULT '',
 starts_on date NOT NULL,
 ends_on date CHECK (ends_on IS NULL OR ends_on >= starts_on),
 end_reason text CHECK (end_reason IN ('salida_servicio','termino_laboral','renuncia','traslado','cambio_perfil')),
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE (worker_id, service_id, starts_on)
);
CREATE INDEX IF NOT EXISTS assignments_service ON assignments(service_id);

-- "No aplica" de una exigencia condicional: solo administrador con configuración y motivo.
CREATE TABLE IF NOT EXISTS requirement_exemptions (
 assignment_id bigint NOT NULL REFERENCES assignments(id),
 document_type_id bigint NOT NULL REFERENCES document_types(id),
 reason text NOT NULL CHECK (length(trim(reason)) > 0),
 decided_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (assignment_id, document_type_id)
);

CREATE TABLE IF NOT EXISTS files (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 sha256 text NOT NULL,
 size integer NOT NULL CHECK (size > 0),
 mime text NOT NULL,
 original_name text NOT NULL,
 storage_key text NOT NULL,
 uploaded_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);

-- Versiones de evidencia. Cada versión se revisa por separado; client_id fija el
-- mandante en que la aprobación es válida. period = primer día del mes (mensuales).
CREATE TABLE IF NOT EXISTS document_versions (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 document_type_id bigint NOT NULL REFERENCES document_types(id),
 contractor_id bigint NOT NULL REFERENCES contractors(id),
 worker_id bigint REFERENCES workers(id),
 client_id bigint NOT NULL REFERENCES clients(id),
 period date CHECK (period IS NULL OR extract(day FROM period) = 1),
 file_id bigint NOT NULL REFERENCES files(id),
 issued_on date,
 expires_on date CHECK (expires_on IS NULL OR issued_on IS NULL OR expires_on >= issued_on),
 status text NOT NULL DEFAULT 'borrador' CHECK (status IN ('borrador','en_revision','aprobado','rechazado')),
 submitted_at timestamptz,
 reviewed_by bigint REFERENCES users(id),
 reviewed_at timestamptz,
 review_criteria text,
 rejection_reason text,
 correction_due_on date,
 revision integer NOT NULL DEFAULT 0,
 idempotency_key text UNIQUE,
 created_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK (status <> 'rechazado' OR length(trim(coalesce(rejection_reason,''))) > 0)
);
CREATE INDEX IF NOT EXISTS document_versions_worker ON document_versions(worker_id, document_type_id, client_id);
CREATE INDEX IF NOT EXISTS document_versions_company ON document_versions(contractor_id, document_type_id, client_id) WHERE worker_id IS NULL;
CREATE INDEX IF NOT EXISTS document_versions_status ON document_versions(status);

-- Responsable de prevención: el registro SEREMI se asocia al titular y su período.
CREATE TABLE IF NOT EXISTS prevention_experts (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 contractor_id bigint NOT NULL REFERENCES contractors(id),
 name text NOT NULL CHECK (length(trim(name)) > 0),
 rut text NOT NULL CHECK (rut ~ '^[0-9]{1,9}-[0-9K]$'),
 seremi_registration text NOT NULL DEFAULT '',
 file_id bigint REFERENCES files(id),
 starts_on date NOT NULL,
 ends_on date CHECK (ends_on IS NULL OR ends_on >= starts_on),
 service_ids bigint[] NOT NULL DEFAULT '{}',
 created_at timestamptz NOT NULL DEFAULT now()
);

-- Período mensual por servicio (mes cerrado).
CREATE TABLE IF NOT EXISTS periods (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 service_id bigint NOT NULL REFERENCES services(id),
 month date NOT NULL CHECK (extract(day FROM month) = 1),
 opens_on date NOT NULL,
 due_on date NOT NULL CHECK (due_on >= opens_on),
 state text NOT NULL DEFAULT 'abierto' CHECK (state IN ('abierto','presentado','observado','aprobado')),
 submitted_at timestamptz,
 submitted_by bigint REFERENCES users(id),
 resolved_at timestamptz,
 resolved_by bigint REFERENCES users(id),
 resolution_note text,
 revision integer NOT NULL DEFAULT 0,
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE (service_id, month)
);

-- Nómina del período: se conserva aunque el trabajador salga de la dotación.
CREATE TABLE IF NOT EXISTS period_payroll (
 period_id bigint NOT NULL REFERENCES periods(id),
 worker_id bigint NOT NULL REFERENCES workers(id),
 assignment_id bigint NOT NULL REFERENCES assignments(id),
 starts_on date NOT NULL,
 ends_on date,
 movement text NOT NULL DEFAULT 'continuidad',
 version integer NOT NULL DEFAULT 1,
 added_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (period_id, worker_id)
);

-- Resoluciones y reaperturas: nunca se sobrescriben.
CREATE TABLE IF NOT EXISTS period_resolutions (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 period_id bigint NOT NULL REFERENCES periods(id),
 action text NOT NULL CHECK (action IN ('presentado','aprobado','observado','reabierto')),
 note text NOT NULL DEFAULT '',
 actor_id bigint NOT NULL REFERENCES users(id),
 at timestamptz NOT NULL DEFAULT now(),
 evidence jsonb NOT NULL DEFAULT '[]'
);

CREATE TABLE IF NOT EXISTS notifications (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 user_id bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 kind text NOT NULL,
 title text NOT NULL,
 body text NOT NULL,
 link text NOT NULL DEFAULT '',
 channel text NOT NULL DEFAULT 'interna',
 delivery text NOT NULL DEFAULT 'entregado' CHECK (delivery IN ('pendiente','entregado','fallido')),
 dedupe_key text,
 created_at timestamptz NOT NULL DEFAULT now(),
 read_at timestamptz,
 UNIQUE (user_id, dedupe_key)
);
CREATE INDEX IF NOT EXISTS notifications_user ON notifications(user_id, created_at DESC);

-- Corte diario comparable para evolución (RF-04).
CREATE TABLE IF NOT EXISTS compliance_snapshots (
 day date NOT NULL,
 service_id bigint NOT NULL REFERENCES services(id),
 workers_total integer NOT NULL,
 workers_accredited integer NOT NULL,
 worker_required integer NOT NULL,
 worker_fulfilled integer NOT NULL,
 company_required integer NOT NULL,
 company_fulfilled integer NOT NULL,
 PRIMARY KEY (day, service_id)
);

-- Auditoría inalterable para usuarios ordinarios.
CREATE TABLE IF NOT EXISTS audit_events (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 at timestamptz NOT NULL DEFAULT now(),
 actor_id bigint REFERENCES users(id),
 action text NOT NULL,
 object_type text NOT NULL,
 object_id text NOT NULL,
 contractor_id bigint,
 client_id bigint,
 before jsonb,
 after jsonb
);
CREATE INDEX IF NOT EXISTS audit_events_object ON audit_events(object_type, object_id);
CREATE INDEX IF NOT EXISTS audit_events_contractor ON audit_events(contractor_id, at DESC);

CREATE OR REPLACE FUNCTION audit_events_immutable() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'audit_events es de solo inserción';
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS audit_events_no_change ON audit_events;
CREATE TRIGGER audit_events_no_change BEFORE UPDATE OR DELETE ON audit_events
 FOR EACH ROW EXECUTE FUNCTION audit_events_immutable();

COMMIT;
