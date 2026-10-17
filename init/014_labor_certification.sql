-- LAB-01 a LAB-06: fechas aceptadas, matriz por período y decisiones comunicadas.
BEGIN;
CREATE TABLE IF NOT EXISTS labor_calendars (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 service_id bigint NOT NULL REFERENCES services(id),
 month date NOT NULL CHECK (extract(day FROM month)=1),
 version integer NOT NULL,
 items jsonb NOT NULL,
 legal_validation text NOT NULL CHECK (length(trim(legal_validation)) >= 5),
 accepted_by bigint NOT NULL REFERENCES users(id),
 accepted_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(service_id,month,version)
);
ALTER TABLE periods ALTER COLUMN due_on DROP NOT NULL;
ALTER TABLE periods ADD COLUMN IF NOT EXISTS labor_calendar_id bigint REFERENCES labor_calendars(id);
-- Los períodos existentes conservan sus fechas operativas y quedan sin fecha legal inventada.
ALTER TABLE periods ADD COLUMN IF NOT EXISTS calendar_legacy boolean NOT NULL DEFAULT true;
ALTER TABLE periods ALTER COLUMN calendar_legacy SET DEFAULT false;
CREATE TABLE IF NOT EXISTS payment_communications (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 request_id bigint NOT NULL REFERENCES decision_requests(id),
 version integer NOT NULL,
 snapshot jsonb NOT NULL,
 communicated_by bigint NOT NULL REFERENCES users(id),
 communicated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(request_id, version)
);
CREATE TABLE IF NOT EXISTS payment_review_requests (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 communication_id bigint NOT NULL REFERENCES payment_communications(id),
 requested_by bigint NOT NULL REFERENCES users(id),
 reason text NOT NULL CHECK (length(trim(reason)) >= 5),
 created_at timestamptz NOT NULL DEFAULT now(),
 resolution text,
 resolved_by bigint REFERENCES users(id),
 resolved_at timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS payment_review_open ON payment_review_requests(communication_id) WHERE resolved_at IS NULL;
CREATE INDEX IF NOT EXISTS payment_communications_request ON payment_communications(request_id);
DROP TRIGGER IF EXISTS labor_calendars_immutable ON labor_calendars;
CREATE TRIGGER labor_calendars_immutable BEFORE UPDATE OR DELETE ON labor_calendars FOR EACH ROW EXECUTE FUNCTION decision_records_immutable();
DROP TRIGGER IF EXISTS payment_communications_immutable ON payment_communications;
CREATE TRIGGER payment_communications_immutable BEFORE UPDATE OR DELETE ON payment_communications FOR EACH ROW EXECUTE FUNCTION decision_records_immutable();
COMMIT;
