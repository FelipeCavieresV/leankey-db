BEGIN;
CREATE TABLE IF NOT EXISTS reports (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 cutoff date NOT NULL UNIQUE, source text NOT NULL, executive_summary text NOT NULL,
 headers jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS requests (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 title text NOT NULL CHECK (length(trim(title)) > 0),
 company text NOT NULL CHECK (length(trim(company)) > 0),
 state text NOT NULL DEFAULT 'Pendiente' CHECK (state IN ('Pendiente','En revisión','Aprobado','Rechazado')),
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS ksec_contractors (
 report_id bigint NOT NULL REFERENCES reports(id) ON DELETE CASCADE,
 position integer NOT NULL CHECK (position >= 0),
 "name" text NOT NULL,
 "workers" integer NOT NULL CHECK ("workers" >= 0),
 "documents" integer NOT NULL CHECK ("documents" >= 0),
 "approved" integer NOT NULL CHECK ("approved" >= 0),
 "missing" integer NOT NULL CHECK ("missing" >= 0),
 "rejected" integer NOT NULL CHECK ("rejected" >= 0),
 "uploaded" integer NOT NULL CHECK ("uploaded" >= 0),
 "approval" double precision NOT NULL CHECK ("approval" BETWEEN 0 AND 1),
 "complete" integer NOT NULL CHECK ("complete" >= 0),
 "incomplete" integer NOT NULL CHECK ("incomplete" >= 0),
 "with_rejection" integer NOT NULL CHECK ("with_rejection" >= 0),
 "pending" integer NOT NULL CHECK ("pending" >= 0),
 "expired" integer NOT NULL CHECK ("expired" >= 0),
 "expiring" integer NOT NULL CHECK ("expiring" >= 0),
 "document_types" integer NOT NULL CHECK ("document_types" >= 0),
 "required_documents" text NOT NULL,
 PRIMARY KEY (report_id,position)
);
CREATE TABLE IF NOT EXISTS ksec_packages (
 report_id bigint NOT NULL REFERENCES reports(id) ON DELETE CASCADE,
 position integer NOT NULL CHECK (position >= 0),
 "contractor" text NOT NULL,
 "rut" text NOT NULL,
 "worker" text NOT NULL,
 "worker_state" text NOT NULL,
 "required_documents" integer NOT NULL CHECK ("required_documents" >= 0),
 "approved" integer NOT NULL CHECK ("approved" >= 0),
 "missing" integer NOT NULL CHECK ("missing" >= 0),
 "rejected" integer NOT NULL CHECK ("rejected" >= 0),
 "uploaded" integer NOT NULL CHECK ("uploaded" >= 0),
 "approval" double precision NOT NULL CHECK ("approval" BETWEEN 0 AND 1),
 "package_state" text NOT NULL,
 "expired" integer NOT NULL CHECK ("expired" >= 0),
 "expiring" integer NOT NULL CHECK ("expiring" >= 0),
 "priority" text NOT NULL,
 PRIMARY KEY (report_id,position)
);
CREATE INDEX IF NOT EXISTS ksec_packages_company ON ksec_packages(report_id,contractor);
CREATE TABLE IF NOT EXISTS ksec_gaps (
 report_id bigint NOT NULL REFERENCES reports(id) ON DELETE CASCADE,
 position integer NOT NULL CHECK (position >= 0),
 "contractor" text NOT NULL,
 "rut" text NOT NULL,
 "worker" text NOT NULL,
 "document_code" text NOT NULL,
 "document_state" text NOT NULL,
 "uploaded_at" text NOT NULL,
 "expires_at" text NOT NULL,
 "expired" text NOT NULL,
 "expiring" text NOT NULL,
 "comment" text NOT NULL,
 "source_file" text NOT NULL,
 "source_row" integer NOT NULL CHECK ("source_row" >= 0),
 "suggested_action" text NOT NULL,
 PRIMARY KEY (report_id,position)
);
CREATE INDEX IF NOT EXISTS ksec_gaps_company ON ksec_gaps(report_id,contractor);
CREATE TABLE IF NOT EXISTS ksec_history (
 report_id bigint NOT NULL REFERENCES reports(id) ON DELETE CASCADE,
 position integer NOT NULL CHECK (position >= 0),
 "cutoff" text NOT NULL,
 "contractors" integer NOT NULL CHECK ("contractors" >= 0),
 "workers" integer NOT NULL CHECK ("workers" >= 0),
 "documents" integer NOT NULL CHECK ("documents" >= 0),
 "approved" integer NOT NULL CHECK ("approved" >= 0),
 "approval" double precision NOT NULL CHECK ("approval" BETWEEN 0 AND 1),
 "missing" integer NOT NULL CHECK ("missing" >= 0),
 "rejected" integer NOT NULL CHECK ("rejected" >= 0),
 "uploaded" integer NOT NULL CHECK ("uploaded" >= 0),
 "complete" integer NOT NULL CHECK ("complete" >= 0),
 "incomplete" integer NOT NULL CHECK ("incomplete" >= 0),
 "with_rejection" integer NOT NULL CHECK ("with_rejection" >= 0),
 "pending" integer NOT NULL CHECK ("pending" >= 0),
 "expired" integer NOT NULL CHECK ("expired" >= 0),
 "expiring" integer NOT NULL CHECK ("expiring" >= 0),
 PRIMARY KEY (report_id,position)
);
CREATE TABLE IF NOT EXISTS ksec_documents (
 report_id bigint NOT NULL REFERENCES reports(id) ON DELETE CASCADE,
 position integer NOT NULL CHECK (position >= 0),
 "contractor" text NOT NULL,
 "cutoff" text NOT NULL,
 "queried_at" text NOT NULL,
 "source_file" text NOT NULL,
 "source_row" integer NOT NULL CHECK ("source_row" >= 0),
 "rut" text NOT NULL,
 "worker" text NOT NULL,
 "activity" text NOT NULL,
 "worker_state" text NOT NULL,
 "document_code" text NOT NULL,
 "document_state" text NOT NULL,
 "uploaded_at" text NOT NULL,
 "expires_at" text NOT NULL,
 "comments" text NOT NULL,
 "expired" text NOT NULL,
 "expiring" text NOT NULL,
 PRIMARY KEY (report_id,position)
);
CREATE INDEX IF NOT EXISTS ksec_documents_company ON ksec_documents(report_id,contractor);
CREATE TABLE IF NOT EXISTS ksec_sources (
 report_id bigint NOT NULL REFERENCES reports(id) ON DELETE CASCADE,
 position integer NOT NULL CHECK (position >= 0),
 "contractor" text NOT NULL,
 "filename" text NOT NULL,
 "queried_at" text NOT NULL,
 "valid_rows" integer NOT NULL CHECK ("valid_rows" >= 0),
 "state" text NOT NULL,
 "observation" text NOT NULL,
 PRIMARY KEY (report_id,position)
);
CREATE INDEX IF NOT EXISTS ksec_sources_company ON ksec_sources(report_id,contractor);
CREATE TABLE IF NOT EXISTS ksec_criteria (
 report_id bigint NOT NULL REFERENCES reports(id) ON DELETE CASCADE,
 position integer NOT NULL CHECK (position >= 0),
 "criterion" text NOT NULL,
 "definition" text NOT NULL,
 PRIMARY KEY (report_id,position)
);
COMMIT;
