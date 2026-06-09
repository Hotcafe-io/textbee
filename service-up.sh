#!/usr/bin/env bash
#
# service-up.sh — builda o APK e sobe toda a infra do SMS Sender (TextBee self-hosted)
#
# Uso:
#   ./service-up.sh            builda o APK + sobe tudo
#   SKIP_APK=1 ./service-up.sh sobe a infra sem rebuildar o APK (mais rápido)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

TOOLCHAIN="$ROOT/.toolchain"
JAVA_HOME="$(find "$TOOLCHAIN" -maxdepth 1 -type d -name 'jdk-11*' 2>/dev/null | head -1)"
ANDROID_SDK_ROOT="$TOOLCHAIN/android-sdk"
export JAVA_HOME ANDROID_SDK_ROOT
export PATH="${JAVA_HOME:-}/bin:$PATH"

SKIP_APK="${SKIP_APK:-0}"

# Carrega os dominios do .env da raiz (fonte unica). 'set -a' exporta as vars,
# entao API_BASE_URL fica disponivel pro build do APK (build.gradle le do env).
if [ -f .env ]; then set -a; . ./.env 2>/dev/null || true; set +a; fi
WEB_URL="${WEB_URL:-http://localhost:3000}"
API_BASE_URL="${API_BASE_URL:-http://localhost:3001/api/v1/}"

log()  { printf "\n\033[1;36m==> %s\033[0m\n" "$1"; }
ok()   { printf "    \033[1;32m✓\033[0m %s\n" "$1"; }
err()  { printf "\n\033[1;31m✗ ERRO: %s\033[0m\n" "$1" >&2; }

command -v docker >/dev/null || { err "docker não encontrado no PATH"; exit 1; }
docker compose version >/dev/null 2>&1 || { err "'docker compose' indisponível"; exit 1; }

# ------------------------------------------------------------------ APK build
if [ "$SKIP_APK" != "1" ]; then
  log "Verificando toolchain Android"
  [ -n "$JAVA_HOME" ] && [ -x "$JAVA_HOME/bin/java" ] || { err "JDK 11 não encontrado em $TOOLCHAIN (jdk-11*)"; exit 1; }
  [ -d "$ANDROID_SDK_ROOT/platforms" ] || { err "Android SDK não encontrado em $ANDROID_SDK_ROOT"; exit 1; }
  [ -f android/app/google-services.json ] || { err "android/app/google-services.json ausente (obrigatório pro build do Firebase)"; exit 1; }
  ok "JDK: $JAVA_HOME"
  ok "SDK: $ANDROID_SDK_ROOT"

  # a build de release assina com o debug keystore (sideload)
  KS="$HOME/.android/debug.keystore"
  if [ ! -f "$KS" ]; then
    log "Gerando debug.keystore"
    mkdir -p "$HOME/.android"
    "$JAVA_HOME/bin/keytool" -genkeypair -v -keystore "$KS" -storepass android \
      -alias androiddebugkey -keypass android -keyalg RSA -keysize 2048 -validity 10000 \
      -dname "CN=Android Debug,O=Android,C=US"
  fi

  log "Buildando APK (assembleProdRelease)"
  ( cd android && chmod +x gradlew && ./gradlew assembleProdRelease --no-daemon )

  APK_SRC="android/app/build/outputs/apk/prod/release/app-prod-release.apk"
  [ -f "$APK_SRC" ] || { err "APK não gerado em $APK_SRC"; exit 1; }
  cp "$APK_SRC" sms-sender.apk
  cp "$APK_SRC" web/public/sms-sender.apk
  ok "APK pronto ($(du -h sms-sender.apk | cut -f1)) — copiado pra raiz e web/public/"
else
  log "SKIP_APK=1 — pulando build do APK"
  [ -f sms-sender.apk ] && cp sms-sender.apk web/public/sms-sender.apk && ok "APK existente copiado pro web/public/" || true
fi

# ------------------------------------------------------------------ infra up
log "Subindo a infra (docker compose up -d --build)"
docker compose up -d --build

# ------------------------------------------------------------------ health
log "Aguardando serviços responderem"
wait_http() {
  local url="$1" name="$2" tries=90 code
  for _ in $(seq 1 "$tries"); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000)"
    [ "$code" != "000" ] && { ok "$name (HTTP $code)"; return 0; }
    sleep 2
  done
  err "$name não respondeu a tempo ($url)"; return 0
}
wait_http "http://localhost:3001/"                "API  :3001"
wait_http "http://localhost:3000/"                "Web  :3000"
wait_http "http://localhost:3000/sms-sender.apk"  "APK  :3000/sms-sender.apk"

# ------------------------------------------------------------------ status
log "Status dos containers"
docker compose ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'

printf "\n    Firebase: "
if docker compose logs textbee-api --since 5m 2>/dev/null | grep -qi "Firebase initialized"; then
  printf "\033[1;32mATIVO (push ligado)\033[0m\n"
elif docker compose logs textbee-api --since 5m 2>/dev/null | grep -qi "skipping firebase"; then
  printf "\033[1;33mDESLIGADO (FIREBASE_* vazio em api/.env)\033[0m\n"
else
  printf "?\n"
fi

cat <<EOF

Pronto! ✅  Aponte seu túnel/proxy assim:
  Dashboard: ${WEB_URL}        → porta 3000
  API:       ${API_BASE_URL}   → porta 3001

  Local:  Dashboard http://localhost:3000   |   API http://localhost:3001
  APK:    http://localhost:3000/sms-sender.apk   (defina API_BASE_URL/WEB_URL no .env)
EOF
