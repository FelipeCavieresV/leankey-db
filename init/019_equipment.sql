-- VEH-01…05. Identidad común; uso, documentos y permisos separados por relación.
BEGIN;
CREATE TABLE IF NOT EXISTS equipment_units (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 kind text NOT NULL CHECK(kind IN ('grua_horquilla','camion_grua_pluma','grua_alto_tonelaje','camion_materiales')),
 created_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS equipment_identifiers (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 equipment_id bigint NOT NULL REFERENCES equipment_units(id),
 kind text NOT NULL CHECK(kind IN ('patente','serie')),
 value text NOT NULL CHECK(length(value)>0),
 created_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(kind,value), UNIQUE(equipment_id,kind)
);
CREATE TABLE IF NOT EXISTS equipment_uses (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 equipment_id bigint NOT NULL REFERENCES equipment_units(id),
 service_id bigint NOT NULL REFERENCES services(id),
 ownership text NOT NULL CHECK(ownership IN ('propio','arrendado','tercero')),
 owner_name text NOT NULL CHECK(length(trim(owner_name))>0),
 owner_rut text NOT NULL DEFAULT '',
 usage_mode text NOT NULL CHECK(usage_mode IN ('permanente','ocasional')),
 starts_on date NOT NULL,
 ends_on date CHECK(ends_on IS NULL OR ends_on>=starts_on),
 reason text NOT NULL,
 created_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK(usage_mode<>'ocasional' OR ends_on IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS equipment_uses_service ON equipment_uses(service_id,equipment_id);
CREATE TABLE IF NOT EXISTS equipment_use_closures (
 use_id bigint PRIMARY KEY REFERENCES equipment_uses(id),
 ends_on date NOT NULL,
 reason text NOT NULL,
 closed_by bigint NOT NULL REFERENCES users(id),
 closed_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS equipment_document_types (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 code text NOT NULL,
 name text NOT NULL,
 review_criteria text NOT NULL,
 minimums jsonb NOT NULL CHECK(jsonb_typeof(minimums)='array' AND jsonb_array_length(minimums)>0),
 no_expiry boolean NOT NULL,
 created_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(client_id,code)
);
CREATE TABLE IF NOT EXISTS equipment_matrices (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 kind text NOT NULL CHECK(kind IN ('grua_horquilla','camion_grua_pluma','grua_alto_tonelaje','camion_materiales')),
 usage_mode text NOT NULL CHECK(usage_mode IN ('permanente','ocasional')),
 effective_on date NOT NULL,
 document_type_ids bigint[] NOT NULL CHECK(cardinality(document_type_ids)>0),
 driver_profile_ids bigint[] NOT NULL DEFAULT '{}',
 operator_profile_ids bigint[] NOT NULL DEFAULT '{}',
 reason text NOT NULL,
 configured_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS equipment_document_versions (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 equipment_id bigint NOT NULL REFERENCES equipment_units(id),
 client_id bigint NOT NULL REFERENCES clients(id),
 contractor_id bigint NOT NULL REFERENCES contractors(id),
 document_type_id bigint NOT NULL REFERENCES equipment_document_types(id),
 submitted_for_use_id bigint NOT NULL REFERENCES equipment_uses(id),
 version integer NOT NULL CHECK(version>0),
 file_id bigint NOT NULL REFERENCES files(id),
 issued_on date NOT NULL,
 expires_on date CHECK(expires_on IS NULL OR expires_on>=issued_on),
 submitted_by bigint NOT NULL REFERENCES users(id),
 submitted_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(equipment_id,client_id,contractor_id,document_type_id,version)
);
CREATE TABLE IF NOT EXISTS equipment_reviews (
 version_id bigint PRIMARY KEY REFERENCES equipment_document_versions(id),
 decision text NOT NULL CHECK(decision IN ('aprobado','rechazado')),
 expires_on date,
 reason text NOT NULL,
 unmet_minimums jsonb NOT NULL DEFAULT '[]',
 reviewed_by bigint NOT NULL REFERENCES users(id),
 reviewed_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS equipment_scope_requests (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 service_id bigint NOT NULL REFERENCES services(id),
 required boolean NOT NULL,
 reason text NOT NULL,
 requested_by bigint NOT NULL REFERENCES users(id),
 requested_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS equipment_scope_resolutions (
 request_id bigint PRIMARY KEY REFERENCES equipment_scope_requests(id),
 accepted boolean NOT NULL,
 scope_id bigint REFERENCES service_equipment_scopes(id),
 reason text NOT NULL,
 resolved_by bigint NOT NULL REFERENCES users(id),
 resolved_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS equipment_operator_authorizations (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 use_id bigint NOT NULL REFERENCES equipment_uses(id),
 worker_id bigint NOT NULL REFERENCES workers(id),
 operator_service_id bigint NOT NULL REFERENCES services(id),
 profile_id bigint NOT NULL REFERENCES profiles(id),
 activity text NOT NULL CHECK(activity IN ('conducir','operar')),
 starts_on date NOT NULL,
 ends_on date CHECK(ends_on IS NULL OR ends_on>=starts_on),
 reason text NOT NULL,
 granted_by bigint NOT NULL REFERENCES users(id),
 granted_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS equipment_operator_revocations (
 authorization_id bigint PRIMARY KEY REFERENCES equipment_operator_authorizations(id),
 reason text NOT NULL,
 revoked_by bigint NOT NULL REFERENCES users(id),
 revoked_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS equipment_movements (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 equipment_id bigint NOT NULL REFERENCES equipment_units(id),
 use_id bigint NOT NULL REFERENCES equipment_uses(id),
 service_id bigint NOT NULL REFERENCES services(id),
 site_id bigint REFERENCES sites(id),
 direction text NOT NULL CHECK(direction IN ('entrada','salida')),
 result text NOT NULL CHECK(result IN ('registrado','rechazado')),
 authorization_id bigint REFERENCES equipment_operator_authorizations(id),
 reasons jsonb NOT NULL,
 verification jsonb NOT NULL,
 note text NOT NULL,
 event_key text NOT NULL,
 registered_by bigint NOT NULL REFERENCES users(id),
 at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(registered_by,event_key)
);
CREATE INDEX IF NOT EXISTS equipment_presence ON equipment_movements(equipment_id,at DESC,id DESC) WHERE result='registrado';
DO $$ DECLARE tab text; BEGIN
 FOREACH tab IN ARRAY ARRAY['equipment_units','equipment_identifiers','equipment_uses','equipment_use_closures','equipment_document_types','equipment_matrices','equipment_document_versions','equipment_reviews','equipment_scope_requests','equipment_scope_resolutions','equipment_operator_authorizations','equipment_operator_revocations','equipment_movements'] LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS equipment_record_immutable ON %I',tab);
  EXECUTE format('CREATE TRIGGER equipment_record_immutable BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION decision_records_immutable()',tab);
 END LOOP;
END $$;
COMMIT;
