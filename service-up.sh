#!/usr/bin/env bash
#
# service-up.sh — sobe toda a stack do SMS Sender.
# O APK Android e buildado DENTRO da imagem web (multi-stage), entao nao
# precisa de toolchain local. A 1a build baixa o Android SDK (lenta);
# as seguintes usam o cache de layers do Docker (rapidas).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# carrega dominios/vars do .env (set -a exporta pro compose)
if [ -f .env ]; then set -a; . ./.env 2>/dev/null || true; set +a; fi
WEB_URL="${WEB_URL:-http://localhost:3000}"
API_BASE_URL="${API_BASE_URL:-http://localhost:3001/api/v1/}"

log() { printf "\n\033[1;36m==> %s\033[0m\n" "$1"; }
ok()  { printf "    \033[1;32m✓\033[0m %s\n" "$1"; }

command -v docker >/dev/null || { echo "docker nao encontrado no PATH"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "'docker compose' indisponivel"; exit 1; }

log "Subindo a stack (docker compose up -d --build)"
echo "    (1a vez builda o APK no Docker — baixa o Android SDK, leva alguns minutos)"
# local: carrega o override que expoe as portas no host (em prod/Dokploy nao se usa)
DOCKER_BUILDKIT=1 docker compose -f docker-compose.yaml -f docker-compose.local.yml up -d --build

log "Aguardando servicos responderem"
wait_http() {
  local url="$1" name="$2" code
  for _ in $(seq 1 120); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000)"
    [ "$code" != "000" ] && { ok "$name (HTTP $code)"; return 0; }
    sleep 2
  done
  printf "    ! %s nao respondeu (%s)\n" "$name" "$url"
}
wait_http "http://localhost:3001/"               "API  :3001"
wait_http "http://localhost:3000/"               "Web  :3000"
wait_http "http://localhost:3000/sms-sender.apk" "APK  :3000/sms-sender.apk"

log "Status dos containers"
docker compose ps --format 'table {{.Service}}\t{{.Status}}'

printf "\n    Firebase: "
if docker compose logs textbee-api --since 5m 2>/dev/null | grep -qi "Firebase initialized"; then
  printf "ATIVO (push ligado)\n"
elif docker compose logs textbee-api --since 5m 2>/dev/null | grep -qi "skipping firebase"; then
  printf "DESLIGADO (FIREBASE_* vazio em api/.env)\n"
else
  printf "?\n"
fi

cat <<EOF

Pronto! ✅  Aponte seu tunel/proxy:
  Dashboard: ${WEB_URL}        -> porta 3000
  API:       ${API_BASE_URL}   -> porta 3001

  Local:  http://localhost:3000   |   http://localhost:3001
  APK:    http://localhost:3000/sms-sender.apk
EOF
