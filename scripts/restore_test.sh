#!/usr/bin/env bash
# Prueba de restauracion: restaura el ultimo backup en una BD temporal DENTRO del mismo contenedor
# (no toca la BD real) y compara conteos, rutinas, triggers, vistas y permisos contra la BD real.
# Uso:  ./scripts/restore_test.sh [ruta/al/archivo.dump]
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

CONT="${DB_CONTAINER:-jardineria_db}"
DEST="${BACKUP_DIR:-$HOME/backups}"
TESTDB="${DB_NAME}_restore_test"
F="${1:-$(ls -1t "$DEST"/${DB_NAME}_*.dump | head -1)}"
[ -f "$F" ] || { echo "No hay backup en $DEST"; exit 1; }
echo "Backup a probar: $F"

SQL=$(cat <<'EOSQL'
SELECT 'tabla ' || table_schema || '.' || table_name AS k,
       (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text AS v
FROM information_schema.tables
WHERE table_type = 'BASE TABLE' AND table_schema IN ('auditoria','clientes','operaciones','seguridad')
UNION ALL SELECT 'rutinas (operaciones+auditoria)', count(*)::text
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname IN ('auditoria','operaciones')
UNION ALL SELECT 'triggers', count(*)::text FROM pg_trigger WHERE NOT tgisinternal
UNION ALL SELECT 'vistas reportes', count(*)::text FROM pg_views WHERE schemaname = 'reportes'
UNION ALL SELECT 'app_user lee pedido', has_table_privilege('app_user','operaciones.pedido','SELECT')::text
UNION ALL SELECT 'app_user lee auditoria.log (debe ser false)', has_table_privilege('app_user','auditoria.log','SELECT')::text
UNION ALL SELECT 'reportes_user lee pedido (debe ser false)', has_table_privilege('reportes_user','operaciones.pedido','SELECT')::text
UNION ALL SELECT 'reportes_user lee v_auditoria', has_table_privilege('reportes_user','reportes.v_auditoria','SELECT')::text
ORDER BY 1;
EOSQL
)

psql_db() { docker exec -i "$CONT" psql -U "$DB_USER" -X -q -A -t -v ON_ERROR_STOP=1 "$@"; }
cleanup() { docker exec "$CONT" dropdb -U "$DB_USER" --if-exists "$TESTDB" >/dev/null 2>&1 || true; }
trap cleanup EXIT

cleanup
docker exec "$CONT" createdb -U "$DB_USER" "$TESTDB"
docker exec -i "$CONT" pg_restore -U "$DB_USER" -d "$TESTDB" --exit-on-error < "$F"
echo "Restauracion completada en $TESTDB"

echo "$SQL" | psql_db -d "$DB_NAME" > /tmp/rt_real.txt
echo "$SQL" | psql_db -d "$TESTDB"  > /tmp/rt_rest.txt

if diff /tmp/rt_real.txt /tmp/rt_rest.txt; then
  echo "RESULTADO: OK - la restauracion coincide con la BD real ($(wc -l < /tmp/rt_rest.txt) comprobaciones)"
else
  echo "RESULTADO: HAY DIFERENCIAS (arriba). Si hubo actividad en la app despues del backup,"
  echo "           repite: ./scripts/backup.sh && ./scripts/restore_test.sh"
  exit 1
fi
