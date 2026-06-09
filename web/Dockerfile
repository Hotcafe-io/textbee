# syntax=docker/dockerfile:1
# Contexto de build = RAIZ do repo (ver docker-compose: build.context = .)
# Builda o APK Android num estagio e o serve em /sms-sender.apk pelo Next.

# ============================ Stage 0: APK (Android) ============================
FROM eclipse-temurin:11-jdk AS apk-builder
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV PATH="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${PATH}"

RUN apt-get update \
 && apt-get install -y --no-install-recommends unzip curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# cmdline-tools 8512546 roda em Java 11 (versoes novas exigem Java 17+)
RUN set -eux; \
    mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools"; \
    curl -fsSL -o /tmp/cmd.zip https://dl.google.com/android/repository/commandlinetools-linux-8512546_latest.zip; \
    unzip -q /tmp/cmd.zip -d "$ANDROID_SDK_ROOT/cmdline-tools"; \
    mv "$ANDROID_SDK_ROOT/cmdline-tools/cmdline-tools" "$ANDROID_SDK_ROOT/cmdline-tools/latest"; \
    rm /tmp/cmd.zip; \
    yes | sdkmanager --licenses >/dev/null 2>&1 || true; \
    sdkmanager "platform-tools" "platforms;android-32" "build-tools;32.0.0" >/dev/null

WORKDIR /build
COPY android/ ./android/

# URL da API embutida no APK + (opcional) google-services.json em base64.
# Local: o arquivo ja vem no contexto. Dokploy/CI: passe GOOGLE_SERVICES_JSON_B64.
ARG API_BASE_URL=https://api.example.com/api/v1/
ARG GOOGLE_SERVICES_JSON_B64=
ENV API_BASE_URL=${API_BASE_URL}

RUN set -eux; \
    if [ -n "$GOOGLE_SERVICES_JSON_B64" ]; then \
      echo "$GOOGLE_SERVICES_JSON_B64" | base64 -d > android/app/google-services.json; \
    fi; \
    test -f android/app/google-services.json || { \
      echo "ERRO: android/app/google-services.json ausente. Defina GOOGLE_SERVICES_JSON_B64 (base64) no build."; exit 1; }; \
    mkdir -p /root/.android; \
    keytool -genkeypair -v -keystore /root/.android/debug.keystore -storepass android \
      -alias androiddebugkey -keypass android -keyalg RSA -keysize 2048 -validity 10000 \
      -dname "CN=Android Debug,O=Android,C=US"

RUN --mount=type=cache,target=/root/.gradle \
    cd android && chmod +x gradlew && ./gradlew assembleProdRelease --no-daemon
RUN cp android/app/build/outputs/apk/prod/release/app-prod-release.apk /sms-sender.apk

# ============================ Stage 1: deps ============================
FROM node:22-alpine AS deps
WORKDIR /app
RUN apk add --no-cache openssl openssl-dev && npm install -g pnpm@9
COPY web/package.json web/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

# ============================ Stage 2: builder ============================
FROM node:22-alpine AS builder
WORKDIR /app
RUN apk add --no-cache openssl openssl-dev && npm install -g pnpm@9
COPY --from=deps /app/node_modules ./node_modules
COPY web/ ./
ENV NEXT_TELEMETRY_DISABLED=1
# NEXT_PUBLIC_* sao fixados em build-time (Next inlina no bundle)
ARG NEXT_PUBLIC_API_BASE_URL=http://localhost:3001/api/v1
ARG NEXT_PUBLIC_SITE_URL=http://localhost:3000
ARG NEXT_PUBLIC_APK_DOWNLOAD_URL=
ENV NEXT_PUBLIC_API_BASE_URL=${NEXT_PUBLIC_API_BASE_URL}
ENV NEXT_PUBLIC_SITE_URL=${NEXT_PUBLIC_SITE_URL}
ENV NEXT_PUBLIC_APK_DOWNLOAD_URL=${NEXT_PUBLIC_APK_DOWNLOAD_URL}
RUN pnpm build

# ============================ Stage 3: runner ============================
FROM node:22-alpine AS runner
WORKDIR /app
RUN apk add --no-cache openssl openssl-dev && npm install -g pnpm@9
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV CONTAINER_RUNTIME=docker

RUN addgroup --system --gid 1001 nodejs \
 && adduser --system --uid 1001 nextjs \
 && chown -R nextjs:nodejs /app

COPY --from=builder --chown=nextjs:nodejs /app/next.config.js ./
COPY --from=builder --chown=nextjs:nodejs /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static
COPY --from=builder --chown=nextjs:nodejs /app/package.json ./
COPY --from=builder --chown=nextjs:nodejs /app/pnpm-lock.yaml ./

# APK buildado entra no public -> servido em /sms-sender.apk
COPY --from=apk-builder --chown=nextjs:nodejs /sms-sender.apk ./public/sms-sender.apk

RUN pnpm install --prod --frozen-lockfile

USER nextjs
ENV PORT=3000
EXPOSE ${PORT}
CMD ["node", "server"]
