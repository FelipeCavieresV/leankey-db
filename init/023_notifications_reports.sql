-- NOT-01…05: reportes, exportaciones y notificaciones con entrega trazable. Idempotente.
BEGIN;

CREATE OR REPLACE FUNCTION valid_reminder_days(days integer[]) RETURNS boolean AS $$
 SELECT cardinality(days) BETWEEN 1 AND 6 AND days <@ (SELECT array_agg(g) FROM generate_series(0,90) g)
$$ LANGUAGE sql IMMUTABLE;

-- NOT-03: avisos anticipados configurables por mandante (base 30, 15, 7 y vencimiento). Versiones de solo inserción.
CREATE TABLE IF NOT EXISTS notice_policies (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 reminder_days integer[] NOT NULL CHECK (valid_reminder_days(reminder_days)),
 reason text NOT NULL CHECK (length(trim(reason)) >= 5),
 configured_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS notice_policies_client ON notice_policies(client_id, id DESC);

-- NOT-03: una acción resuelta deja de recordarse y su aviso lo indica; NOT-01: el resumen semanal conserva sus cifras.
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS resolved_at timestamptz;
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS resolution text;
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS payload jsonb;

-- NOT-04/05: mensajes externos con contenido sin secretos, reintentos y estados verificables.
ALTER TABLE outbound_messages DROP CONSTRAINT IF EXISTS outbound_messages_status_check;
ALTER TABLE outbound_messages ADD CONSTRAINT outbound_messages_status_check
 CHECK (status IN ('pendiente_proveedor','enviada','entregada','leida','fallida'));
ALTER TABLE outbound_messages ADD COLUMN IF NOT EXISTS subject text;
ALTER TABLE outbound_messages ADD COLUMN IF NOT EXISTS body text;
ALTER TABLE outbound_messages ADD COLUMN IF NOT EXISTS link text;
ALTER TABLE outbound_messages ADD COLUMN IF NOT EXISTS notification_id bigint REFERENCES notifications(id) ON DELETE SET NULL;
DROP INDEX IF EXISTS outbound_shift_notice;
ALTER TABLE outbound_messages ADD COLUMN IF NOT EXISTS dedupe_key text;
ALTER TABLE outbound_messages ADD COLUMN IF NOT EXISTS attempts integer NOT NULL DEFAULT 0;
ALTER TABLE outbound_messages ADD COLUMN IF NOT EXISTS next_attempt_at timestamptz;
ALTER TABLE outbound_messages ADD COLUMN IF NOT EXISTS last_error text;
ALTER TABLE outbound_messages ADD COLUMN IF NOT EXISTS contact_issue boolean NOT NULL DEFAULT false;
ALTER TABLE outbound_messages ADD COLUMN IF NOT EXISTS provider_ref text;
-- Qué confirma el canal: solo 'entrega' y 'lectura' si el proveedor aportó esa evidencia.
ALTER TABLE outbound_messages ADD COLUMN IF NOT EXISTS verified text[] NOT NULL DEFAULT '{}';
ALTER TABLE outbound_messages ADD COLUMN IF NOT EXISTS sent_at timestamptz;
ALTER TABLE outbound_messages ADD COLUMN IF NOT EXISTS delivered_at timestamptz;
ALTER TABLE outbound_messages ADD COLUMN IF NOT EXISTS read_at timestamptz;
CREATE UNIQUE INDEX IF NOT EXISTS outbound_dedupe ON outbound_messages(user_id, channel, dedupe_key) WHERE dedupe_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS outbound_retry ON outbound_messages(next_attempt_at) WHERE status IN ('pendiente_proveedor','fallida');
CREATE INDEX IF NOT EXISTS outbound_user ON outbound_messages(user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS delivery_events (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 message_id bigint NOT NULL REFERENCES outbound_messages(id),
 event text NOT NULL CHECK (event IN ('encolado','enviado','entregado','leido','fallido','reintento','contacto_incorrecto')),
 source text NOT NULL CHECK (source IN ('sistema','proveedor')),
 detail text NOT NULL DEFAULT '',
 at timestamptz NOT NULL DEFAULT now(),
 -- Entregado y leído solo los aporta el proveedor: el sistema no los presume.
 CHECK (event NOT IN ('entregado','leido') OR source = 'proveedor')
);
CREATE INDEX IF NOT EXISTS delivery_events_message ON delivery_events(message_id, id);

-- NOT-02: preparación en segundo plano; el archivo se vuelve a autorizar al descargar.
CREATE TABLE IF NOT EXISTS export_jobs (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 user_id bigint NOT NULL REFERENCES users(id),
 dataset text NOT NULL,
 format text NOT NULL CHECK (format IN ('csv','xlsx','pdf')),
 filters jsonb NOT NULL DEFAULT '{}',
 state text NOT NULL DEFAULT 'pendiente' CHECK (state IN ('pendiente','procesando','listo','fallido')),
 row_count integer,
 file_id bigint REFERENCES files(id),
 error text,
 requested_at timestamptz NOT NULL DEFAULT now(),
 started_at timestamptz,
 finished_at timestamptz,
 expires_at timestamptz NOT NULL DEFAULT now() + interval '7 days'
);
CREATE INDEX IF NOT EXISTS export_jobs_user ON export_jobs(user_id, id DESC);

-- NOT-05: indisponibilidad de la plataforma y ajustes auditables de plazos de corrección. Solo inserción.
CREATE TABLE IF NOT EXISTS availability_incidents (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint REFERENCES clients(id),
 starts_at timestamptz NOT NULL,
 ends_at timestamptz NOT NULL CHECK (ends_at > starts_at),
 description text NOT NULL CHECK (length(trim(description)) >= 5),
 registered_by bigint NOT NULL REFERENCES users(id),
 registered_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS deadline_adjustments (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 version_id bigint NOT NULL REFERENCES document_versions(id),
 incident_id bigint NOT NULL REFERENCES availability_incidents(id),
 previous_due_on date NOT NULL,
 new_due_on date NOT NULL CHECK (new_due_on > previous_due_on),
 business_days integer NOT NULL CHECK (business_days > 0),
 reason text NOT NULL CHECK (length(trim(reason)) >= 5),
 adjusted_by bigint NOT NULL REFERENCES users(id),
 adjusted_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS deadline_adjustments_version ON deadline_adjustments(version_id, id);

DO $$ DECLARE tab text; BEGIN
 FOREACH tab IN ARRAY ARRAY['notice_policies','delivery_events','availability_incidents','deadline_adjustments'] LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS notice_record_immutable ON %I',tab);
  EXECUTE format('CREATE TRIGGER notice_record_immutable BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION decision_records_immutable()',tab);
 END LOOP;
END $$;
COMMIT;
