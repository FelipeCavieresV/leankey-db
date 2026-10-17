-- REP-01…06: reposos, reincorporación y rectificaciones, separados de la investigación del accidente. Idempotente.
BEGIN;

-- Restricciones de ingreso con origen y levantamiento trazable: una rectificación revisada anula la situación
-- (quién, cuándo y por qué) en vez de borrarla o recortarla en silencio.
ALTER TABLE worker_situations ADD COLUMN IF NOT EXISTS origin text NOT NULL DEFAULT 'dotacion';
ALTER TABLE worker_situations DROP CONSTRAINT IF EXISTS worker_situations_origin_check;
ALTER TABLE worker_situations ADD CONSTRAINT worker_situations_origin_check CHECK (origin IN ('dotacion','reposo_preventivo'));
UPDATE worker_situations s SET origin='reposo_preventivo'
FROM prevention_rests r WHERE r.situation_id=s.id AND s.origin<>'reposo_preventivo';
ALTER TABLE worker_situations ADD COLUMN IF NOT EXISTS voided_at timestamptz;
ALTER TABLE worker_situations ADD COLUMN IF NOT EXISTS voided_by bigint REFERENCES users(id);
ALTER TABLE worker_situations ADD COLUMN IF NOT EXISTS void_reason text;
ALTER TABLE worker_situations DROP CONSTRAINT IF EXISTS worker_situations_void_check;
ALTER TABLE worker_situations ADD CONSTRAINT worker_situations_void_check
 CHECK ((voided_at IS NULL) = (voided_by IS NULL) AND (voided_at IS NULL) = (void_reason IS NULL));

-- REP-01: un nuevo período (posterior a una reincorporación) reactiva la restricción; prórroga y nuevo período
-- referencian el respaldo anterior de la misma persona.
ALTER TABLE prevention_rests DROP CONSTRAINT IF EXISTS prevention_rests_kind_check;
ALTER TABLE prevention_rests ADD CONSTRAINT prevention_rests_kind_check CHECK (kind IN ('inicial','prorroga','nuevo_periodo'));
ALTER TABLE prevention_rests DROP CONSTRAINT IF EXISTS prevention_rests_check1;
ALTER TABLE prevention_rests DROP CONSTRAINT IF EXISTS prevention_rests_previous_check;
ALTER TABLE prevention_rests ADD CONSTRAINT prevention_rests_previous_check CHECK ((kind='inicial') = (previous_id IS NULL));
-- REP-03: los respaldos registrados antes de 022 no exigen alta (sin bloqueo retroactivo); los nuevos sí.
ALTER TABLE prevention_rests ADD COLUMN IF NOT EXISTS reinstatement_required boolean NOT NULL DEFAULT false;
ALTER TABLE prevention_rests ALTER COLUMN reinstatement_required SET DEFAULT true;

ALTER TABLE prevention_evidence DROP CONSTRAINT IF EXISTS prevention_evidence_purpose_check;
ALTER TABLE prevention_evidence ADD CONSTRAINT prevention_evidence_purpose_check
 CHECK (purpose IN ('investigacion','clasificacion','reposo','reapertura','correccion','alta'));

