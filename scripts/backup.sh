#!/usr/bin/env bash
# Backup logico de la BD (pg_dump -Fc) + roles (globals). Rota los mas antiguos.
# Uso:  ./scripts/backup.sh        (desde cualquier carpeta)
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

CONT="${DB_CONTAINER:-jardineria_db}"
DEST="${BACKUP_DIR:-$HOME/backups}"
KEEP="${BACKUP_KEEP:-7}"
TS="$(date +%Y%m%d_%H%M%S)"
F="$DEST/${DB_NAME}_${TS}.dump"
G="$DEST/globals_${TS}.sql"

mkdir -p "$DEST"; chmod 700 "$DEST"
trap 'rm -f "$F.tmp" "$G.tmp"' EXIT

docker exec "$CONT" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc > "$F.tmp"
docker exec "$CONT" pg_dumpall -U "$DB_USER" --globals-only > "$G.tmp"   # roles app_user / reportes_user

# Valida que el dump sea legible antes de darlo por bueno
docker exec -i "$CONT" pg_restore -l < "$F.tmp" > /dev/null
[ -s "$F.tmp" ] && [ -s "$G.tmp" ]

mv "$F.tmp" "$F"; mv "$G.tmp" "$G"
chmod 600 "$F" "$G"

# Rotacion: conserva los KEEP mas recientes de cada tipo
ls -1t "$DEST"/${DB_NAME}_*.dump 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
ls -1t "$DEST"/globals_*.sql     2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f

echo "$(date -Is) OK backup $F ($(du -h "$F" | cut -f1))"
