-- Ajustes tras la revisión de requerimientos v0.1. Idempotente.
BEGIN;

-- Documentos que realmente no vencen se marcan explícitamente; el resto exige vencimiento (RF-17).
ALTER TABLE document_types ADD COLUMN IF NOT EXISTS no_expiry boolean NOT NULL DEFAULT false;
UPDATE document_types SET no_expiry = true WHERE scope IN ('monthly_worker','monthly_company') AND NOT no_expiry;

-- Presentación completa registrada para distinguir presentación oportuna de incumplimiento (RF-28/RF-30).
ALTER TABLE periods ADD COLUMN IF NOT EXISTS submitted_complete boolean NOT NULL DEFAULT false;
-- Regla aplicada al período, consultable por el contratista (RF-32).
ALTER TABLE periods ADD COLUMN IF NOT EXISTS policy jsonb;

-- Idempotencia por usuario y no global (RF-14, CA16).
ALTER TABLE document_versions DROP CONSTRAINT IF EXISTS document_versions_idempotency_key_key;
CREATE UNIQUE INDEX IF NOT EXISTS document_versions_idempotency ON document_versions(created_by, idempotency_key) WHERE idempotency_key IS NOT NULL;

COMMIT;
