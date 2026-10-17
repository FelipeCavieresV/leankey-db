BEGIN;
CREATE TABLE IF NOT EXISTS document_collectives (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    service_id bigint NOT NULL REFERENCES services(id),
    document_type_id bigint NOT NULL REFERENCES document_types(id),
    original_file_id bigint NOT NULL REFERENCES files(id),
    created_by bigint NOT NULL REFERENCES users(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    previous_id bigint REFERENCES document_collectives(id),
    common_change boolean NOT NULL DEFAULT false,
    justification text NOT NULL,
    revision integer NOT NULL DEFAULT 1
);
ALTER TABLE document_versions ADD COLUMN IF NOT EXISTS collective_id bigint REFERENCES document_collectives(id);
ALTER TABLE document_versions ADD COLUMN IF NOT EXISTS extract_verified_by bigint REFERENCES users(id);
ALTER TABLE document_versions ADD COLUMN IF NOT EXISTS extract_verified_at timestamptz;
CREATE TABLE IF NOT EXISTS document_collective_members (
    collective_id bigint NOT NULL REFERENCES document_collectives(id),
    worker_id bigint NOT NULL REFERENCES workers(id),
    version_id bigint NOT NULL REFERENCES document_versions(id),
    changed boolean NOT NULL,
    PRIMARY KEY (collective_id, worker_id)
);
CREATE INDEX IF NOT EXISTS document_versions_collective_idx ON document_versions(collective_id);
COMMIT;
