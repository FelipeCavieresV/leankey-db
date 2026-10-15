-- Requerimientos v1.0, sección 04: dotación e identidad del trabajador. Idempotente.
BEGIN;

-- Identidad única por RUT con código no secreto (DOT-01). Cada empresa mantiene su propia ficha en `workers`;
-- entre empresas solo se comparten el RUT y el código.
CREATE OR REPLACE FUNCTION new_person_code() RETURNS text AS $$
DECLARE
  alphabet constant text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
  result text := 'LK-';
BEGIN
  FOR i IN 1..8 LOOP
    result := result || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
  END LOOP;
  RETURN result;
END $$ LANGUAGE plpgsql VOLATILE;

CREATE TABLE IF NOT EXISTS persons (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 rut text NOT NULL UNIQUE CHECK (rut ~ '^[0-9]{1,9}-[0-9K]$'),
 code text NOT NULL UNIQUE DEFAULT new_person_code() CHECK (code ~ '^LK-[2-9A-HJKMNP-Z]{8}$'),
 created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO persons (rut, created_at)
SELECT rut, min(created_at) FROM workers GROUP BY rut
ON CONFLICT (rut) DO NOTHING;

ALTER TABLE workers ADD COLUMN IF NOT EXISTS person_id bigint REFERENCES persons(id);
UPDATE workers w SET person_id = p.id FROM persons p WHERE p.rut = w.rut AND w.person_id IS NULL;
ALTER TABLE workers ALTER COLUMN person_id SET NOT NULL;
CREATE INDEX IF NOT EXISTS workers_person ON workers(person_id);

-- Ficha de la planilla (DOT-02). `job_title` es la función; `name` conserva el nombre completo para mostrar.
-- Los registros anteriores quedan con ficha incompleta: nada se completa por inferencia.
ALTER TABLE workers ADD COLUMN IF NOT EXISTS first_names text NOT NULL DEFAULT '';
ALTER TABLE workers ADD COLUMN IF NOT EXISTS last_name_paternal text NOT NULL DEFAULT '';
ALTER TABLE workers ADD COLUMN IF NOT EXISTS last_name_maternal text NOT NULL DEFAULT '';
ALTER TABLE workers ADD COLUMN IF NOT EXISTS mutual text CHECK (mutual IN ('achs','ist','mutual_cchc','isl'));
ALTER TABLE workers ADD COLUMN IF NOT EXISTS birth_date date;
ALTER TABLE workers ADD COLUMN IF NOT EXISTS disability text CHECK (disability IN ('si','no'));
ALTER TABLE workers ADD COLUMN IF NOT EXISTS gender text CHECK (gender IN ('femenino','masculino','otro','no_informa'));
ALTER TABLE workers ADD COLUMN IF NOT EXISTS country text NOT NULL DEFAULT '';
ALTER TABLE workers ADD COLUMN IF NOT EXISTS commune text NOT NULL DEFAULT '';
ALTER TABLE workers ADD COLUMN IF NOT EXISTS address text NOT NULL DEFAULT '';
-- Contacto del trabajador (DOT-04): opcional, no bloquea dotación ni documentos.
ALTER TABLE workers ADD COLUMN IF NOT EXISTS phone text NOT NULL DEFAULT '';
ALTER TABLE workers ADD COLUMN IF NOT EXISTS email text NOT NULL DEFAULT '' CHECK (email = '' OR email = lower(email) AND email LIKE '%@%');
ALTER TABLE workers ADD COLUMN IF NOT EXISTS email_verified_at timestamptz;
ALTER TABLE workers ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

-- Situaciones temporales (DOT-05): ausencia o licencia con fechas. Renuncia, término y traslado se registran al
-- terminar la asignación (end_reason) y conservan su expediente.
CREATE TABLE IF NOT EXISTS worker_situations (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 worker_id bigint NOT NULL REFERENCES workers(id),
 kind text NOT NULL CHECK (kind IN ('ausencia','licencia')),
 starts_on date NOT NULL,
 ends_on date,
 note text NOT NULL DEFAULT '',
 created_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK (ends_on IS NULL OR ends_on >= starts_on)
);
CREATE INDEX IF NOT EXISTS worker_situations_worker ON worker_situations(worker_id, starts_on DESC);

-- Invitaciones personales al acceso móvil (DOT-04). Solo se guarda el resumen del token: nadie, ni el
-- contratista, conoce el enlace ni la contraseña que define el trabajador.
CREATE TABLE IF NOT EXISTS worker_invitations (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 worker_id bigint NOT NULL REFERENCES workers(id),
 channel text NOT NULL CHECK (channel IN ('correo')),
 destination text NOT NULL,
 token_hash text NOT NULL UNIQUE,
 delivery text NOT NULL CHECK (delivery IN ('pendiente_proveedor','enviada','fallida')),
 created_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 expires_at timestamptz NOT NULL,
 accepted_at timestamptz,
 user_id bigint REFERENCES users(id),
 revoked_at timestamptz
);
CREATE INDEX IF NOT EXISTS worker_invitations_worker ON worker_invitations(worker_id, created_at DESC);

-- Mensajes salientes sin su contenido (los enlaces son secretos). El envío real espera al proveedor (D15).
CREATE TABLE IF NOT EXISTS outbound_messages (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 channel text NOT NULL,
 destination text NOT NULL,
 kind text NOT NULL,
 status text NOT NULL CHECK (status IN ('pendiente_proveedor','enviada','fallida')),
 created_at timestamptz NOT NULL DEFAULT now()
);

-- DOT-06: el anexo de traslado no exige informar el destino a la mandante de origen. Se conserva la regla
-- anterior en el historial del catálogo, como cualquier cambio de documento.
DO $$
DECLARE
  t record;
BEGIN
  SELECT * INTO t FROM document_types WHERE code = 'MEN-TRASLADO' AND review_criteria = 'Fecha y destino del traslado.';
  IF FOUND THEN
    INSERT INTO document_type_revisions (document_type_id, version, data, valid_from)
    VALUES (t.id, t.version, jsonb_build_object(
      'code', t.code, 'name', t.name, 'scope', t.scope, 'description', t.description, 'evidence', t.evidence,
      'review_criteria', t.review_criteria, 'validity_months', t.validity_months, 'no_expiry', t.no_expiry,
      'monthly_condition', t.monthly_condition, 'sensitive', t.sensitive, 'sensitivity', t.sensitivity,
      'active', t.active), t.updated_at)
    ON CONFLICT DO NOTHING;
    UPDATE document_types
    SET review_criteria = 'Fecha de salida del servicio por traslado; no exige informar el destino.',
        version = version + 1, updated_at = now()
    WHERE id = t.id;
  END IF;
END $$;

COMMIT;
