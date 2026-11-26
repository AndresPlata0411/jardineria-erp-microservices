#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<EOSQL
CREATE ROLE app_user LOGIN PASSWORD '${APP_PASSWORD}';
CREATE ROLE reportes_user LOGIN PASSWORD '${REPORTES_PASSWORD}';
GRANT USAGE ON SCHEMA clientes, operaciones, seguridad TO app_user;
GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA clientes, operaciones, seguridad TO app_user;
GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA clientes, operaciones, seguridad TO app_user;
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA operaciones TO app_user;
GRANT USAGE ON SCHEMA reportes TO reportes_user;
GRANT SELECT ON ALL TABLES IN SCHEMA reportes TO reportes_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA reportes GRANT SELECT ON TABLES TO reportes_user;
EOSQL
