#!/usr/bin/env bash
set -euo pipefail

SONAR_HOST_URL="${SONAR_HOST_URL:-http://localhost:9000}"
ADMIN_USER="admin"
DEFAULT_PASSWORD="admin"
CI_PASSWORD="${SONAR_CI_ADMIN_PASSWORD:-CiOnly-NotASecret-2024}"
GATE_NAME="workshop-gate"

echo "Detectando credenciales de admin (¿instancia nueva o snapshot restaurado?)..."
if curl -s -u "${ADMIN_USER}:${CI_PASSWORD}" "${SONAR_HOST_URL}/api/authentication/validate" | grep -q '"valid":true'; then
  echo "Snapshot restaurado: la contraseña de CI ya estaba configurada."
  AUTH="${ADMIN_USER}:${CI_PASSWORD}"
else
  echo "Instancia nueva: cambiando la contraseña por defecto de admin..."
  curl -s -u "${ADMIN_USER}:${DEFAULT_PASSWORD}" -X POST "${SONAR_HOST_URL}/api/users/change_password" \
    --data-urlencode "login=${ADMIN_USER}" \
    --data-urlencode "previousPassword=${DEFAULT_PASSWORD}" \
    --data-urlencode "password=${CI_PASSWORD}" > /dev/null
  AUTH="${ADMIN_USER}:${CI_PASSWORD}"
fi

echo "Generando token de análisis para este run..."
TOKEN_RESPONSE="$(curl -s -u "${AUTH}" -X POST "${SONAR_HOST_URL}/api/user_tokens/generate" \
  --data-urlencode "name=ci-token-${GITHUB_RUN_ID:-local}-$(date +%s)")"
TOKEN="$(echo "$TOKEN_RESPONSE" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)"

if [ -z "$TOKEN" ]; then
  echo "No se pudo generar el token: $TOKEN_RESPONSE"
  exit 1
fi
echo "::add-mask::${TOKEN}"

echo "Verificando Quality Gate '${GATE_NAME}'..."
EXISTING="$(curl -s -u "${AUTH}" "${SONAR_HOST_URL}/api/qualitygates/list" | grep -o "\"name\":\"${GATE_NAME}\"" || true)"

if [ -z "$EXISTING" ]; then
  echo "No existe todavía: creando Quality Gate '${GATE_NAME}'..."
  curl -s -u "${AUTH}" -X POST "${SONAR_HOST_URL}/api/qualitygates/create" \
    --data-urlencode "name=${GATE_NAME}" > /dev/null

  add_condition() {
    local metric="$1" op="$2" error="$3"
    curl -s -u "${AUTH}" -X POST "${SONAR_HOST_URL}/api/qualitygates/create_condition" \
      --data-urlencode "gateName=${GATE_NAME}" \
      --data-urlencode "metric=${metric}" \
      --data-urlencode "op=${op}" \
      --data-urlencode "error=${error}" > /dev/null
  }

  add_condition "code_smells" "GT" "10"
  add_condition "coverage" "LT" "95"
  add_condition "duplicated_lines_density" "GT" "2"
  add_condition "vulnerabilities" "GT" "0"
  add_condition "security_hotspots_reviewed" "LT" "100"
  add_condition "reliability_rating" "GT" "1"
  add_condition "security_rating" "GT" "1"
  add_condition "sqale_rating" "GT" "1"

  curl -s -u "${AUTH}" -X POST "${SONAR_HOST_URL}/api/qualitygates/set_as_default" \
    --data-urlencode "name=${GATE_NAME}" > /dev/null

  echo "Quality Gate '${GATE_NAME}' creado y marcado como default."
else
  echo "Quality Gate '${GATE_NAME}' ya existe (viene del snapshot restaurado); no se reconfigura."
fi

echo "token=${TOKEN}" >> "$GITHUB_OUTPUT"
