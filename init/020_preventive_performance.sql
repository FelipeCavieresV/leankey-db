-- PRE-01…08: evento consolidado, expedientes privados y consecuencias administrativas.
BEGIN;
CREATE TABLE IF NOT EXISTS prevention_events (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 created_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE investigations ADD COLUMN IF NOT EXISTS event_id bigint REFERENCES prevention_events(id);
DO $$ DECLARE r record; eid bigint; BEGIN
 FOR r IN SELECT id,client_id,created_by,created_at FROM investigations WHERE event_id IS NULL LOOP
  INSERT INTO prevention_events(client_id,created_by,created_at) VALUES(r.client_id,r.created_by,r.created_at) RETURNING id INTO eid;
  UPDATE investigations SET event_id=eid WHERE id=r.id;
 END LOOP;
END $$;
ALTER TABLE investigations ALTER COLUMN event_id SET NOT NULL;
CREATE INDEX IF NOT EXISTS investigations_event ON investigations(event_id);
CREATE TABLE IF NOT EXISTS prevention_policies (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 contractor_reporting boolean NOT NULL,
 reporter_roles text[] NOT NULL CHECK(reporter_roles <@ ARRAY['administrador','supervisor','prevencion']::text[]),
 reason text NOT NULL,
 configured_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS prevention_evidence (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 investigation_id bigint NOT NULL REFERENCES investigations(id),
 purpose text NOT NULL CHECK(purpose IN ('investigacion','clasificacion','reposo','reapertura','correccion')),
 file_id bigint NOT NULL REFERENCES files(id),
 sensitivity text NOT NULL CHECK(sensitivity IN ('ninguna','medica','laboral')),
 note text NOT NULL,
 uploaded_by bigint NOT NULL REFERENCES users(id),
 uploaded_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS prevention_reports (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 investigation_id bigint NOT NULL REFERENCES investigations(id),
 occurred_at timestamptz,
 site_id bigint REFERENCES sites(id),
 place text NOT NULL DEFAULT '',
 function_performed text NOT NULL DEFAULT '',
 description text NOT NULL,
 immediate_measures text NOT NULL DEFAULT '',
 people_complete boolean NOT NULL DEFAULT false,
 reported_classification text NOT NULL CHECK(reported_classification IN ('trabajo','trayecto','otro','pendiente')),
 investigation_text text NOT NULL DEFAULT '',
 investigation_complete boolean NOT NULL DEFAULT false,
 evidence_id bigint REFERENCES prevention_evidence(id),
 recorded_by bigint NOT NULL REFERENCES users(id),
 recorded_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS prevention_reports_case ON prevention_reports(investigation_id,id DESC);
CREATE TABLE IF NOT EXISTS prevention_participants (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 investigation_id bigint NOT NULL REFERENCES investigations(id),
 worker_id bigint REFERENCES workers(id),
 name text NOT NULL,
 external_reference text NOT NULL DEFAULT '',
 created_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS prevention_case_worker ON prevention_participants(investigation_id,worker_id) WHERE worker_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS prevention_case_external ON prevention_participants(investigation_id,external_reference) WHERE external_reference<>'';
CREATE TABLE IF NOT EXISTS prevention_participant_versions (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 participant_id bigint NOT NULL REFERENCES prevention_participants(id),
 injured boolean NOT NULL,
 active boolean NOT NULL DEFAULT true,
 function_performed text NOT NULL,
 reason text NOT NULL,
 recorded_by bigint NOT NULL REFERENCES users(id),
 recorded_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS prevention_classifications (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 investigation_id bigint NOT NULL REFERENCES investigations(id),
 classification text NOT NULL CHECK(classification IN ('trabajo','trayecto','otro','pendiente')),
 status text NOT NULL CHECK(status IN ('pendiente','respaldada')),
 issuer text NOT NULL,
 evidence_id bigint REFERENCES prevention_evidence(id),
 reason text NOT NULL,
 recorded_by bigint NOT NULL REFERENCES users(id),
 recorded_at timestamptz NOT NULL DEFAULT now(),
 CHECK(status<>'respaldada' OR (classification<>'pendiente' AND evidence_id IS NOT NULL AND length(trim(issuer))>0))
);
CREATE TABLE IF NOT EXISTS prevention_investigation_reviews (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 report_id bigint NOT NULL REFERENCES prevention_reports(id),
 decision text NOT NULL CHECK(decision IN ('aprobado','observado')),
 participant_versions bigint[] NOT NULL DEFAULT '{}',
 note text NOT NULL,
 reviewed_by bigint NOT NULL REFERENCES users(id),
 reviewed_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(report_id)
);
ALTER TABLE prevention_investigation_reviews ADD COLUMN IF NOT EXISTS participant_versions bigint[] NOT NULL DEFAULT '{}';
ALTER TABLE corrective_measures DROP CONSTRAINT IF EXISTS corrective_measures_state_check;
ALTER TABLE corrective_measures ADD CONSTRAINT corrective_measures_state_check CHECK(state IN ('pendiente','en_ejecucion','en_validacion','observada','cerrada'));
ALTER TABLE corrective_measures ADD COLUMN IF NOT EXISTS responsible_name text NOT NULL DEFAULT '';
UPDATE corrective_measures m SET responsible_name=u.name FROM users u WHERE u.id=m.created_by AND m.responsible_name='';
CREATE TABLE IF NOT EXISTS prevention_measure_history (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 measure_id bigint NOT NULL REFERENCES corrective_measures(id),
 payload jsonb NOT NULL,
 reason text NOT NULL,
 author_id bigint NOT NULL REFERENCES users(id),
 at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS prevention_extensions (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 measure_id bigint NOT NULL REFERENCES corrective_measures(id),
 previous_due_on date NOT NULL,
 requested_due_on date NOT NULL CHECK(requested_due_on>previous_due_on),
 overdue_days_at_request integer NOT NULL CHECK(overdue_days_at_request>=0),
 reason text NOT NULL,
 requested_by bigint NOT NULL REFERENCES users(id),
 requested_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS prevention_extension_decisions (
 extension_id bigint PRIMARY KEY REFERENCES prevention_extensions(id),
 approved boolean NOT NULL,
 overdue_days_at_decision integer NOT NULL CHECK(overdue_days_at_decision>=0),
 reason text NOT NULL,
 decided_by bigint NOT NULL REFERENCES users(id),
 decided_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS prevention_case_history (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 investigation_id bigint NOT NULL REFERENCES investigations(id),
 action text NOT NULL,
 reason text NOT NULL,
 evidence_id bigint REFERENCES prevention_evidence(id),
 payload jsonb NOT NULL DEFAULT '{}',
 author_id bigint NOT NULL REFERENCES users(id),
 at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS prevention_corrections (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 investigation_id bigint NOT NULL REFERENCES investigations(id),
 kind text NOT NULL CHECK(kind IN ('anular','duplicado','restaurar')),
 duplicate_of bigint REFERENCES investigations(id),
 reason text NOT NULL,
 requested_by bigint NOT NULL REFERENCES users(id),
 requested_at timestamptz NOT NULL DEFAULT now(),
 CHECK((kind='duplicado')=(duplicate_of IS NOT NULL)),
 CHECK(duplicate_of IS NULL OR duplicate_of<>investigation_id)
);
CREATE TABLE IF NOT EXISTS prevention_correction_decisions (
 correction_id bigint PRIMARY KEY REFERENCES prevention_corrections(id),
 approved boolean NOT NULL,
 reason text NOT NULL,
 decided_by bigint NOT NULL REFERENCES users(id),
 decided_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS prevention_rests (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 participant_id bigint NOT NULL REFERENCES prevention_participants(id),
 kind text NOT NULL CHECK(kind IN ('inicial','prorroga')),
 previous_id bigint REFERENCES prevention_rests(id),
 starts_on date NOT NULL,
 ends_on date NOT NULL CHECK(ends_on>=starts_on),
 issuer text NOT NULL,
 evidence_id bigint NOT NULL REFERENCES prevention_evidence(id),
 situation_id bigint REFERENCES worker_situations(id),
 recorded_by bigint NOT NULL REFERENCES users(id),
 recorded_at timestamptz NOT NULL DEFAULT now(),
 CHECK((kind='prorroga')=(previous_id IS NOT NULL))
);
CREATE TABLE IF NOT EXISTS prevention_external_reports (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 document_version_id bigint NOT NULL REFERENCES document_versions(id),
 report_kind text NOT NULL DEFAULT 'siniestralidad' CHECK(report_kind IN ('siniestralidad','accidentabilidad','ambos')),
 starts_on date NOT NULL,
 ends_on date NOT NULL CHECK(ends_on>=starts_on),
 issuer text NOT NULL,
 recorded_by bigint NOT NULL REFERENCES users(id),
 recorded_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE prevention_external_reports ADD COLUMN IF NOT EXISTS report_kind text NOT NULL DEFAULT 'siniestralidad' CHECK(report_kind IN ('siniestralidad','accidentabilidad','ambos'));
DO $$ DECLARE tab text; BEGIN
 FOREACH tab IN ARRAY ARRAY['prevention_events','prevention_policies','prevention_evidence','prevention_reports','prevention_participants','prevention_participant_versions','prevention_classifications','prevention_investigation_reviews','prevention_measure_history','prevention_extensions','prevention_extension_decisions','prevention_case_history','prevention_corrections','prevention_correction_decisions','prevention_rests','prevention_external_reports'] LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS prevention_record_immutable ON %I',tab);
  EXECUTE format('CREATE TRIGGER prevention_record_immutable BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION decision_records_immutable()',tab);
 END LOOP;
END $$;
COMMIT;
