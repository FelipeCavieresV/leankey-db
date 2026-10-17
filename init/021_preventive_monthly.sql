-- RPM-01…05. Reporte preventivo mensual: ausencia de envío nunca declara cero eventos.
BEGIN;
CREATE TABLE IF NOT EXISTS preventive_monthly_scopes (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 service_id bigint NOT NULL REFERENCES services(id),
 enabled boolean NOT NULL,
 starts_on date NOT NULL,
 ends_on date CHECK(ends_on IS NULL OR ends_on>=starts_on),
 reason text NOT NULL,
 configured_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS preventive_monthly_scope_service ON preventive_monthly_scopes(service_id,starts_on DESC,id DESC);
CREATE TABLE IF NOT EXISTS preventive_monthly_policies (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 effective_month date NOT NULL CHECK(extract(day FROM effective_month)=1),
 submission_business_day integer NOT NULL CHECK(submission_business_day BETWEEN 1 AND 31),
 review_business_days integer NOT NULL CHECK(review_business_days BETWEEN 1 AND 60),
 correction_business_days integer NOT NULL CHECK(correction_business_days BETWEEN 1 AND 60),
 reason text NOT NULL,
 configured_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS preventive_monthly_drafts (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 service_id bigint NOT NULL REFERENCES services(id),
 month date NOT NULL CHECK(extract(day FROM month)=1),
 revision integer NOT NULL DEFAULT 1,
 base_version_id bigint,
 declaration text CHECK(declaration IN ('con_eventos','sin_eventos','sin_actividad')),
 statement text NOT NULL DEFAULT '',
 no_activity_confirmed boolean NOT NULL DEFAULT false,
 source_hash text NOT NULL,
 payload jsonb NOT NULL,
 updated_by bigint REFERENCES users(id),
 updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(service_id,month)
);
CREATE TABLE IF NOT EXISTS preventive_monthly_versions (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 service_id bigint NOT NULL REFERENCES services(id),
 month date NOT NULL CHECK(extract(day FROM month)=1),
 version integer NOT NULL CHECK(version>0),
 previous_id bigint REFERENCES preventive_monthly_versions(id),
 declaration text NOT NULL CHECK(declaration IN ('con_eventos','sin_eventos','sin_actividad')),
 statement text NOT NULL,
 no_activity_confirmed boolean NOT NULL,
 reason text NOT NULL,
 source_hash text NOT NULL,
 payload jsonb NOT NULL,
 schedule jsonb NOT NULL,
 submission_due_on date,
 review_due_on date NOT NULL,
 submitted_by bigint NOT NULL REFERENCES users(id),
 submitted_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(service_id,month,version)
);
CREATE TABLE IF NOT EXISTS preventive_monthly_reviews (
 version_id bigint PRIMARY KEY REFERENCES preventive_monthly_versions(id),
 decision text NOT NULL CHECK(decision IN ('aceptado','observado')),
 note text NOT NULL,
 activity_contrast_confirmed boolean NOT NULL,
 correction_due_on date,
 reviewed_by bigint NOT NULL REFERENCES users(id),
 reviewed_at timestamptz NOT NULL DEFAULT now(),
 CHECK((decision='observado')=(correction_due_on IS NOT NULL))
);
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conname='preventive_monthly_draft_base_fk') THEN
  ALTER TABLE preventive_monthly_drafts ADD CONSTRAINT preventive_monthly_draft_base_fk FOREIGN KEY(base_version_id) REFERENCES preventive_monthly_versions(id);
 END IF;
END $$;
DO $$ DECLARE tab text; BEGIN
 FOREACH tab IN ARRAY ARRAY['preventive_monthly_scopes','preventive_monthly_policies','preventive_monthly_versions','preventive_monthly_reviews'] LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS preventive_monthly_immutable ON %I',tab);
  EXECUTE format('CREATE TRIGGER preventive_monthly_immutable BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION decision_records_immutable()',tab);
 END LOOP;
END $$;
COMMIT;
