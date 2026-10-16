-- SEG-01…04: reportes de acceso y dotación opcional; no certifica trabajo efectivo.
BEGIN;
CREATE TABLE IF NOT EXISTS staffing_scopes (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 service_id bigint NOT NULL REFERENCES services(id),
 enabled boolean NOT NULL,
 effective_on date NOT NULL,
 ends_on date CHECK (ends_on IS NULL OR ends_on>=effective_on),
 reason text NOT NULL CHECK (length(trim(reason))>=5),
 configured_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS staffing_scopes_service ON staffing_scopes(service_id,effective_on DESC,id DESC);
CREATE TABLE IF NOT EXISTS staffing_commitments (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 service_id bigint NOT NULL REFERENCES services(id),
 profile_id bigint NOT NULL REFERENCES profiles(id),
 label text NOT NULL,
 starts_at timestamptz NOT NULL,
 ends_at timestamptz NOT NULL CHECK (ends_at>starts_at),
 headcount integer NOT NULL CHECK (headcount BETWEEN 1 AND 100000),
 replaces_id bigint REFERENCES staffing_commitments(id),
 reason text NOT NULL,
 proposed_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS staffing_validations (
 commitment_id bigint PRIMARY KEY REFERENCES staffing_commitments(id),
 accepted boolean NOT NULL,
 note text NOT NULL,
 validated_by bigint NOT NULL REFERENCES users(id),
 validated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS security_monthly_reports (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 service_id bigint NOT NULL REFERENCES services(id),
 month date NOT NULL CHECK (extract(day FROM month)=1),
 version integer NOT NULL CHECK (version>0),
 cutoff_at timestamptz NOT NULL,
 scheduled_for date NOT NULL,
 generated_at timestamptz NOT NULL DEFAULT now(),
 generated_by bigint REFERENCES users(id),
 reason text NOT NULL,
 source_hash text NOT NULL,
 payload jsonb NOT NULL,
 UNIQUE(service_id,month,version)
);
DO $$ DECLARE tab text; BEGIN
 FOREACH tab IN ARRAY ARRAY['staffing_scopes','staffing_commitments','staffing_validations','security_monthly_reports'] LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS security_record_immutable ON %I',tab);
  EXECUTE format('CREATE TRIGGER security_record_immutable BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION decision_records_immutable()',tab);
 END LOOP;
END $$;
COMMIT;
