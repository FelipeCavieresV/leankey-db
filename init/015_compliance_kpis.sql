BEGIN;
CREATE TABLE IF NOT EXISTS service_equipment_scopes (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 service_id bigint NOT NULL REFERENCES services(id),
 required boolean NOT NULL,
 reason text NOT NULL CHECK (length(trim(reason)) >= 5),
 recorded_by bigint NOT NULL REFERENCES users(id),
 recorded_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS equipment_scopes_service ON service_equipment_scopes(service_id,recorded_at DESC,id DESC);
CREATE TABLE IF NOT EXISTS compliance_cuts (
 day date NOT NULL,
 service_id bigint NOT NULL REFERENCES services(id),
 captured_at timestamptz NOT NULL DEFAULT now(),
 payload jsonb NOT NULL,
 PRIMARY KEY(day,service_id)
);
DROP TRIGGER IF EXISTS compliance_cuts_immutable ON compliance_cuts;
CREATE TRIGGER compliance_cuts_immutable BEFORE UPDATE OR DELETE ON compliance_cuts
 FOR EACH ROW EXECUTE FUNCTION decision_records_immutable();
DROP TRIGGER IF EXISTS equipment_scopes_immutable ON service_equipment_scopes;
CREATE TRIGGER equipment_scopes_immutable BEFORE UPDATE OR DELETE ON service_equipment_scopes
 FOR EACH ROW EXECUTE FUNCTION decision_records_immutable();
COMMIT;
