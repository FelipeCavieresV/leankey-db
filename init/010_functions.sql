-- Requerimientos v1.0, sección 05: funciones y habilitación documental. Idempotente.
BEGIN;

-- Exigencias por función y servicio (FUN-01). Sin servicio, la exigencia aplica en todos los servicios de la
-- mandante; con servicio, solo en ese y prevalece sobre la general del mismo documento.
ALTER TABLE profile_requirements ADD COLUMN IF NOT EXISTS service_id bigint REFERENCES services(id);
DROP INDEX IF EXISTS profile_requirements_current;
CREATE UNIQUE INDEX IF NOT EXISTS profile_requirements_scope_current
 ON profile_requirements(profile_id, document_type_id, coalesce(service_id, 0)) WHERE valid_to IS NULL;

-- Funciones compatibles autorizadas por la mandante (FUN-02). Revocar cierra la fila con motivo: la historia
-- permite reconstruir qué dualidades estaban autorizadas en cada corte.
CREATE TABLE IF NOT EXISTS profile_compatibilities (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 profile_a bigint NOT NULL REFERENCES profiles(id),
 profile_b bigint NOT NULL REFERENCES profiles(id),
 note text NOT NULL DEFAULT '',
 authorized_by bigint NOT NULL REFERENCES users(id),
 valid_from timestamptz NOT NULL DEFAULT now(),
 valid_to timestamptz,
 ended_by bigint REFERENCES users(id),
 end_reason text,
 CHECK (profile_a < profile_b),
 CHECK (valid_to IS NULL OR valid_to >= valid_from),
 CHECK (valid_to IS NULL OR length(trim(coalesce(end_reason, ''))) > 0)
);
CREATE UNIQUE INDEX IF NOT EXISTS profile_compatibilities_current
 ON profile_compatibilities(profile_a, profile_b) WHERE valid_to IS NULL;
CREATE INDEX IF NOT EXISTS profile_compatibilities_client ON profile_compatibilities(client_id);

-- Segunda función de la asignación (FUN-02): como máximo dos y distintas. Agregarla o retirarla es un cambio de
-- función: cierra la asignación vigente y abre otra, conservando la historia y la fecha de aplicación.
ALTER TABLE assignments ADD COLUMN IF NOT EXISTS secondary_profile_id bigint REFERENCES profiles(id);
ALTER TABLE assignments DROP CONSTRAINT IF EXISTS assignments_secondary_distinct;
ALTER TABLE assignments ADD CONSTRAINT assignments_secondary_distinct
 CHECK (secondary_profile_id IS NULL OR secondary_profile_id <> profile_id);

-- Horario de ingreso por servicio (FUN-04): ventanas semanales con vigencia. Sin horario no hay restricción
-- horaria. Es una condición de acceso: nunca altera el porcentaje documental.
CREATE TABLE IF NOT EXISTS service_access_schedules (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 service_id bigint NOT NULL REFERENCES services(id),
 windows jsonb NOT NULL CHECK (jsonb_typeof(windows) = 'array'),
 note text NOT NULL DEFAULT '',
 changed_by bigint REFERENCES users(id),
 valid_from timestamptz NOT NULL DEFAULT now(),
 valid_to timestamptz,
 CHECK (valid_to IS NULL OR valid_to >= valid_from)
);
CREATE UNIQUE INDEX IF NOT EXISTS service_access_schedules_current
 ON service_access_schedules(service_id) WHERE valid_to IS NULL;

-- Funciones que la persona ejerce en el turno de cada movimiento (FUN-02). Los anteriores quedan sin detalle.
ALTER TABLE access_movements ADD COLUMN IF NOT EXISTS profile_ids bigint[] NOT NULL DEFAULT '{}';

COMMIT;
