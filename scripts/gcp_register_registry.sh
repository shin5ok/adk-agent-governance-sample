#!/usr/bin/env bash
# Cloud Run など Runtime 外のエージェントを Agent Registry に手動登録する。
# 前提: エージェントが $AGENT_BASE_URL で稼働し、カードを返せること。
set -euo pipefail
: "${GOOGLE_CLOUD_PROJECT:?}" "${AGENT_BASE_URL:?例 https://policy-agent-xxxx.a.run.app}"
LOCATION="${GOOGLE_CLOUD_LOCATION:-us-central1}"
NAME="${SERVICE_NAME:-policy-agent}"

# 生きているカードを取ってくる（自分で書かない）
curl -sf "${AGENT_BASE_URL}/.well-known/agent-card.json" > /tmp/agent-card.json
echo "card fetched ($(wc -c < /tmp/agent-card.json) bytes; 上限 10KB)"

gcloud agent-registry services create "$NAME" \
  --project="$GOOGLE_CLOUD_PROJECT" --location="$LOCATION" \
  --display-name="$NAME" \
  --agent-spec-type=a2a-agent-card \
  --agent-spec-content=@/tmp/agent-card.json