-- REP-06: horario de atención aprobado de LeanKey, versionado. Cada solicitud conserva la versión con que se
-- calculó su plazo; un cambio posterior no reescribe plazos ya comunicados.
CREATE TABLE IF NOT EXISTS leankey_attention_schedules (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 weekdays smallint[] NOT NULL CHECK (cardinality(weekdays) > 0 AND weekdays <@ ARRAY[1,2,3,4,5,6,7]::smallint[]),
 opens_at time NOT NULL,
 closes_at time NOT NULL CHECK (closes_at > opens_at),
 reason text NOT NULL,
 configured_by bigint REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO leankey_attention_schedules (weekdays, opens_at, closes_at, reason)
SELECT ARRAY[1,2,3,4,5]::smallint[], '09:00', '18:00',
       'Horario de atención inicial: lunes a viernes, 09:00 a 18:00, sin feriados registrados'
WHERE NOT EXISTS (SELECT 1 FROM leankey_attention_schedules);

-- REP-03 / DEP-01: uso de la declaración de alta sin verificación independiente, por mandante. Sin registro rige
-- el acuerdo de producto (habilitado). No es una aprobación de casos: la mandante no aprueba reposos ni altas.
CREATE TABLE IF NOT EXISTS rest_policies (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 declaration_tolerance boolean NOT NULL,
 reason text NOT NULL,
 configured_by bigint NOT NULL REFERENCES users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS rest_policies_client ON rest_policies(client_id, id DESC);

-- REP-05: rectificaciones vinculadas al respaldo original, que se conserva. Acortar, anular o cambiar de persona
-- con restricción vigente exigen revisión de LeanKey; ampliar y cambios sin efecto en acceso rigen al registrarse.
CREATE TABLE IF NOT EXISTS rest_rectifications (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 rest_id bigint NOT NULL REFERENCES prevention_rests(id),
 kind text NOT NULL CHECK (kind IN ('acortar','ampliar','anular','persona','datos')),
 starts_on date,
 ends_on date,
 participant_id bigint REFERENCES prevention_participants(id),
 issuer text,
 reason text NOT NULL CHECK (length(trim(reason)) >= 5),
 evidence_id bigint REFERENCES prevention_evidence(id),
 requires_review boolean NOT NULL,
 situation_id bigint REFERENCES worker_situations(id),
 attention_due_at timestamptz,
 attention_schedule_id bigint REFERENCES leankey_attention_schedules(id),
 requested_by bigint NOT NULL REFERENCES users(id),
 requested_at timestamptz NOT NULL DEFAULT now(),
 CHECK ((kind IN ('acortar','ampliar')) = (starts_on IS NOT NULL AND ends_on IS NOT NULL)),
 CHECK (ends_on IS NULL OR ends_on >= starts_on),
 CHECK ((kind='persona') = (participant_id IS NOT NULL)),
 CHECK ((kind='datos') = (issuer IS NOT NULL)),
 CHECK (kind NOT IN ('acortar','anular','persona') OR evidence_id IS NOT NULL),
 CHECK (requires_review = (attention_due_at IS NOT NULL AND attention_schedule_id IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS rest_rectifications_rest ON rest_rectifications(rest_id, id);
CREATE TABLE IF NOT EXISTS rest_rectification_decisions (
 rectification_id bigint PRIMARY KEY REFERENCES rest_rectifications(id),
 approved boolean NOT NULL,
 reason text NOT NULL CHECK (length(trim(reason)) >= 5),
 situation_id bigint REFERENCES worker_situations(id),
 decided_by bigint NOT NULL REFERENCES users(id),
 decided_at timestamptz NOT NULL DEFAULT now()
);

-- REP-03: alta laboral. La declaración (emisión y fecha) da la tolerancia de carga; el respaldo lo verifica LeanKey
-- (respaldo, no aptitud médica). Ambos quedan ligados al término del período que cierran.
CREATE TABLE IF NOT EXISTS rest_reinstatements (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 participant_id bigint NOT NULL REFERENCES prevention_participants(id),
 kind text NOT NULL CHECK (kind IN ('declaracion','respaldo')),
 rest_end_on date NOT NULL,
 issued_on date NOT NULL,
 return_on date NOT NULL CHECK (return_on > rest_end_on),
 issuer text NOT NULL CHECK (length(trim(issuer)) >= 2),
 statement text NOT NULL DEFAULT '',
 evidence_id bigint REFERENCES prevention_evidence(id),
 load_due_on date NOT NULL CHECK (load_due_on >= return_on),
 timely boolean,
 attention_due_at timestamptz,
 attention_schedule_id bigint REFERENCES leankey_attention_schedules(id),
 recorded_by bigint NOT NULL REFERENCES users(id),
 recorded_at timestamptz NOT NULL DEFAULT now(),
 CHECK ((kind='respaldo') = (evidence_id IS NOT NULL)),
 CHECK ((kind='respaldo') = (timely IS NOT NULL)),
 CHECK (kind='respaldo' OR length(trim(statement)) >= 5)
);
CREATE INDEX IF NOT EXISTS rest_reinstatements_participant ON rest_reinstatements(participant_id, id DESC);
CREATE UNIQUE INDEX IF NOT EXISTS rest_reinstatements_one_declaration
 ON rest_reinstatements(participant_id, rest_end_on) WHERE kind='declaracion';
CREATE TABLE IF NOT EXISTS rest_reinstatement_reviews (
 reinstatement_id bigint PRIMARY KEY REFERENCES rest_reinstatements(id),
 decision text NOT NULL CHECK (decision IN ('verificado','observado')),
 reason text NOT NULL CHECK (length(trim(reason)) >= 5),
 reviewed_by bigint NOT NULL REFERENCES users(id),
 reviewed_at timestamptz NOT NULL DEFAULT now()
);

DO $$ DECLARE tab text; BEGIN
 FOREACH tab IN ARRAY ARRAY['leankey_attention_schedules','rest_policies','rest_rectifications','rest_rectification_decisions','rest_reinstatements','rest_reinstatement_reviews'] LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS rest_record_immutable ON %I',tab);
  EXECUTE format('CREATE TRIGGER rest_record_immutable BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION decision_records_immutable()',tab);
 END LOOP;
END $$;
COMMIT;
