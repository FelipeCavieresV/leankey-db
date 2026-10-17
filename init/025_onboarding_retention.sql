-- CIC-01…07: puesta en marcha por módulos y conservación, entrega y disposición de información. Idempotente.
BEGIN;

-- CIC-02: pruebas identificadas. Un turno de prueba no se mezcla con la programación real y una marcación de
-- prueba (o anterior a la exigencia del control de acceso) no genera presencia.
ALTER TABLE shifts ADD COLUMN IF NOT EXISTS is_test boolean NOT NULL DEFAULT false;
ALTER TABLE access_movements DROP CONSTRAINT IF EXISTS access_movements_result_check;
ALTER TABLE access_movements ADD CONSTRAINT access_movements_result_check
 CHECK (result IN ('registrado','rechazado','prueba'));

-- Turnos y control de acceso pasan a tener fechas propias. Las mandantes que ya los usan quedan activas desde su
-- primer uso real (primer turno aprobado o primer movimiento registrado): no se cambia su operación ni se inventa
-- otra fecha. Las demás siguen pendientes, sin bloqueos ni incumplimientos.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT u.client_id, u.module, u.first_day FROM (
      SELECT s.client_id, 'turnos' AS module, min((v.starts_at AT TIME ZONE 'America/Santiago')::date) AS first_day
      FROM shift_versions v JOIN shifts sh ON sh.id=v.shift_id JOIN services s ON s.id=sh.service_id
      JOIN decision_requests d ON d.id=v.request_id WHERE d.state='aprobada' AND NOT sh.is_test
      GROUP BY s.client_id
      UNION ALL
      SELECT client_id, 'control_acceso', min((event_at AT TIME ZONE 'America/Santiago')::date)
      FROM access_movements WHERE result='registrado' GROUP BY client_id
    ) u
    WHERE NOT EXISTS (SELECT 1 FROM client_modules m WHERE m.client_id=u.client_id AND m.module=u.module
                      AND m.valid_to IS NULL AND m.status <> 'pendiente')
  LOOP
    UPDATE client_modules SET valid_to=now() WHERE client_id=r.client_id AND module=r.module AND valid_to IS NULL;
    INSERT INTO client_modules (client_id, module, status, enforced_from, note)
    VALUES (r.client_id, r.module, 'activo', r.first_day,
            'CIC-02: activo desde su primer uso real, registrado antes de las fechas por módulo');
  END LOOP;
END $$;

-- CIC-01: preparación de LeanKey y confirmación del administrador antes de activar un módulo.
CREATE TABLE IF NOT EXISTS onboarding_preparations (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 module text NOT NULL,
 enforced_from date NOT NULL,
 checklist jsonb NOT NULL,
 note text NOT NULL DEFAULT '',
 prepared_by bigint NOT NULL REFERENCES users(id),
 prepared_at timestamptz NOT NULL DEFAULT now(),
 decision text CHECK (decision IN ('confirmada','rechazada')),
 decided_by bigint REFERENCES users(id),
 decided_at timestamptz,
 decision_note text,
 CHECK ((decision IS NULL) = (decided_at IS NULL)),
 CHECK (decided_by IS NULL OR decided_by <> prepared_by)
);
CREATE UNIQUE INDEX IF NOT EXISTS onboarding_preparations_open
 ON onboarding_preparations(client_id, module) WHERE decision IS NULL;

