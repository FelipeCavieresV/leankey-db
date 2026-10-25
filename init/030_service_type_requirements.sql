-- Requerimientos documentales por tipo de servicio y función, y acceso de Prevención a los documentos de
-- trabajadores con autorización del administrador de la mandante. Idempotente.
BEGIN;

-- Tipo de servicio de la mandante (p. ej. Mantenimiento Electricidad, Aseo): agrupa sus funciones y la matriz
-- documental de cada una. Un servicio contratado puede declarar su tipo para ofrecer solo esas funciones.
CREATE TABLE IF NOT EXISTS service_types (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 name text NOT NULL CHECK (length(trim(name)) > 0),
 note text NOT NULL DEFAULT '',
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE (client_id, name)
);
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS service_type_id bigint REFERENCES service_types(id);
ALTER TABLE services ADD COLUMN IF NOT EXISTS service_type_id bigint REFERENCES service_types(id);
-- La función se nombra dentro de su tipo: «Supervisor» puede existir en Aseo y en otro tipo de servicio.
ALTER TABLE profiles DROP CONSTRAINT IF EXISTS profiles_client_id_name_key;
CREATE UNIQUE INDEX IF NOT EXISTS profiles_client_type_name ON profiles(client_id, coalesce(service_type_id, 0), name);

-- Opcional: se puede cargar y validar, pero no suma al porcentaje ni condiciona la habilitación.
ALTER TABLE profile_requirements DROP CONSTRAINT IF EXISTS profile_requirements_mode_check;
ALTER TABLE profile_requirements ADD CONSTRAINT profile_requirements_mode_check
 CHECK (mode IN ('obligatorio','condicional','opcional'));
ALTER TABLE profile_requirements DROP CONSTRAINT IF EXISTS profile_requirements_check;
ALTER TABLE profile_requirements ADD CONSTRAINT profile_requirements_check
 CHECK (mode <> 'condicional' OR length(trim(condition)) > 0);
-- Detalle exigible a la función (p. ej. «Licencia SEC clase B», «Examen de altura»). Vacío = sin detalle.
ALTER TABLE profile_requirements ADD COLUMN IF NOT EXISTS detail text NOT NULL DEFAULT '';

-- Documentos de acreditación individual de la planilla de requerimientos por tipo de servicio.
-- Vigencias sin definir quedan NULL: el administrador las configura en Documentos.
INSERT INTO document_types (code,name,scope,description,evidence,review_criteria,monthly_condition,sensitive,sensitivity) VALUES
 ('IRL','Registro IRL','worker','Información de riesgos laborales entregada al trabajador.','Registro firmado por el trabajador.','Identidad, fecha y riesgos de la función.','siempre',false,'ninguna'),
 ('DPS','Registro de capacitación PTS','worker','Difusión de los procedimientos de trabajo seguro: la misma cantidad de difusiones que de procedimientos.','Registro nominativo de cada difusión.','Identidad, procedimiento difundido y fecha.','siempre',false,'ninguna'),
 ('EPP','Registro de entrega de Elementos de Protección Personal','worker','Primera entrega y actualizaciones de los EPP.','Registro firmado de entrega.','Identidad, elementos entregados y fecha.','siempre',false,'ninguna'),
 ('RRI','Registro de entrega del Reglamento Interno de Orden, Higiene y Seguridad','worker','Entrega del RIOHS al trabajador.','Comprobante de entrega firmado.','Identidad, fecha y firma.','siempre',false,'ninguna'),
 ('EXO','Exámenes de salud ocupacional','worker','Altura física, espacios confinados u otros según aplique a la función.','Certificado de aptitud (sin diagnóstico).','Resultado apto, tipo de examen y vigencia.','siempre',true,'medica'),
 ('CVA','Certificado de vacunación','worker','Vacunas exigidas a la función (p. ej. hepatitis, influenza en campaña de invierno).','Certificado o carnet de vacunación.','Identidad, vacuna y fecha.','siempre',true,'medica'),
 ('CTE','Certificado de especialidad','worker','Soldador, eléctrico, transporte vertical, RCI u otros según aplique.','Certificado de la especialidad.','Identidad, especialidad y vigencia.','siempre',false,'ninguna'),
 ('SEC','Licencia SEC eléctrico','worker','Licencia SEC de instalador eléctrico clase A, B, C o D.','Credencial o certificado SEC.','Identidad, clase de licencia y vigencia.','siempre',false,'ninguna'),
 ('CDS','Certificado de soldador','worker','Certificación de soldador.','Certificado vigente.','Identidad, proceso certificado y vigencia.','siempre',false,'ninguna'),
 ('DMP','Registro de entrega de matriz de riesgos','worker','Entrega de la matriz de riesgos al trabajador.','Registro firmado.','Identidad, fecha y matriz entregada.','siempre',false,'ninguna'),
 ('RCX','Registro de capacitación en uso de extintores','worker','Capacitación en uso de extintores.','Registro de asistencia o certificado.','Identidad, contenido y fecha.','siempre',false,'ninguna'),
 ('CUC','Registro de capacitación en uso y mantención de EPP','worker','Capacitación en uso y mantención de los EPP.','Registro de asistencia o certificado.','Identidad, contenido y fecha.','siempre',false,'ninguna'),
 ('RCE','Registro de capacitación por especialidad','worker','Equipos médicos, Aseo-REAS, obras civiles, climatización, alimentación, transporte vertical, electricidad, RCI.','Registro de asistencia o certificado.','Identidad, especialidad y fecha.','siempre',false,'ninguna'),
 ('OS1','OS-10','worker','Acreditación OS-10 para funciones de seguridad.','Credencial OS-10 vigente.','Identidad y vigencia.','siempre',false,'ninguna'),
 ('CPS','Capacitación de personal que usa sustancias peligrosas','worker','Capacitación en manejo de sustancias peligrosas (p. ej. REAS).','Registro de asistencia o certificado.','Identidad, contenido y fecha.','siempre',false,'ninguna')
ON CONFLICT (code) DO NOTHING;

-- Prevención de la mandante consulta los documentos de trabajadores solo con el visto bueno de su administrador.
-- Pedir, autorizar, rechazar y revocar quedan con autor y fecha; a lo más una fila abierta por persona y mandante.
CREATE TABLE IF NOT EXISTS prevention_document_access (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 client_id bigint NOT NULL REFERENCES clients(id),
 user_id bigint NOT NULL REFERENCES users(id),
 state text NOT NULL CHECK (state IN ('solicitada','autorizada','rechazada','revocada')),
 request_note text NOT NULL DEFAULT '',
 requested_at timestamptz,
 decided_by bigint REFERENCES users(id),
 decided_at timestamptz,
 decision_note text NOT NULL DEFAULT '',
 revoked_by bigint REFERENCES users(id),
 revoked_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK (state = 'solicitada' OR (decided_by IS NOT NULL AND decided_at IS NOT NULL)),
 CHECK ((state = 'revocada') = (revoked_by IS NOT NULL AND revoked_at IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS prevention_document_access_open
 ON prevention_document_access(client_id, user_id) WHERE state IN ('solicitada','autorizada');

COMMIT;
