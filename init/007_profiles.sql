-- Requerimientos v1.0, sección 02: perfiles y permisos. Idempotente.
BEGIN;

-- Conversiones de datos que deben ocurrir una sola vez aunque el archivo se vuelva a aplicar.
CREATE TABLE IF NOT EXISTS schema_migrations (
 name text PRIMARY KEY,
 applied_at timestamptz NOT NULL DEFAULT now()
);

-- Cuentas de trabajador (PER-05): consultan solo lo propio, vinculadas por RUT.
ALTER TABLE users ADD COLUMN IF NOT EXISTS worker_rut text CHECK (worker_rut IS NULL OR worker_rut ~ '^[0-9]{1,9}-[0-9K]$');
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_kind_check;
ALTER TABLE users ADD CONSTRAINT users_kind_check CHECK (kind IN ('admin','contractor','worker'));
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_worker_rut;
ALTER TABLE users ADD CONSTRAINT users_worker_rut CHECK ((kind = 'worker') = (worker_rut IS NOT NULL));
-- Perfiles internos ampliados (PER-03, PER-05).
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_roles_valid;
ALTER TABLE users ADD CONSTRAINT users_roles_valid CHECK (
 roles <@ ARRAY['leankey','administrador','supervisor','prevencion','seguridad','jefe_seguridad']::text[]
 AND (kind = 'admin' OR roles = '{}')
);
-- Capacidades que nunca tiene una cuenta externa (contratista o trabajador).
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_check1;
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_internal_capabilities;
ALTER TABLE users ADD CONSTRAINT users_internal_capabilities CHECK (
 kind = 'admin' OR NOT (capabilities && ARRAY['review','review_labor','configure','manage_users','all_clients','critical_tickets'])
);
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_worker_capabilities;
ALTER TABLE users ADD CONSTRAINT users_worker_capabilities CHECK (kind <> 'worker' OR capabilities = '{}');

-- Consulta, carga, revisión y descarga se autorizan por separado; «sensible» se divide en médico y laboral.
-- Se conserva lo otorgado: quien veía sensibles ve ambos, quien revisaba revisa también la certificación
-- laboral, quien cargaba o revisaba puede descargar y toda cuenta existente conserva la consulta.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE name = '007_capabilities') THEN
    UPDATE users u
    SET capabilities = (
      SELECT coalesce(array_agg(DISTINCT c ORDER BY c), '{}')
      FROM unnest(
        u.capabilities
        || ARRAY['view']
        || CASE WHEN 'sensitive' = ANY(u.capabilities) THEN ARRAY['sensitive_medical','sensitive_labor'] ELSE '{}' END
        || CASE WHEN 'review' = ANY(u.capabilities) THEN ARRAY['review_labor'] ELSE '{}' END
        || CASE WHEN u.capabilities && ARRAY['review','upload'] THEN ARRAY['download'] ELSE '{}' END
      ) AS c
      WHERE c <> 'sensitive'
    )
    WHERE u.kind IN ('admin','contractor');
    INSERT INTO schema_migrations (name) VALUES ('007_capabilities');
  END IF;
END $$;

-- Sensibilidad por tipo de documento: médica (exámenes) o laboral (remuneraciones y relación laboral).
ALTER TABLE document_types ADD COLUMN IF NOT EXISTS sensitivity text NOT NULL DEFAULT 'ninguna';
ALTER TABLE document_types DROP CONSTRAINT IF EXISTS document_types_sensitivity;
ALTER TABLE document_types ADD CONSTRAINT document_types_sensitivity CHECK (sensitivity IN ('ninguna','medica','laboral'));
UPDATE document_types
SET sensitivity = CASE WHEN code = 'TRA-EXAMEN' THEN 'medica' ELSE 'laboral' END
WHERE sensitive AND sensitivity = 'ninguna';
ALTER TABLE document_types DROP CONSTRAINT IF EXISTS document_types_sensitivity_consistent;
ALTER TABLE document_types ADD CONSTRAINT document_types_sensitivity_consistent CHECK (sensitive = (sensitivity <> 'ninguna'));

-- Empresa inhabilitada por la mandante (PER-01): bloquea el ingreso de su dotación en esa mandante, con vigencia.
CREATE TABLE IF NOT EXISTS contractor_suspensions (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 contractor_id bigint NOT NULL REFERENCES contractors(id),
 client_id bigint NOT NULL REFERENCES clients(id),
 reason text NOT NULL CHECK (length(trim(reason)) > 0),
 starts_at timestamptz NOT NULL DEFAULT now(),
 created_by bigint NOT NULL REFERENCES users(id),
 ends_at timestamptz,
 ended_by bigint REFERENCES users(id),
 end_reason text,
 CHECK (ends_at IS NULL OR ends_at >= starts_at),
 CHECK (ends_at IS NULL OR length(trim(coalesce(end_reason, ''))) > 0)
);
CREATE UNIQUE INDEX IF NOT EXISTS contractor_suspensions_current ON contractor_suspensions(contractor_id, client_id) WHERE ends_at IS NULL;

