-- PER-01…06: carga, modificación y aprobación son permisos independientes.
-- Conserva por única vez lo que cada cuenta ya podía hacer. Una revocación posterior no se repone.
BEGIN;

ALTER TABLE users DROP CONSTRAINT IF EXISTS users_internal_capabilities;
ALTER TABLE users ADD CONSTRAINT users_internal_capabilities CHECK (
 kind = 'admin' OR NOT (capabilities && ARRAY['approve','review','review_labor','configure','manage_users','all_clients','critical_tickets'])
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE name = '028_independent_actions') THEN
    UPDATE users u
    SET capabilities = (
      SELECT coalesce(array_agg(DISTINCT c ORDER BY c), '{}')
      FROM unnest(
        u.capabilities
        || CASE WHEN u.capabilities && ARRAY['upload','configure','manage_users']
             OR u.roles && ARRAY['administrador','supervisor'] THEN ARRAY['edit'] ELSE '{}' END
        || CASE WHEN u.kind = 'admin' AND (u.roles && ARRAY['administrador','supervisor','prevencion']
             OR u.capabilities && ARRAY['review','review_labor']) THEN ARRAY['approve'] ELSE '{}' END
      ) AS c
    )
    WHERE u.kind IN ('admin','contractor');
    INSERT INTO schema_migrations (name) VALUES ('028_independent_actions');
  END IF;
END $$;

COMMIT;
