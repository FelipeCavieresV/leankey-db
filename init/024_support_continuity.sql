-- SOP-01…04: atención humana, plazos de soporte, canal crítico y continuidad técnica. Idempotente.
BEGIN;

-- SOP-01: el horario aprobado se expresa en su propia zona (Santiago) y admite cobertura adicional contratada por
-- mandante. La versión SOP-01 se agrega una sola vez; los plazos ya calculados conservan la versión anterior.
ALTER TABLE leankey_attention_schedules ADD COLUMN IF NOT EXISTS timezone text NOT NULL DEFAULT 'America/Santiago';
ALTER TABLE leankey_attention_schedules ADD COLUMN IF NOT EXISTS client_id bigint REFERENCES clients(id);
INSERT INTO leankey_attention_schedules (weekdays, opens_at, closes_at, reason, timezone)
SELECT ARRAY[1,2,3,4,5]::smallint[], '08:30', '17:30',
       'SOP-01: lunes a viernes de 08:30 a 17:30, hora de Santiago, sin feriados aplicables y con cobertura de colación',
       'America/Santiago'
WHERE NOT EXISTS (SELECT 1 FROM leankey_attention_schedules WHERE client_id IS NULL AND reason LIKE 'SOP-01:%');

-- SOP-02/03: plazos de primera respuesta, recepción separada de la resolución y reportes a la mandante.
ALTER TABLE tickets ADD COLUMN IF NOT EXISTS audience text NOT NULL DEFAULT 'leankey';
ALTER TABLE tickets DROP CONSTRAINT IF EXISTS tickets_audience_check;
ALTER TABLE tickets ADD CONSTRAINT tickets_audience_check CHECK (
  audience IN ('leankey','mandante') AND (audience = 'leankey' OR (priority = 'normal' AND client_id IS NOT NULL)));
ALTER TABLE tickets ADD COLUMN IF NOT EXISTS escalated_from bigint REFERENCES tickets(id);
ALTER TABLE tickets ADD COLUMN IF NOT EXISTS attention_starts_at timestamptz;
ALTER TABLE tickets ADD COLUMN IF NOT EXISTS first_response_due_at timestamptz;
ALTER TABLE tickets ADD COLUMN IF NOT EXISTS attention_schedule_id bigint REFERENCES leankey_attention_schedules(id);
ALTER TABLE tickets ADD COLUMN IF NOT EXISTS first_response_at timestamptz;
ALTER TABLE tickets ADD COLUMN IF NOT EXISTS first_response_by bigint REFERENCES users(id);
ALTER TABLE tickets ADD COLUMN IF NOT EXISTS first_response_kind text;
ALTER TABLE tickets DROP CONSTRAINT IF EXISTS tickets_first_response_kind_check;
ALTER TABLE tickets ADD CONSTRAINT tickets_first_response_kind_check
  CHECK (first_response_kind IS NULL OR first_response_kind IN ('recepcion','respuesta'));
CREATE INDEX IF NOT EXISTS tickets_first_response_due ON tickets(first_response_due_at) WHERE first_response_at IS NULL;

CREATE TABLE IF NOT EXISTS ticket_messages (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 ticket_id bigint NOT NULL REFERENCES tickets(id),
 author_id bigint NOT NULL REFERENCES users(id),
 kind text NOT NULL CHECK (kind IN ('recepcion','respuesta','consulta')),
 body text NOT NULL CHECK (length(trim(body)) >= 5),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ticket_messages_ticket ON ticket_messages(ticket_id, id);

-- SOP-04: monitoreo automático, incidentes técnicos y guardia, independientes de los tickets y del horario humano.
CREATE TABLE IF NOT EXISTS monitor_state (
 component text PRIMARY KEY,
 ok boolean NOT NULL,
 consecutive_failures integer NOT NULL DEFAULT 0,
 first_failure_at timestamptz,
 last_checked_at timestamptz NOT NULL,
 last_ok_at timestamptz,
 last_error text,
 source text NOT NULL CHECK (source IN ('monitoreo','watchdog'))
);
CREATE TABLE IF NOT EXISTS platform_incidents (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 component text NOT NULL,
 kind text NOT NULL CHECK (kind IN ('caida_general','degradacion')),
 state text NOT NULL DEFAULT 'abierta' CHECK (state IN ('abierta','reconocida','recuperada')),
 detected_by text NOT NULL CHECK (detected_by IN ('monitoreo','watchdog','manual')),
 started_at timestamptz NOT NULL,
 detected_at timestamptz NOT NULL DEFAULT now(),
 summary text NOT NULL DEFAULT '',
 acknowledged_at timestamptz,
 acknowledged_by bigint REFERENCES users(id),
 recovered_at timestamptz,
 last_alert_at timestamptz,
 alerts integer NOT NULL DEFAULT 0,
 CHECK ((state = 'recuperada') = (recovered_at IS NOT NULL)),
 CHECK (state <> 'reconocida' OR acknowledged_at IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS platform_incidents_open ON platform_incidents(component) WHERE state <> 'recuperada';
CREATE TABLE IF NOT EXISTS platform_incident_events (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 incident_id bigint NOT NULL REFERENCES platform_incidents(id),
 event text NOT NULL CHECK (event IN ('detectada','alerta','recordatorio','reconocida','nota','recuperada')),
 detail text NOT NULL DEFAULT '',
 actor_id bigint REFERENCES users(id),
 at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS platform_incident_events_incident ON platform_incident_events(incident_id, id);
CREATE TABLE IF NOT EXISTS oncall_shifts (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 user_id bigint NOT NULL REFERENCES users(id),
 starts_at timestamptz NOT NULL,
 ends_at timestamptz NOT NULL CHECK (ends_at > starts_at),
 reason text NOT NULL CHECK (length(trim(reason)) >= 5),
 created_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS oncall_shifts_window ON oncall_shifts(starts_at, ends_at);

DO $$ DECLARE tab text; BEGIN
 FOREACH tab IN ARRAY ARRAY['ticket_messages','platform_incident_events','oncall_shifts'] LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS support_record_immutable ON %I',tab);
  EXECUTE format('CREATE TRIGGER support_record_immutable BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION decision_records_immutable()',tab);
 END LOOP;
END $$;
COMMIT;
