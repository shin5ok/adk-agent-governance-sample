#!/usr/bin/env bash
# Agent Identity（principal://）に権限を付ける。エージェント1体につき1回流す。
# 使い方: AGENT_ENGINE_ID=xxxx ./scripts/gcp_grant_iam.sh
#
# 対象は Agent Runtime に載る3体（receipt / policy / orchestrator）だけ。
# fx-agent は Cloud Run なので Agent Identity を持たず、ここには出てこない。
# 実行 ID は Cloud Run のサービスアカウントで、呼ばれる側としての保護は
# 下の run.invoker（呼ぶ側の principal:// に付ける）で行う。
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

# 別ランタイム（Cloud Run）の fx-agent を呼ぶ許可。
# agents-cli deploy は Cloud Run へ --no-allow-unauthenticated で出すので、
# 呼ぶ側（オーケストレータ）の principal:// に run.invoker が要る。
# オーケストレータの AGENT_ENGINE_ID で流すときだけ設定する。
if [[ -n "${FX_SERVICE_NAME:-}" ]]; then
  gcloud run services add-iam-policy-binding "$FX_SERVICE_NAME" \
    --region="$LOCATION" --project="$GOOGLE_CLOUD_PROJECT" \
    --member="$AGENT_PRINCIPAL" --role="roles/run.invoker" --quiet
fi
