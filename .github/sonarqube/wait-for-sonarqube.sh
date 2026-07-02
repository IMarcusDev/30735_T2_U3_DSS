#!/usr/bin/env bash
set -euo pipefail

SONAR_HOST_URL="${SONAR_HOST_URL:-http://localhost:9000}"

echo "Esperando a que SonarQube esté disponible en ${SONAR_HOST_URL}..."
for i in $(seq 1 60); do
  response="$(curl -s "${SONAR_HOST_URL}/api/system/status" || true)"
  status="$(echo "$response" | grep -o '"status":"[A-Z]*"' | cut -d'"' -f4 || true)"

  if [ "$status" = "UP" ]; then
    echo "SonarQube está listo (intento $i)."
    exit 0
  fi

  if [ "$status" = "DB_MIGRATION_NEEDED" ] || [ "$status" = "DB_MIGRATION_RUNNING" ]; then
    echo "Intento $i/60: aplicando migraciones del snapshot restaurado (${status})..."
  else
    echo "Intento $i/60: estado actual '${status:-sin respuesta}', esperando 5s..."
  fi
  sleep 5
done

echo "SonarQube no llegó a estado UP a tiempo."
docker logs sonarqube || true
exit 1
