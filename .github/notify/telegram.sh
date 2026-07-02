#!/usr/bin/env bash
set -euo pipefail

SONAR_HOST_URL="${SONAR_HOST_URL:-http://localhost:9000}"

missing=""
[ -z "${TELEGRAM_BOT_TOKEN:-}" ] && missing="${missing} TELEGRAM_BOT_TOKEN"
[ -z "${TELEGRAM_CHAT_ID:-}" ]   && missing="${missing} TELEGRAM_CHAT_ID"
if [ -n "$missing" ]; then
  echo "::error::Falta(n) el/los secret(s):${missing}. La notificación a Telegram es obligatoria; configúralo(s) en Settings → Secrets and variables → Actions."
  exit 1
fi

PROJECT_KEY="$(grep '^sonar.projectKey=' sonar-project.properties | cut -d'=' -f2)"

notes=()

esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

measures=""
gate_status="UNKNOWN"
if [ -z "${SONAR_TOKEN:-}" ]; then
  notes+=("No se recibió SONAR_TOKEN: no se pudieron leer las métricas de SonarQube.")
else
  METRICS="bugs,vulnerabilities,code_smells,security_hotspots,coverage,duplicated_lines_density,ncloc"
  measures="$(curl -sf -u "${SONAR_TOKEN}:" \
    "${SONAR_HOST_URL}/api/measures/component?component=${PROJECT_KEY}&metricKeys=${METRICS}" || true)"
  gate="$(curl -sf -u "${SONAR_TOKEN}:" \
    "${SONAR_HOST_URL}/api/qualitygates/project_status?projectKey=${PROJECT_KEY}" || true)"
  gate_status="$(echo "$gate" | jq -r '.projectStatus.status // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")"

  [ -z "$measures" ] && notes+=("No se pudo consultar la API de SonarQube (¿análisis fallido o instancia caída?); las métricas van incompletas.")
  [ "$gate_status" = "UNKNOWN" ] && notes+=("Estado del Quality Gate desconocido; el análisis pudo no completarse.")
fi

metric() {
  local v
  v="$(echo "$measures" | jq -r --arg k "$1" \
    '.component.measures[]? | select(.metric==$k) | (.value // empty)' 2>/dev/null || true)"
  if [ -n "$v" ]; then echo "$v"; else echo "-"; fi
}

if [ "$gate_status" = "OK" ]; then
  gate_emoji="✅"; gate_text="PASSED"
elif [ "$gate_status" = "UNKNOWN" ]; then
  gate_emoji="❔"; gate_text="DESCONOCIDO"
else
  gate_emoji="❌"; gate_text="${gate_status}"
fi

crit=0; high=0
if [ -f trivy-deps.json ]; then
  crit="$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' trivy-deps.json 2>/dev/null || echo 0)"
  high="$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")]     | length' trivy-deps.json 2>/dev/null || echo 0)"
else
  notes+=("No se encontró trivy-deps.json: el escaneo de dependencias no se ejecutó o falló.")
fi

if [ "$crit" -gt 0 ]; then
  trivy_emoji="❌"  
elif [ "$high" -gt 0 ]; then
  trivy_emoji="⚠️"
else
  trivy_emoji="✅"
fi

if [ "${EVENT_NAME:-}" = "pull_request" ] && [ -n "${PR_NUMBER:-}" ]; then
  ctx="PR #${PR_NUMBER} → ${BRANCH:-?}"
else
  ctx="push → ${BRANCH:-?}"
fi
short_sha="${COMMIT_SHA:0:7}"

notes_block=""
if [ "${#notes[@]}" -gt 0 ]; then
  notes_block=$'\n\n⚠️ <b>Avisos</b>'
  for n in "${notes[@]}"; do
    notes_block="${notes_block}"$'\n'"• $(printf '%s' "$n" | esc)"
  done
fi

MSG="$(cat <<EOF
🔎 <b>SonarQube — $(printf '%s' "$PROJECT_KEY" | esc)</b>
Quality Gate: ${gate_emoji} <b>${gate_text}</b>
$(printf '%s' "$ctx" | esc) · <code>${short_sha}</code>

📊 <b>Métricas del proyecto</b>
• Bugs: $(metric bugs)
• Vulnerabilidades: $(metric vulnerabilities)
• Code smells: $(metric code_smells)
• Security hotspots: $(metric security_hotspots)
• Cobertura: $(metric coverage)%
• Duplicación: $(metric duplicated_lines_density)%
• Líneas (ncloc): $(metric ncloc)

${trivy_emoji} <b>Trivy — dependencias (HIGH/CRITICAL)</b>
• CRITICAL: ${crit}
• HIGH: ${high}

🔗 <a href="${RUN_URL:-}">Ver ejecución en GitHub Actions</a>${notes_block}
EOF
)"

send() {
  curl -s -o /tmp/tg_resp.json -w '%{http_code}' \
    -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${MSG}" \
    -d "parse_mode=HTML" \
    -d "disable_web_page_preview=true" || echo "000"
}

http_code=""
for attempt in 1 2 3; do
  http_code="$(send)"
  [ "$http_code" = "200" ] && break
  echo "::warning::Intento ${attempt}/3 de enviar a Telegram falló (HTTP ${http_code}): $(cat /tmp/tg_resp.json 2>/dev/null || true)"
  sleep 3
done

if [ "$http_code" != "200" ]; then
  echo "::error::No se pudo enviar la notificación a Telegram tras 3 intentos (HTTP ${http_code}). La notificación es obligatoria, por lo que el job falla."
  exit 1
fi
echo "Notificación enviada a Telegram."
