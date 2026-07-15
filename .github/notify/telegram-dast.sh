#!/usr/bin/env bash
set -euo pipefail

REPORT="${REPORT:-report_json.json}"
ZAP_TARGET="${ZAP_TARGET:-http://localhost:3000}"
MAX_HIGH="${MAX_HIGH:-0}"

missing=""
[ -z "${TELEGRAM_BOT_TOKEN:-}" ] && missing="${missing} TELEGRAM_BOT_TOKEN"
[ -z "${TELEGRAM_CHAT_ID:-}" ]   && missing="${missing} TELEGRAM_CHAT_ID"
if [ -n "$missing" ]; then
  echo "::error::Falta(n) el/los secret(s):${missing}. La notificación a Telegram es obligatoria; configúralo(s) en Settings → Secrets and variables → Actions."
  exit 1
fi

notes=()

esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

count_risk() {
  jq --arg r "$1" '[.site[]?.alerts[]? | select(.riskcode==$r)] | length' "$REPORT" 2>/dev/null || echo 0
}

high=0; medium=0; low=0; info=0
if [ -f "$REPORT" ]; then
  high="$(count_risk 3)"
  medium="$(count_risk 2)"
  low="$(count_risk 1)"
  info="$(count_risk 0)"
else
  notes+=("No se encontró ${REPORT}: el escaneo DAST no se ejecutó o no llegó a completarse.")
fi

if [ "${ZAP_OUTCOME:-}" = "failure" ]; then
  notes+=("La acción de ZAP terminó en error; el objetivo pudo no estar accesible.")
fi

# Mismo criterio que el gate del workflow: solo el riesgo ALTO reprueba.
if [ ! -f "$REPORT" ] || [ "${ZAP_OUTCOME:-}" = "failure" ]; then
  gate_emoji="❔"; gate_text="DESCONOCIDO"
elif [ "${high:-0}" -gt "${MAX_HIGH}" ]; then
  gate_emoji="❌"; gate_text="FAILED"
else
  gate_emoji="✅"; gate_text="PASSED"
fi

# Top de alertas por riesgo, para no mandar el reporte entero al chat.
top_block=""
if [ -f "$REPORT" ]; then
  top="$(jq -r '
    def etiqueta: {"3":"🔴","2":"🟠","1":"🟡","0":"🔵"}[.riskcode] // "•";
    [.site[]?.alerts[]? | select(.riskcode=="3" or .riskcode=="2")]
    | sort_by(.riskcode) | reverse | .[:5][]
    | "\(etiqueta) \(.name) (\(.instances | length))"
  ' "$REPORT" 2>/dev/null || true)"
  if [ -n "$top" ]; then
    top_block=$'\n\n🚨 <b>Alertas más relevantes</b>'
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      top_block="${top_block}"$'\n'"• $(printf '%s' "$line" | esc)"
    done <<< "$top"
  fi
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
🛡️ <b>DAST — OWASP ZAP Baseline</b>
Resultado: ${gate_emoji} <b>${gate_text}</b> (umbral: máx. ${MAX_HIGH} de riesgo alto)
$(printf '%s' "$ctx" | esc) · <code>${short_sha}</code>
Objetivo: <code>$(printf '%s' "$ZAP_TARGET" | esc)</code>

📊 <b>Alertas por riesgo</b>
• 🔴 Altas: ${high}
• 🟠 Medias: ${medium}
• 🟡 Bajas: ${low}
• 🔵 Informativas: ${info}${top_block}

🔗 <a href="${RUN_URL:-}">Ver ejecución en GitHub Actions</a>
📄 <a href="${RUN_URL:-}#summary">Ver resumen del job (tabla de alertas)</a>${notes_block}
EOF
)"

send() {
  curl -s -o /tmp/tg_dast_resp.json -w '%{http_code}' \
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
  echo "::warning::Intento ${attempt}/3 de enviar a Telegram falló (HTTP ${http_code}): $(cat /tmp/tg_dast_resp.json 2>/dev/null || true)"
  sleep 3
done

if [ "$http_code" != "200" ]; then
  echo "::error::No se pudo enviar la notificación a Telegram tras 3 intentos (HTTP ${http_code}). La notificación es obligatoria, por lo que el job falla."
  exit 1
fi
echo "Notificación DAST enviada a Telegram."
