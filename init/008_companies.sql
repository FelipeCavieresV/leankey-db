-- Requerimientos v1.0, sección 03: empresas y usuarios. Idempotente.
BEGIN;

-- Vínculo empresa–mandante con fecha efectiva (EMP-01). Una empresa nueva queda vinculada al cliente aunque
-- todavía no tenga servicios; queda activa desde que se crea y se inhabilita con contractor_suspensions.
CREATE TABLE IF NOT EXISTS client_contractors (
 contractor_id bigint NOT NULL REFERENCES contractors(id),
 client_id bigint NOT NULL REFERENCES clients(id),
 starts_on date NOT NULL,
 created_by bigint REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (contractor_id, client_id)
);
CREATE INDEX IF NOT EXISTS client_contractors_client ON client_contractors(client_id);
-- Relaciones existentes: las que ya tienen servicios, desde su primer servicio.
INSERT INTO client_contractors (contractor_id, client_id, starts_on, created_at)
SELECT contractor_id, client_id, min(starts_on), min(created_at)
FROM services
GROUP BY contractor_id, client_id
ON CONFLICT DO NOTHING;

-- Contacto y verificación de cuentas individuales (EMP-04). Sin RUT: basta el nombre, el correo único y el
-- registro de quién verificó que la cuenta es de uso personal (minimización de datos personales).
ALTER TABLE users ADD COLUMN IF NOT EXISTS phone text NOT NULL DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS contact_verified_at timestamptz;
ALTER TABLE users ADD COLUMN IF NOT EXISTS contact_verified_by bigint REFERENCES users(id);
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_contact_verification;
ALTER TABLE users ADD CONSTRAINT users_contact_verification CHECK ((contact_verified_at IS NULL) = (contact_verified_by IS NULL));

COMMIT;
