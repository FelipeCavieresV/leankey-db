-- RNF-01…12: autenticación, protección, auditoría, continuidad, idempotencia y tiempo. Idempotente.
BEGIN;

-- RNF-01: doble verificación (TOTP). El secreto se guarda cifrado con la llave de datos; los códigos de
-- recuperación, solo como resumen. Nadie puede consultar contraseñas ni secretos de otra persona.
ALTER TABLE users ADD COLUMN IF NOT EXISTS mfa_secret text;
ALTER TABLE users ADD COLUMN IF NOT EXISTS mfa_enabled_at timestamptz;
ALTER TABLE users ADD COLUMN IF NOT EXISTS mfa_recovery_hashes text[] NOT NULL DEFAULT '{}';
ALTER TABLE users ADD COLUMN IF NOT EXISTS mfa_last_step bigint;
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_mfa_consistent;
ALTER TABLE users ADD CONSTRAINT users_mfa_consistent CHECK (mfa_enabled_at IS NULL OR mfa_secret IS NOT NULL);
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS mfa_verified boolean NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS auth_challenges (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 token_hash text NOT NULL UNIQUE,
 user_id bigint NOT NULL REFERENCES users(id),
 purpose text NOT NULL CHECK (purpose IN ('login','enrolamiento','recuperacion')),
 pending_secret text,
 attempts integer NOT NULL DEFAULT 0,
 created_at timestamptz NOT NULL DEFAULT now(),
 expires_at timestamptz NOT NULL,
 used_at timestamptz
);
CREATE INDEX IF NOT EXISTS auth_challenges_user ON auth_challenges(user_id, created_at DESC);

-- RNF-01: perfiles distintos de administrador y LeanKey privilegiado para los que la mandante exige 2FA.
CREATE TABLE IF NOT EXISTS mfa_policies (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 required_profiles text[] NOT NULL DEFAULT '{}'
   CHECK (required_profiles <@ ARRAY['supervisor','prevencion','seguridad','jefe_seguridad','contratista','trabajador']::text[]),
 reason text NOT NULL CHECK (length(trim(reason)) >= 5),
 configured_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS mfa_policies_client ON mfa_policies(client_id, id DESC);

-- RNF-03: enlaces de descarga temporales; se vuelven a autorizar al usarse.
CREATE TABLE IF NOT EXISTS download_links (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 token_hash text NOT NULL UNIQUE,
 user_id bigint NOT NULL REFERENCES users(id),
 resource text NOT NULL CHECK (resource IN ('documento')),
 resource_id bigint NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 expires_at timestamptz NOT NULL,
 uses integer NOT NULL DEFAULT 0
);

-- RNF-10: una operación repetida (doble clic o reintento tras cortarse la respuesta) se registra una sola vez.
CREATE TABLE IF NOT EXISTS idempotency_keys (
 scope text NOT NULL,
 key text NOT NULL,
 request_hash text NOT NULL,
 status integer,
 content_type text,
 body bytea,
 created_at timestamptz NOT NULL DEFAULT now(),
 expires_at timestamptz NOT NULL,
 PRIMARY KEY (scope, key)
);
CREATE INDEX IF NOT EXISTS idempotency_keys_expires ON idempotency_keys(expires_at);

-- RNF-07: bitácora de eliminaciones ejecutadas. Se replica fuera de la base para reaplicarla tras restaurar una
-- copia antigua y no volver a publicar información eliminada.
CREATE TABLE IF NOT EXISTS disposal_ledger (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 at timestamptz NOT NULL DEFAULT now(),
 client_id bigint REFERENCES clients(id),
 origin text NOT NULL,
 version_ids bigint[] NOT NULL DEFAULT '{}',
 file_ids bigint[] NOT NULL DEFAULT '{}',
 storage_keys text[] NOT NULL DEFAULT '{}',
 actor_id bigint REFERENCES users(id)
);

-- RNF-05/06/07: pruebas de restauración y simulacros con sus tiempos frente al objetivo.
CREATE TABLE IF NOT EXISTS recovery_drills (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 kind text NOT NULL CHECK (kind IN ('restauracion','simulacro')),
 scenario text NOT NULL CHECK (length(trim(scenario)) >= 5),
 backup_at timestamptz,
 detected_at timestamptz NOT NULL,
 restore_started_at timestamptz,
 restored_at timestamptz,
 validated_at timestamptz,
 integrity jsonb NOT NULL DEFAULT '{}',
 essential_functions jsonb NOT NULL DEFAULT '[]',
 succeeded boolean NOT NULL,
 notes text NOT NULL DEFAULT '',
 recorded_by bigint REFERENCES users(id),
 recorded_at timestamptz NOT NULL DEFAULT now(),
 CHECK (restored_at IS NULL OR restored_at >= detected_at),
 CHECK (validated_at IS NULL OR restored_at IS NULL OR validated_at >= restored_at)
);

-- RNF-12: zona horaria por instalación. Cada marcación guarda su fecha local y zona al registrarse: un cambio
-- posterior de zona u horario no cambia en silencio la fecha de una marcación histórica.
ALTER TABLE sites ADD COLUMN IF NOT EXISTS timezone text NOT NULL DEFAULT 'America/Santiago';
ALTER TABLE access_movements ADD COLUMN IF NOT EXISTS local_date date;
ALTER TABLE access_movements ADD COLUMN IF NOT EXISTS timezone text;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM access_movements WHERE local_date IS NULL) THEN
    ALTER TABLE access_movements DISABLE TRIGGER USER;
    UPDATE access_movements m
       SET timezone = coalesce(s.timezone, 'America/Santiago'),
           local_date = (m.event_at AT TIME ZONE coalesce(s.timezone, 'America/Santiago'))::date
      FROM services sv LEFT JOIN sites s ON s.id = sv.site_id
     WHERE sv.id = m.service_id AND m.local_date IS NULL;
    ALTER TABLE access_movements ENABLE TRIGGER USER;
  END IF;
