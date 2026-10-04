-- Catálogo documental inicial (sección 13 de los requerimientos v0.1).
-- Vigencias sin definir quedan NULL: el administrador las configura en Documentos.
-- Las denominaciones y su exigibilidad requieren validación especializada (D13).
BEGIN;
INSERT INTO document_types (code,name,scope,description,evidence,review_criteria,monthly_condition,sensitive) VALUES
 ('EMP-RIOHS','Reglamento Interno de Orden, Higiene y Seguridad','company','RIOHS vigente de la empresa contratista.','Documento RIOHS completo.','Corresponde a la empresa y está vigente.','siempre',false),
 ('EMP-RIOHS-DT','Respaldo de trámite RIOHS ante la DT','company','Comprobante de presentación del RIOHS ante la Dirección del Trabajo.','Comprobante de trámite.','Identifica empresa y fecha de presentación.','siempre',false),
 ('EMP-RIOHS-SEREMI','Respaldo de trámite RIOHS ante SEREMI de Salud','company','Comprobante de presentación ante SEREMI de Salud.','Comprobante de trámite.','Identifica empresa y fecha de presentación.','siempre',false),
 ('EMP-REG-CONTRATISTAS','Acuse de Reglamento para Empresas Contratistas','company','Acuse de recibo del reglamento del mandante.','Acuse firmado.','Firmado por representante de la empresa.','siempre',false),
 ('EMP-MIPER','Matriz de identificación de peligros y evaluación de riesgos (MIPER)','company','MIPER de las actividades del servicio.','Matriz vigente.','Cubre las actividades del servicio.','siempre',false),
 ('EMP-PROG-PREV','Programa de Prevención de Riesgos','company','Programa de prevención aplicable al servicio.','Programa vigente.','Incluye actividades y responsables.','siempre',false),
 ('EMP-OAL-ADH','Certificado de adhesión a organismo administrador (OAL)','company','Adhesión a mutualidad u organismo administrador de la ley.','Certificado de adhesión.','Emitido por el organismo administrador.','siempre',false),
 ('EMP-OAL-SIN','Certificado de siniestralidad OAL','company','Tasa de siniestralidad informada por el organismo administrador.','Certificado de siniestralidad.','Periodo informado y empresa coinciden.','siempre',false),
 ('EMP-EXPERTO-SEREMI','Registro del experto en prevención ante SEREMI','company','Registro asociado al profesional responsable de prevención y su período.','Credencial o resolución de registro.','Titular coincide con el responsable informado.','siempre',false),
 ('EMP-PTS','Procedimiento de Trabajo Seguro (PTS)','company','PTS empresarial por versión.','Procedimiento firmado y versionado.','Código y versión identificados.','siempre',false),
 ('TRA-ODI','Información de riesgos laborales (ODI/IRL)','worker','Registro de información de riesgos firmado por el trabajador.','Registro firmado.','Identidad, fecha y riesgos del cargo.','siempre',false),
 ('TRA-EPP','Registro de entrega de EPP','worker','Entrega de elementos de protección personal.','Registro firmado.','Identidad y elementos entregados.','siempre',false),
 ('TRA-CAP','Capacitación aplicable al cargo','worker','Capacitaciones exigidas por el perfil.','Certificado o registro de asistencia.','Identidad, contenido y fecha.','siempre',false),
 ('TRA-LIC','Licencia o competencia habilitante','worker','Licencias y competencias cuando la tarea las exige.','Licencia o certificado vigente.','Vigencia y clase acorde a la tarea.','siempre',false),
 ('TRA-EXP','Formación o experiencia','worker','Antecedentes de formación o experiencia del cargo.','Certificado o currículum validado.','Coherencia con el perfil.','siempre',false),
 ('TRA-EXAMEN','Examen ocupacional aplicable','worker','Examen preocupacional u ocupacional según exposición.','Certificado de aptitud (sin diagnóstico).','Resultado apto y vigencia.','siempre',true),
 ('PTS-ALT-DIF','Difusión del procedimiento de trabajo en altura','worker','Difusión del PTS de altura al trabajador.','Registro nominativo asociado a PTS y versión.','Identidad, participación, fecha y versión.','siempre',false),
 ('MEN-LIQ','Liquidación de sueldo','monthly_worker','Liquidación del mes trabajado.','Liquidación del período.','Período, trabajador y empleador coinciden.','siempre',true),
 ('MEN-CONTRATO','Contrato de trabajo y anexos','monthly_worker','Contrato vigente y anexos; se vincula sin exigir copia mensual.','Contrato y anexos firmados.','Versión contractual aplicable al mes.','contrato',true),
 ('MEN-AFP','Certificado de cotizaciones AFP','monthly_worker','Cotizaciones previsionales del mes.','Certificado de cotizaciones.','Período y RUT coinciden.','siempre',true),
 ('MEN-ABONO','Comprobante de abono de remuneración','monthly_worker','Pago de la remuneración del mes.','Comprobante bancario.','Monto, fecha y trabajador.','siempre',true),
 ('MEN-FINIQUITO','Finiquito','monthly_worker','Finiquito ratificado cuando termina la relación laboral.','Finiquito ratificado.','Firmado y ratificado.','termino',true),
 ('MEN-RENUNCIA','Renuncia ratificada','monthly_worker','Renuncia ratificada cuando corresponde.','Carta de renuncia ratificada.','Ratificación ante ministro de fe.','renuncia',true),
 ('MEN-TRASLADO','Anexo de traslado','monthly_worker','Anexo cuando el trabajador se traslada.','Anexo firmado.','Fecha y destino del traslado.','traslado',false),
 ('MEN-TERMINO-DT','Notificación de término a la DT','monthly_worker','Aviso de término de contrato a la Dirección del Trabajo.','Comprobante DT.','Fecha y causal informadas.','termino',true),
 ('MEM-PREVIRED','Planilla PREVIRED (comprobante de pago y detalle)','monthly_company','Comprobante de pago y detalle de planillas; puede ser un archivo conjunto.','Comprobante y detalle PREVIRED.','Período y empresa coinciden.','siempre',true),
 ('MEM-LRE-CSV','Libro de remuneraciones (CSV)','monthly_company','Libro de remuneraciones electrónico en CSV.','Archivo CSV.','Período y empresa coinciden.','siempre',true),
 ('MEM-LRE-COMP','Comprobante de declaración del LRE','monthly_company','Comprobante de declaración del libro ante la DT.','Comprobante DT.','Período declarado.','siempre',true),
 ('MEM-PREVIRED-CSV','CSV PREVIRED','monthly_company','Archivo CSV de PREVIRED del período.','Archivo CSV.','Período y empresa coinciden.','siempre',true)
ON CONFLICT (code) DO NOTHING;

-- Feriados de referencia 2026; editables en Configuración (validar con calendario oficial).
INSERT INTO holidays (day,name) VALUES
 ('2026-01-01','Año Nuevo'),('2026-04-03','Viernes Santo'),('2026-04-04','Sábado Santo'),
 ('2026-05-01','Día del Trabajo'),('2026-05-21','Glorias Navales'),('2026-06-21','Pueblos Indígenas'),
 ('2026-06-29','San Pedro y San Pablo'),('2026-07-16','Virgen del Carmen'),('2026-08-15','Asunción de la Virgen'),
 ('2026-09-18','Independencia Nacional'),('2026-09-19','Glorias del Ejército'),('2026-10-12','Encuentro de Dos Mundos'),
 ('2026-10-31','Iglesias Evangélicas'),('2026-11-01','Todos los Santos'),('2026-12-08','Inmaculada Concepción'),
 ('2026-12-25','Navidad')
ON CONFLICT (day) DO NOTHING;
COMMIT;
