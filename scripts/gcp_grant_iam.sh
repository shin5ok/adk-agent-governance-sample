#!/usr/bin/env bash
# Agent Identity（principal://）に権限を付ける。
# 使い方: AGENT_ENGINE_ID=xxxx ./scripts/gcp_grant_iam.sh
set -euo pipefail
: "${GOOGLE_CLOUD_PROJECT:?}" "${ORG_ID:?set ORG_ID (組織ID)}" "${AGENT_ENGINE_ID:?}"
LOCATION="${GOOGLE_CLOUD_LOCATION:-us-central1}"
PROJECT_NUMBER="$(gcloud projects describe "$GOOGLE_CLOUD_PROJECT" --format='value(projectNumber)')"

AGENT_PRINCIPAL="principal://agents.global.org-${ORG_ID}.system.id.goog/resources/aiplatform/projects/${PROJECT_NUMBER}/locations/${LOCATION}/reasoningEngines/${AGENT_ENGINE_ID}"
echo "principal: $AGENT_PRINCIPAL"

# 共通の下地（推論・セッション・メモリ）
gcloud projects add-iam-policy-binding "$GOOGLE_CLOUD_PROJECT" \
  --member="$AGENT_PRINCIPAL" --role="roles/aiplatform.expressUser" --quiet

# データアクセスは個体に狭く（例: 領収書バケット。必要なものだけ残す）
if [[ -n "${RECEIPTS_BUCKET:-}" ]]; then
  gcloud storage buckets add-iam-policy-binding "gs://${RECEIPTS_BUCKET}" \
    --member="$AGENT_PRINCIPAL" --role="roles/storage.objectViewer" --quiet
fi

# ゲートウェイ通行許可（egress）
gcloud projects add-iam-policy-binding "$GOOGLE_CLOUD_PROJECT" \
  --member="$AGENT_PRINCIPAL" --role="roles/iap.egressor" --quiet
