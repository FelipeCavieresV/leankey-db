-- Sección 11: programación versionada, independiente de marcaciones reales.
BEGIN;
CREATE TABLE IF NOT EXISTS shifts (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 service_id bigint NOT NULL REFERENCES services(id),
 created_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS shift_versions (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 shift_id bigint NOT NULL REFERENCES shifts(id),
 version integer NOT NULL CHECK (version > 0),
 request_id bigint NOT NULL UNIQUE REFERENCES decision_requests(id),
 worker_id bigint NOT NULL REFERENCES workers(id),
 profile_id bigint NOT NULL REFERENCES profiles(id),
 site_id bigint NOT NULL REFERENCES sites(id),
 starts_at timestamptz NOT NULL,
 ends_at timestamptz NOT NULL,
 effective_from timestamptz NOT NULL,
 replacement_kind text CHECK (replacement_kind IN ('temporal','permanente')),
 reason text NOT NULL,
 created_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK (ends_at > starts_at),
 CHECK (effective_from <= starts_at),
 UNIQUE (shift_id,version)
);
CREATE INDEX IF NOT EXISTS shift_versions_worker ON shift_versions(worker_id,starts_at,ends_at);
CREATE TABLE IF NOT EXISTS shift_policies (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 service_id bigint NOT NULL REFERENCES services(id),
 entry_before integer NOT NULL CHECK (entry_before BETWEEN 0 AND 1440),
 exit_after integer NOT NULL CHECK (exit_after BETWEEN 0 AND 1440),
 late_tolerance integer NOT NULL CHECK (late_tolerance BETWEEN 0 AND 1440),
 block_outside boolean NOT NULL,
 reason text NOT NULL,
 changed_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS shift_templates (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 service_id bigint NOT NULL REFERENCES services(id),
 name text NOT NULL,
 profile_id bigint NOT NULL REFERENCES profiles(id),
 weekdays integer[] NOT NULL,
 start_time time NOT NULL,
 end_time time NOT NULL,
 created_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS shift_exceptions (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 request_id bigint NOT NULL UNIQUE REFERENCES decision_requests(id),
 worker_id bigint NOT NULL REFERENCES workers(id),
 service_id bigint NOT NULL REFERENCES services(id),
 site_id bigint NOT NULL REFERENCES sites(id),
 starts_at timestamptz NOT NULL,
 ends_at timestamptz NOT NULL CHECK (ends_at > starts_at),
 reason text NOT NULL
);
ALTER TABLE access_movements ADD COLUMN IF NOT EXISTS shift_version_id bigint REFERENCES shift_versions(id);
ALTER TABLE access_movements ADD COLUMN IF NOT EXISTS timing jsonb NOT NULL DEFAULT '{}';
ALTER TABLE outbound_messages ADD COLUMN IF NOT EXISTS user_id bigint REFERENCES users(id);
ALTER TABLE outbound_messages ADD COLUMN IF NOT EXISTS request_id bigint REFERENCES decision_requests(id);
CREATE UNIQUE INDEX IF NOT EXISTS outbound_shift_notice ON outbound_messages(user_id,request_id,channel) WHERE request_id IS NOT NULL;
DO $$ DECLARE tab text; BEGIN
 FOREACH tab IN ARRAY ARRAY['shift_versions','shift_policies','shift_templates','shift_exceptions'] LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS shift_record_immutable ON %I',tab);
  EXECUTE format('CREATE TRIGGER shift_record_immutable BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION decision_records_immutable()',tab);
 END LOOP;
END $$;
COMMIT;
