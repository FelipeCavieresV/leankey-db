-- ACE-01…06: evidencia, defectos y conformidad por módulo. No activa ni despliega módulos.
BEGIN;
CREATE TABLE IF NOT EXISTS acceptance_acts (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 module text NOT NULL,
 version integer NOT NULL CHECK (version>0),
 software_versions jsonb NOT NULL CHECK (software_versions ?& ARRAY['frontend','backend','database']),
 planned_date date NOT NULL,
 configuration_reference text NOT NULL CHECK (length(trim(configuration_reference))>=5),
 configuration_snapshot jsonb NOT NULL,
 configuration_hash text NOT NULL,
 created_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(client_id,module,version)
);
CREATE INDEX IF NOT EXISTS acceptance_acts_module ON acceptance_acts(client_id,module,id DESC);
CREATE TABLE IF NOT EXISTS acceptance_evidence (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 act_id bigint NOT NULL REFERENCES acceptance_acts(id),
 file_id bigint NOT NULL REFERENCES files(id),
 caption text NOT NULL,
 uploaded_by bigint NOT NULL REFERENCES users(id),
 at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS acceptance_results (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 act_id bigint NOT NULL REFERENCES acceptance_acts(id),
 case_key text NOT NULL,
 ace_code text NOT NULL CHECK (ace_code IN ('ACE-01','ACE-02','ACE-03','ACE-04')),
 expected text NOT NULL CHECK (length(trim(expected))>=5),
 observed text NOT NULL CHECK (length(trim(observed))>=5),
 outcome text NOT NULL CHECK (outcome IN ('aprobado','fallido','pendiente')),
 evidence_id bigint REFERENCES acceptance_evidence(id),
 evidence_reference text NOT NULL DEFAULT '',
 evidence_sha256 text NOT NULL DEFAULT '',
 metrics jsonb NOT NULL DEFAULT '{}',
 recovery_drill_id bigint REFERENCES recovery_drills(id),
 recorded_by bigint NOT NULL REFERENCES users(id),
 at timestamptz NOT NULL DEFAULT now(),
 CHECK (evidence_id IS NOT NULL OR (length(trim(evidence_reference))>=5 AND evidence_sha256 ~ '^[a-f0-9]{64}$'))
);
CREATE INDEX IF NOT EXISTS acceptance_results_current ON acceptance_results(act_id,case_key,id DESC);
CREATE TABLE IF NOT EXISTS acceptance_defects (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 module text NOT NULL,
 act_id bigint REFERENCES acceptance_acts(id),
 summary text NOT NULL CHECK (length(trim(summary))>=5),
 severity text NOT NULL CHECK (severity IN ('critico','menor')),
 impact text NOT NULL CHECK (impact IN ('exposicion_datos','ingreso_incorrecto','perdida_documentos','otro')),
 prevents_use boolean NOT NULL DEFAULT false,
 created_by bigint NOT NULL REFERENCES users(id),
 at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS acceptance_defects_scope ON acceptance_defects(client_id,module);
CREATE TABLE IF NOT EXISTS acceptance_defect_events (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 defect_id bigint NOT NULL REFERENCES acceptance_defects(id),
 state text NOT NULL CHECK (state IN ('resuelto','aceptado','reabierto')),
 reason text NOT NULL CHECK (length(trim(reason))>=5),
 owner_id bigint REFERENCES users(id),
 due_on date,
 evidence_reference text NOT NULL,
 evidence_sha256 text NOT NULL CHECK (evidence_sha256 ~ '^[a-f0-9]{64}$'),
 actor_id bigint NOT NULL REFERENCES users(id),
 at timestamptz NOT NULL DEFAULT now(),
 CHECK (state<>'aceptado' OR (owner_id IS NOT NULL AND due_on IS NOT NULL))
);
CREATE TABLE IF NOT EXISTS acceptance_attestations (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 act_id bigint NOT NULL REFERENCES acceptance_acts(id),
 kind text NOT NULL CHECK (kind IN ('tecnica','mandante')),
 technical_id bigint REFERENCES acceptance_attestations(id),
 evidence_hash text NOT NULL,
 note text NOT NULL CHECK (length(trim(note))>=5),
 user_id bigint NOT NULL REFERENCES users(id),
 at timestamptz NOT NULL DEFAULT now(),
 CHECK ((kind='mandante') = (technical_id IS NOT NULL)),
 UNIQUE(act_id,kind,evidence_hash)
);
ALTER TABLE client_modules ADD COLUMN IF NOT EXISTS acceptance_id bigint REFERENCES acceptance_acts(id);
ALTER TABLE onboarding_preparations ADD COLUMN IF NOT EXISTS acceptance_id bigint REFERENCES acceptance_acts(id);

-- Las evidencias y conformidades se corrigen con registros nuevos; nunca se reescribe el historial.
DO $$ DECLARE tab text; BEGIN
 FOREACH tab IN ARRAY ARRAY['acceptance_acts','acceptance_evidence','acceptance_results',
 'acceptance_defects','acceptance_defect_events','acceptance_attestations'] LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS acceptance_record_immutable ON %I',tab);
  EXECUTE format('CREATE TRIGGER acceptance_record_immutable BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION decision_records_immutable()',tab);
 END LOOP;
END $$;
CREATE OR REPLACE FUNCTION acceptance_distinct_signers() RETURNS trigger AS $$
DECLARE t acceptance_attestations;
BEGIN
 IF NEW.kind='mandante' THEN
  SELECT * INTO t FROM acceptance_attestations WHERE id=NEW.technical_id;
  IF t.kind<>'tecnica' OR t.act_id<>NEW.act_id OR t.user_id=NEW.user_id OR t.evidence_hash<>NEW.evidence_hash THEN
   RAISE EXCEPTION 'La conformidad exige una verificación técnica de la misma acta y otra persona';
  END IF;
 END IF;
 RETURN NEW;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS acceptance_two_people ON acceptance_attestations;
CREATE TRIGGER acceptance_two_people BEFORE INSERT ON acceptance_attestations FOR EACH ROW EXECUTE FUNCTION acceptance_distinct_signers();

-- Misma exclusión mutua para abrir/resolver defectos y activar: no hay carrera «comprobar y luego activar».
CREATE OR REPLACE FUNCTION acceptance_scope_lock() RETURNS trigger AS $$
DECLARE cid bigint; mod text;
BEGIN
 IF TG_TABLE_NAME='acceptance_defect_events' THEN
  SELECT client_id,module INTO cid,mod FROM acceptance_defects WHERE id=NEW.defect_id;
 ELSE cid:=NEW.client_id; mod:=NEW.module;
 END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('ace:'||cid||':'||mod,0));
 RETURN NEW;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS acceptance_defect_lock ON acceptance_defects;
CREATE TRIGGER acceptance_defect_lock BEFORE INSERT ON acceptance_defects FOR EACH ROW EXECUTE FUNCTION acceptance_scope_lock();
DROP TRIGGER IF EXISTS acceptance_event_lock ON acceptance_defect_events;
CREATE TRIGGER acceptance_event_lock BEFORE INSERT ON acceptance_defect_events FOR EACH ROW EXECUTE FUNCTION acceptance_scope_lock();
CREATE OR REPLACE FUNCTION acceptance_no_critical_activation() RETURNS trigger AS $$
BEGIN
 IF NEW.status='activo' AND NEW.valid_to IS NULL THEN
  PERFORM pg_advisory_xact_lock(hashtextextended('ace:'||NEW.client_id||':'||NEW.module,0));
  IF EXISTS(SELECT 1 FROM acceptance_defects d LEFT JOIN LATERAL (
   SELECT state FROM acceptance_defect_events e WHERE e.defect_id=d.id ORDER BY e.id DESC LIMIT 1
  ) e ON true WHERE d.client_id=NEW.client_id AND d.module=NEW.module
    AND (d.severity='critico' OR d.impact<>'otro' OR d.prevents_use) AND coalesce(e.state,'reabierto')<>'resuelto') THEN
   RAISE EXCEPTION 'ACE-05: un defecto bloqueante abierto impide activar el módulo';
  END IF;
 END IF;
 RETURN NEW;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS acceptance_activation_guard ON client_modules;
CREATE TRIGGER acceptance_activation_guard BEFORE INSERT OR UPDATE ON client_modules FOR EACH ROW EXECUTE FUNCTION acceptance_no_critical_activation();
COMMIT;