-- CIC-07: términos contractuales de conservación y salida, versionados. Operan solo con aceptación del cliente y
-- validación legal específica. Plazos finitos: no hay conservación infinita ni borrado inmediato de respaldos.
CREATE TABLE IF NOT EXISTS retention_terms (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 individual_months integer NOT NULL DEFAULT 6 CHECK (individual_months BETWEEN 1 AND 120),
 notice_days integer NOT NULL DEFAULT 30 CHECK (notice_days BETWEEN 1 AND 180),
 client_delivery_business_days integer NOT NULL DEFAULT 10 CHECK (client_delivery_business_days BETWEEN 1 AND 60),
 verification_days integer NOT NULL DEFAULT 30 CHECK (verification_days BETWEEN 1 AND 180),
 backup_rotation_days integer NOT NULL CHECK (backup_rotation_days BETWEEN 1 AND 3650),
 recipient_user_ids bigint[] NOT NULL CHECK (cardinality(recipient_user_ids) > 0),
 sensitive_access text NOT NULL CHECK (length(trim(sensitive_access)) >= 5),
 delivery_format text NOT NULL CHECK (length(trim(delivery_format)) >= 5),
 reception text NOT NULL CHECK (length(trim(reception)) >= 5),
 disposal text NOT NULL CHECK (length(trim(disposal)) >= 5),
 exceptions text NOT NULL CHECK (length(trim(exceptions)) >= 5),
 created_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS retention_terms_client ON retention_terms(client_id, id DESC);
CREATE TABLE IF NOT EXISTS retention_terms_approvals (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 terms_id bigint NOT NULL REFERENCES retention_terms(id),
 kind text NOT NULL CHECK (kind IN ('cliente','legal')),
 user_id bigint NOT NULL REFERENCES users(id),
 reference text NOT NULL CHECK (length(trim(reference)) >= 3),
 at timestamptz NOT NULL DEFAULT now(),
 UNIQUE (terms_id, kind)
);

-- CIC-03/04: expediente de una persona en una mandante tras su baja efectiva.
CREATE TABLE IF NOT EXISTS retention_cases (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 worker_id bigint NOT NULL REFERENCES workers(id),
 baja_on date NOT NULL,
 due_on date NOT NULL CHECK (due_on > baja_on),
 state text NOT NULL DEFAULT 'en_conservacion'
   CHECK (state IN ('en_conservacion','reactivado','pendiente_entrega','entregado','dispuesto')),
 special_hold boolean NOT NULL DEFAULT false,
 hold_reason text,
 notice_sent_at timestamptz,
 package_id bigint,
 disposed_at timestamptz,
 disposed_by bigint REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK (NOT special_hold OR length(trim(coalesce(hold_reason,''))) >= 5),
 CHECK ((state = 'dispuesto') = (disposed_at IS NOT NULL)),
 UNIQUE (client_id, worker_id, baja_on)
);
CREATE UNIQUE INDEX IF NOT EXISTS retention_cases_open ON retention_cases(client_id, worker_id)
 WHERE state NOT IN ('reactivado','dispuesto');

-- CIC-05: salida completa de cliente.
CREATE TABLE IF NOT EXISTS client_exits (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 effective_on date NOT NULL,
 reason text NOT NULL CHECK (length(trim(reason)) >= 5),
 state text NOT NULL DEFAULT 'programada'
   CHECK (state IN ('programada','confirmada','cerrada','entregada','dispuesta','cancelada')),
 due_on date,
 requested_by bigint NOT NULL REFERENCES users(id),
 requested_at timestamptz NOT NULL DEFAULT now(),
 confirmed_by bigint REFERENCES users(id),
 confirmed_at timestamptz,
 closed_at timestamptz,
 package_id bigint,
 disposed_at timestamptz,
 disposed_by bigint REFERENCES users(id),
 CHECK (confirmed_by IS NULL OR confirmed_by <> requested_by)
);
CREATE UNIQUE INDEX IF NOT EXISTS client_exits_active ON client_exits(client_id)
 WHERE state NOT IN ('dispuesta','cancelada');

-- CIC-04/05/06: paquetes de entrega, verificación y reclamos.
CREATE TABLE IF NOT EXISTS retention_packages (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 kind text NOT NULL CHECK (kind IN ('trabajador','cliente')),
 client_id bigint NOT NULL REFERENCES clients(id),
 case_id bigint REFERENCES retention_cases(id),
 exit_id bigint REFERENCES client_exits(id),
 terms_id bigint REFERENCES retention_terms(id),
 state text NOT NULL DEFAULT 'preparando'
   CHECK (state IN ('preparando','disponible','verificado','reclamado','reemplazado','fallido','eliminado')),
 storage_key text,
 sha256 text,
 size bigint,
 index jsonb,
 sensitive boolean NOT NULL DEFAULT false,
 error text,
 replaces_id bigint REFERENCES retention_packages(id),
 created_by bigint REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 available_at timestamptz,
 verification_until timestamptz,
 downloads integer NOT NULL DEFAULT 0,
 verified_at timestamptz,
 verified_by bigint REFERENCES users(id),
 CHECK ((kind = 'trabajador') = (case_id IS NOT NULL)),
 CHECK ((kind = 'cliente') = (exit_id IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS retention_packages_case ON retention_packages(case_id, id DESC);
CREATE INDEX IF NOT EXISTS retention_packages_exit ON retention_packages(exit_id, id DESC);
CREATE TABLE IF NOT EXISTS retention_claims (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 package_id bigint NOT NULL REFERENCES retention_packages(id),
 description text NOT NULL CHECK (length(trim(description)) >= 5),
 affected jsonb NOT NULL DEFAULT '[]',
 raised_by bigint NOT NULL REFERENCES users(id),
 raised_at timestamptz NOT NULL DEFAULT now(),
 resolved_at timestamptz,
 resolved_by bigint REFERENCES users(id),
 resolution text,
 replacement_package_id bigint REFERENCES retention_packages(id),
 CHECK ((resolved_at IS NULL) = (resolution IS NULL))
);
CREATE TABLE IF NOT EXISTS retention_events (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 case_id bigint REFERENCES retention_cases(id),
 exit_id bigint REFERENCES client_exits(id),
 package_id bigint REFERENCES retention_packages(id),
 event text NOT NULL,
 detail text NOT NULL DEFAULT '',
 actor_id bigint REFERENCES users(id),
 at timestamptz NOT NULL DEFAULT now(),
 CHECK (num_nonnulls(case_id, exit_id, package_id) >= 1)
);
CREATE INDEX IF NOT EXISTS retention_events_case ON retention_events(case_id, id);
CREATE INDEX IF NOT EXISTS retention_events_exit ON retention_events(exit_id, id);

-- CIC-04/06: disposición contractual. Se elimina el contenido del archivo y queda la constancia.
ALTER TABLE document_versions ADD COLUMN IF NOT EXISTS disposed_at timestamptz;
ALTER TABLE files ADD COLUMN IF NOT EXISTS purged_at timestamptz;

DO $$ DECLARE tab text; BEGIN
 FOREACH tab IN ARRAY ARRAY['retention_terms','retention_terms_approvals','retention_events'] LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS retention_record_immutable ON %I',tab);
  EXECUTE format('CREATE TRIGGER retention_record_immutable BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION decision_records_immutable()',tab);
 END LOOP;
END $$;
COMMIT;
