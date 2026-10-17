-- ACC-01…08: accesos, identidad personal y trazabilidad. No certifica asistencia.
BEGIN;
CREATE TABLE IF NOT EXISTS site_access_policies (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 site_id bigint NOT NULL REFERENCES sites(id),
 mobile_method text NOT NULL CHECK (mobile_method IN ('desactivado','gps','qr','gps_qr')),
 latitude double precision CHECK (latitude BETWEEN -90 AND 90),
 longitude double precision CHECK (longitude BETWEEN -180 AND 180),
 radius_m integer NOT NULL CHECK (radius_m BETWEEN 10 AND 5000),
 max_accuracy_m integer NOT NULL CHECK (max_accuracy_m BETWEEN 1 AND 500),
 qr_ttl_seconds integer NOT NULL CHECK (qr_ttl_seconds BETWEEN 15 AND 300),
 max_event_delay_seconds integer NOT NULL CHECK (max_event_delay_seconds BETWEEN 30 AND 300),
 assisted_allowed boolean NOT NULL,
 reentry_allowed boolean NOT NULL,
 forgotten_exit_confirmation boolean NOT NULL,
 declaration_closes_pending boolean NOT NULL,
 offline_enabled boolean NOT NULL,
 offline_max_hours integer NOT NULL CHECK (offline_max_hours BETWEEN 1 AND 72),
 reason text NOT NULL CHECK (length(trim(reason))>=5),
 configured_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK (mobile_method NOT IN ('gps','gps_qr') OR (latitude IS NOT NULL AND longitude IS NOT NULL)),
 CHECK (NOT declaration_closes_pending OR forgotten_exit_confirmation)
);
CREATE INDEX IF NOT EXISTS site_access_policies_latest ON site_access_policies(site_id,id DESC);
CREATE TABLE IF NOT EXISTS access_qr_challenges (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 site_id bigint NOT NULL REFERENCES sites(id),
 policy_id bigint NOT NULL REFERENCES site_access_policies(id),
 gate text NOT NULL,
 token_hash text NOT NULL UNIQUE,
 created_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 expires_at timestamptz NOT NULL
);
-- El trigger existente protege el libro; se suspende solo para completar los metadatos anteriores.
DROP TRIGGER IF EXISTS access_movements_no_change ON access_movements;
ALTER TABLE access_movements ADD COLUMN IF NOT EXISTS person_id bigint REFERENCES persons(id);
ALTER TABLE access_movements ADD COLUMN IF NOT EXISTS event_at timestamptz;
ALTER TABLE access_movements ADD COLUMN IF NOT EXISTS method text NOT NULL DEFAULT 'asistido'
 CHECK (method IN ('asistido','movil','declarado','regularizacion','contingencia'));
ALTER TABLE access_movements ADD COLUMN IF NOT EXISTS event_key text;
ALTER TABLE access_movements ADD COLUMN IF NOT EXISTS gate text NOT NULL DEFAULT '';
ALTER TABLE access_movements ADD COLUMN IF NOT EXISTS verification jsonb NOT NULL DEFAULT '{}';
UPDATE access_movements m SET person_id=w.person_id,event_at=m.at FROM workers w WHERE m.worker_id=w.id AND m.person_id IS NULL;
ALTER TABLE access_movements ALTER COLUMN person_id SET NOT NULL;
ALTER TABLE access_movements ALTER COLUMN event_at SET DEFAULT now();
ALTER TABLE access_movements ALTER COLUMN event_at SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS access_movements_idempotency ON access_movements(registered_by,event_key) WHERE event_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS access_movements_presence ON access_movements(person_id,client_id,event_at DESC,id DESC) WHERE result='registrado';
CREATE TRIGGER access_movements_no_change BEFORE UPDATE OR DELETE ON access_movements FOR EACH ROW EXECUTE FUNCTION decision_records_immutable();
CREATE TABLE IF NOT EXISTS access_incidents (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 service_id bigint NOT NULL REFERENCES services(id),
 worker_id bigint NOT NULL REFERENCES workers(id),
 site_id bigint REFERENCES sites(id),
 kind text NOT NULL,
 summary text NOT NULL,
 movement_id bigint REFERENCES access_movements(id),
 event_key text,
 registered_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS access_exit_declarations (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 entry_id bigint NOT NULL REFERENCES access_movements(id),
 worker_id bigint NOT NULL REFERENCES workers(id),
 service_id bigint NOT NULL REFERENCES services(id),
 declared_at timestamptz NOT NULL,
 submitted_at timestamptz NOT NULL DEFAULT now(),
 reason text NOT NULL,
 submitted_by bigint NOT NULL REFERENCES users(id),
 event_key text NOT NULL,
 policy_id bigint REFERENCES site_access_policies(id),
 requires_confirmation boolean NOT NULL,
 closes_pending boolean NOT NULL,
 UNIQUE(submitted_by,event_key)
);
CREATE UNIQUE INDEX IF NOT EXISTS access_exit_declaration_entry ON access_exit_declarations(entry_id);
CREATE TABLE IF NOT EXISTS access_exit_resolutions (
 declaration_id bigint PRIMARY KEY REFERENCES access_exit_declarations(id),
 confirmed boolean NOT NULL,
 note text NOT NULL,
 resolved_by bigint NOT NULL REFERENCES users(id),
 resolved_at timestamptz NOT NULL DEFAULT now(),
 movement_id bigint REFERENCES access_movements(id)
);
CREATE TABLE IF NOT EXISTS access_contingencies (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 service_id bigint NOT NULL REFERENCES services(id),
 worker_id bigint NOT NULL REFERENCES workers(id),
 site_id bigint NOT NULL REFERENCES sites(id),
 direction text NOT NULL CHECK (direction IN ('entrada','salida')),
 event_at timestamptz NOT NULL,
 synced_at timestamptz NOT NULL DEFAULT now(),
 event_key text NOT NULL,
 note text NOT NULL,
 captured_by bigint NOT NULL REFERENCES users(id),
 policy_id bigint NOT NULL REFERENCES site_access_policies(id),
 UNIQUE(captured_by,event_key)
);
CREATE TABLE IF NOT EXISTS access_contingency_resolutions (
 contingency_id bigint PRIMARY KEY REFERENCES access_contingencies(id),
 accepted boolean NOT NULL,
 note text NOT NULL,
 resolved_by bigint NOT NULL REFERENCES users(id),
 resolved_at timestamptz NOT NULL DEFAULT now(),
 movement_id bigint REFERENCES access_movements(id)
);
DO $$ DECLARE tab text; BEGIN
 FOREACH tab IN ARRAY ARRAY['site_access_policies','access_qr_challenges','access_incidents','access_exit_declarations','access_exit_resolutions','access_contingencies','access_contingency_resolutions'] LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS access_record_immutable ON %I',tab);
  EXECUTE format('CREATE TRIGGER access_record_immutable BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION decision_records_immutable()',tab);
 END LOOP;
END $$;
COMMIT;
