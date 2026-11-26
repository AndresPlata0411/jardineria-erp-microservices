#!/usr/bin/env bash
# Checklist final de verificacion (se corre EN el VPS). Imprime PASS/FAIL por item.
# Opcional: CHECK_USER=admin CHECK_PASS=... ./scripts/checklist.sh   (prueba login por HTTPS)
#           RUN_TESTS=1 ./scripts/checklist.sh                       (ejecuta db/tests/tests.sql)
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
CONT="${DB_CONTAINER:-jardineria_db}"
DEST="${BACKUP_DIR:-$HOME/backups}"
URL="https://${DOMAIN}"
ok=0; bad=0

chk() { local d="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "PASS  $d"; ok=$((ok+1)); else echo "FAIL  $d"; bad=$((bad+1)); fi; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

echo "== Contenedores =="
chk "7 servicios en ejecucion (postgres, clientes, operaciones, reportes, gateway, frontend, caddy)" \
    test "$(docker compose ps --status running -q | wc -l)" -ge 7
chk "ningun contenedor unhealthy" test -z "$(docker ps --filter health=unhealthy -q)"

echo "== HTTPS y dominio ($DOMAIN) =="
chk "HTTPS /app/ responde 200 con certificado valido" test "$(code "$URL/app/")" = "200"
chk "HTTP redirige a HTTPS" bash -c "c=\$(curl -s -o /dev/null -w '%{http_code}' http://${DOMAIN}/); [[ \$c =~ ^(301|302|307|308)\$ ]]"
chk "Swagger operaciones accesible (/api/operaciones/docs)" test "$(code "$URL/api/operaciones/docs")" = "200"
chk "API sin token responde 401" test "$(code "$URL/api/clientes/clientes")" = "401"
chk "ruta raiz redirige a /app/" bash -c "curl -sI ${URL}/ | grep -qi '^location: .*/app/'"
if [ -n "${CHECK_USER:-}" ] && [ -n "${CHECK_PASS:-}" ]; then
  TOKEN=$(curl -s "$URL/api/operaciones/auth/login" -H 'content-type: application/json' \
          -d "{\"usuario\":\"$CHECK_USER\",\"password\":\"$CHECK_PASS\"}" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
  chk "login por HTTPS entrega JWT" test -n "$TOKEN"
  chk "/auth/me con JWT responde 200" test "$(code "$URL/api/operaciones/auth/me" -H "Authorization: Bearer $TOKEN")" = "200"
fi
echo "   certificado: $(echo | openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -issuer -enddate 2>/dev/null | tr '\n' ' ')"

echo "== Exposicion de puertos (en el VPS) =="
chk "Postgres solo en 127.0.0.1" bash -c "! ss -tlnH | awk '{print \$4}' | grep -E '^(0\.0\.0\.0|\*|\[::\]):(5432|5433)\$'"
chk "Gateway 8080 solo en 127.0.0.1" bash -c "! ss -tlnH | awk '{print \$4}' | grep -E '^(0\.0\.0\.0|\*|\[::\]):8080\$'"
echo "   escuchando en todas las interfaces: $(ss -tlnH | awk '{print $4}' | grep -E '^(0\.0\.0\.0|\*|\[::\]):' | sed 's/.*://' | sort -un | tr '\n' ' ')  (esperado: 22 80 443)"

echo "== Secretos =="
chk ".env ignorado por git" bash -c "git check-ignore -q .env"
chk "JWT_SECRET de 32+ caracteres" test "${#JWT_SECRET}" -ge 32

echo "== Respaldos =="
chk "existe un backup de las ultimas 36 h" bash -c "find '$DEST' -name '${DB_NAME}_*.dump' -mmin -2160 | grep -q ."
chk "cron del backup instalado" bash -c "crontab -l 2>/dev/null | grep -q backup.sh"

if [ "${RUN_TESTS:-0}" = "1" ]; then
  echo "== Pruebas SQL =="
  chk "db/tests/tests.sql sin errores" bash -c "docker exec -i $CONT psql -U $DB_USER -d $DB_NAME -v ON_ERROR_STOP=1 < db/tests/tests.sql"
fi

echo; echo "Resultado: $ok PASS, $bad FAIL"
echo "Pendiente de comprobar FUERA del VPS (desde tu PC o el celular con datos moviles): abrir $URL/app/"
[ "$bad" -eq 0 ]