-- Investigaciones y medidas correctivas (PER-03, base de la sección 15).
CREATE TABLE IF NOT EXISTS investigations (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 service_id bigint NOT NULL REFERENCES services(id),
 contractor_id bigint NOT NULL REFERENCES contractors(id),
 kind text NOT NULL CHECK (kind IN ('accidente','incidente','casi_accidente','condicion_insegura')),
 title text NOT NULL CHECK (length(trim(title)) > 0),
 occurred_on date NOT NULL,
 description text NOT NULL CHECK (length(trim(description)) > 0),
 state text NOT NULL DEFAULT 'abierta' CHECK (state IN ('abierta','observada','cerrada')),
 created_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 closed_at timestamptz,
 closed_by bigint REFERENCES users(id),
 revision integer NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS investigations_service ON investigations(service_id, created_at DESC);

CREATE TABLE IF NOT EXISTS investigation_notes (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 investigation_id bigint NOT NULL REFERENCES investigations(id),
 measure_id bigint,
 kind text NOT NULL CHECK (kind IN ('observacion','respuesta','evidencia','cierre')),
 body text NOT NULL CHECK (length(trim(body)) > 0),
 author_id bigint NOT NULL REFERENCES users(id),
 at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS corrective_measures (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 investigation_id bigint NOT NULL REFERENCES investigations(id),
 description text NOT NULL CHECK (length(trim(description)) > 0),
 due_on date NOT NULL,
 state text NOT NULL DEFAULT 'pendiente' CHECK (state IN ('pendiente','en_validacion','observada','cerrada')),
 evidence_file_id bigint REFERENCES files(id),
 evidence_sensitivity text NOT NULL DEFAULT 'ninguna' CHECK (evidence_sensitivity IN ('ninguna','medica','laboral')),
 evidence_note text NOT NULL DEFAULT '',
 submitted_at timestamptz,
 submitted_by bigint REFERENCES users(id),
 validated_at timestamptz,
 validated_by bigint REFERENCES users(id),
 observation text NOT NULL DEFAULT '',
 revision integer NOT NULL DEFAULT 0,
 created_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 -- Una medida solo se cierra sustentada: con evidencia registrada.
 CHECK (state <> 'cerrada' OR evidence_file_id IS NOT NULL),
 CHECK (state NOT IN ('en_validacion','cerrada') OR submitted_at IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS corrective_measures_investigation ON corrective_measures(investigation_id);

-- Movimientos asistidos por seguridad (PER-05, base de las secciones 12 y 13). Un intento rechazado también queda.
CREATE TABLE IF NOT EXISTS access_movements (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 service_id bigint NOT NULL REFERENCES services(id),
 site_id bigint REFERENCES sites(id),
 worker_id bigint NOT NULL REFERENCES workers(id),
 direction text NOT NULL CHECK (direction IN ('entrada','salida')),
 result text NOT NULL CHECK (result IN ('registrado','rechazado')),
 enabled boolean NOT NULL,
 reasons jsonb NOT NULL DEFAULT '[]',
 note text NOT NULL DEFAULT '',
 registered_by bigint NOT NULL REFERENCES users(id),
 at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS access_movements_worker ON access_movements(worker_id, at DESC);
CREATE INDEX IF NOT EXISTS access_movements_client ON access_movements(client_id, at DESC);
DROP TRIGGER IF EXISTS access_movements_no_change ON access_movements;
CREATE TRIGGER access_movements_no_change BEFORE UPDATE OR DELETE ON access_movements
 FOR EACH ROW EXECUTE FUNCTION decision_records_immutable();

-- Tickets de atención (PER-06, base de la sección 19). Solo usuarios autorizados de la mandante levantan críticos.
CREATE TABLE IF NOT EXISTS tickets (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint REFERENCES clients(id),
 priority text NOT NULL CHECK (priority IN ('normal','critica')),
 title text NOT NULL CHECK (length(trim(title)) > 0),
 description text NOT NULL CHECK (length(trim(description)) > 0),
 state text NOT NULL DEFAULT 'abierto' CHECK (state IN ('abierto','en_atencion','resuelto')),
 created_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 attended_by bigint REFERENCES users(id),
 resolution text NOT NULL DEFAULT '',
 CHECK (state <> 'resuelto' OR length(trim(resolution)) > 0)
);
CREATE INDEX IF NOT EXISTS tickets_client ON tickets(client_id, state);

COMMIT;