END $$;

DO $$ DECLARE tab text; BEGIN
 FOREACH tab IN ARRAY ARRAY['mfa_policies','disposal_ledger','recovery_drills'] LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS nonfunctional_record_immutable ON %I',tab);
  EXECUTE format('CREATE TRIGGER nonfunctional_record_immutable BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION decision_records_immutable()',tab);
 END LOOP;
END $$;
-- RNF-02: también revoca ante cambios SQL, no solo desde una pantalla.
CREATE OR REPLACE FUNCTION revoke_changed_user_sessions() RETURNS trigger AS $$
DECLARE uid bigint;
BEGIN
 IF TG_TABLE_NAME = 'users' THEN
   IF (OLD.active,OLD.password_hash,OLD.capabilities,OLD.roles,OLD.contractor_id,OLD.worker_rut)
      IS NOT DISTINCT FROM (NEW.active,NEW.password_hash,NEW.capabilities,NEW.roles,NEW.contractor_id,NEW.worker_rut) THEN
     RETURN NEW;
   END IF;
   uid := NEW.id;
 ELSE
   IF TG_TABLE_NAME = 'service_supervisors' AND TG_OP = 'UPDATE' THEN
     IF (OLD.user_id,OLD.service_id,OLD.ended_at) IS NOT DISTINCT FROM (NEW.user_id,NEW.service_id,NEW.ended_at) THEN RETURN NEW; END IF;
   END IF;
   IF TG_OP = 'DELETE' THEN uid := OLD.user_id; ELSE uid := NEW.user_id; END IF;
 END IF;
 UPDATE sessions SET revoked_at=now() WHERE user_id=uid AND revoked_at IS NULL;
 UPDATE auth_challenges SET used_at=now() WHERE user_id=uid AND used_at IS NULL;
 IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS users_revoke_sessions ON users;
CREATE TRIGGER users_revoke_sessions AFTER UPDATE ON users FOR EACH ROW EXECUTE FUNCTION revoke_changed_user_sessions();
DROP TRIGGER IF EXISTS scopes_revoke_sessions ON user_client_scopes;
CREATE TRIGGER scopes_revoke_sessions AFTER INSERT OR UPDATE OR DELETE ON user_client_scopes FOR EACH ROW EXECUTE FUNCTION revoke_changed_user_sessions();
DROP TRIGGER IF EXISTS supervisors_revoke_sessions ON service_supervisors;
CREATE TRIGGER supervisors_revoke_sessions AFTER INSERT OR UPDATE OR DELETE ON service_supervisors FOR EACH ROW EXECUTE FUNCTION revoke_changed_user_sessions();

CREATE OR REPLACE FUNCTION capture_movement_local_time() RETURNS trigger AS $$
BEGIN
 SELECT timezone INTO NEW.timezone FROM sites WHERE id=NEW.site_id;
 NEW.timezone := coalesce(NEW.timezone,'America/Santiago');
 NEW.local_date := (NEW.event_at AT TIME ZONE NEW.timezone)::date;
 RETURN NEW;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS movement_local_time ON access_movements;
CREATE TRIGGER movement_local_time BEFORE INSERT ON access_movements FOR EACH ROW EXECUTE FUNCTION capture_movement_local_time();
CREATE INDEX IF NOT EXISTS access_movements_local_day ON access_movements(site_id,local_date,person_id);
CREATE INDEX IF NOT EXISTS audit_events_actor_time ON audit_events(actor_id,at DESC);
COMMIT;
