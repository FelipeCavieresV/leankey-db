-- Ayuda antes del ingreso. No altera cuentas, credenciales ni permisos.
BEGIN;
CREATE TABLE IF NOT EXISTS public_support_requests (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 name text NOT NULL CHECK (length(trim(name)) BETWEEN 2 AND 120),
 email text NOT NULL CHECK (length(email) <= 254),
 subject text NOT NULL CHECK (length(trim(subject)) BETWEEN 3 AND 200),
 description text NOT NULL CHECK (length(trim(description)) BETWEEN 5 AND 4000),
 source_hash text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 resolved_at timestamptz,
 resolved_by bigint REFERENCES users(id),
 resolution text,
 CHECK ((resolved_at IS NULL AND resolved_by IS NULL AND resolution IS NULL)
     OR (resolved_at IS NOT NULL AND resolved_by IS NOT NULL AND length(trim(resolution)) >= 5))
);
CREATE INDEX IF NOT EXISTS public_support_rate ON public_support_requests(source_hash, created_at);
CREATE INDEX IF NOT EXISTS public_support_email_rate ON public_support_requests(email, created_at);
COMMIT;
