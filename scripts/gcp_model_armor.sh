#!/usr/bin/env bash
# Model Armor テンプレート作成 + ゲートウェイ用 SA へのロール付与
set -euo pipefail
: "${GOOGLE_CLOUD_PROJECT:?}"
LOCATION="${GOOGLE_CLOUD_LOCATION:-us-central1}"
PROJECT_NUMBER="$(gcloud projects describe "$GOOGLE_CLOUD_PROJECT" --format='value(projectNumber)')"

# ゲートウェイと同じリージョンに作ること
gcloud model-armor templates create ma-egress \
  --location="$LOCATION" \
  --pi-and-jailbreak-filter-settings-enforcement=enabled \
  --pi-and-jailbreak-filter-settings-confidence-level=medium-and-above \
  --malicious-uri-filter-settings-enforcement=enabled

# Service Extensions の SA に検査呼び出し権限
SA="service-${PROJECT_NUMBER}@gcp-sa-dep.iam.gserviceaccount.com"
for ROLE in roles/modelarmor.calloutUser roles/serviceusage.serviceUsageConsumer roles/modelarmor.user; do
  gcloud projects add-iam-policy-binding "$GOOGLE_CLOUD_PROJECT" \
    --member="serviceAccount:${SA}" --role="$ROLE" --quiet
done
echo "template: projects/${GOOGLE_CLOUD_PROJECT}/locations/${LOCATION}/templates/ma-egress"
echo "運用: まず INSPECT_ONLY / DRY_RUN で観察し、ログ確認後に遮断へ。"
