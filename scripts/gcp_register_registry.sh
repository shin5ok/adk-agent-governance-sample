#!/usr/bin/env bash
# Agent Runtime の外にいるエージェント（このリポジトリでは Cloud Run の fx-agent）を
# Agent Registry に手動登録する。
#
# Agent Runtime にデプロイした3体は deploy が Registry の面倒を見るが、
# Cloud Run のものは対象外なので、ここで名簿に載せる。載せておかないと
# USE_AGENT_REGISTRY=1 のオーケストレータから名前で解決できない。
#
# 使い方: AGENT_BASE_URL=https://fx-agent-xxxx.us-central1.run.app ./scripts/gcp_register_registry.sh
set -euo pipefail
: "${GOOGLE_CLOUD_PROJECT:?}" "${AGENT_BASE_URL:?例 https://fx-agent-xxxx.us-central1.run.app}"
LOCATION="${GOOGLE_CLOUD_LOCATION:-us-central1}"
NAME="${SERVICE_NAME:-fx-agent}"
CARD="$(mktemp)"
trap 'rm -f "$CARD"' EXIT

# カードのパスは Agent Runtime 側と同じ /a2a/{App.name}/.well-known/agent-card.json。
# ランタイムが変わってもここは変わらない（App.name は "app" 固定）。
# agents-cli deploy は Cloud Run へ --no-allow-unauthenticated で出すので、
# カードの取得にも ID トークンが要る。
curl -sf -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
  "${AGENT_BASE_URL}/a2a/app/.well-known/agent-card.json" > "$CARD"
echo "card fetched ($(wc -c < "$CARD") bytes; 上限 10KB)"

gcloud agent-registry services create "$NAME" \
  --project="$GOOGLE_CLOUD_PROJECT" --location="$LOCATION" \
  --display-name="$NAME" \
  --agent-spec-type=a2a-agent-card \
  --agent-spec-content=@"$CARD"
