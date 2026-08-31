#!/usr/bin/env bash
# Agent Gateway（egress）+ IAP 認可を作成
set -euo pipefail
: "${GOOGLE_CLOUD_PROJECT:?}"
LOCATION="${GOOGLE_CLOUD_LOCATION:-us-central1}"
TMP=$(mktemp -d)

for f in agent-gateway-egress iap-authz-extension iap-authz-policy; do
  sed -e "s/PROJECT_ID/${GOOGLE_CLOUD_PROJECT}/g" -e "s/REGION/${LOCATION}/g" \
    "deploy/${f}.yaml" > "${TMP}/${f}.yaml"
done

gcloud network-services agent-gateways import expense-gw \
  --source="${TMP}/agent-gateway-egress.yaml" --location="$LOCATION"

gcloud beta service-extensions authz-extensions import expense-gw-authz-ext \
  --source="${TMP}/iap-authz-extension.yaml" --location="$LOCATION"

gcloud network-security authz-policies import expense-gw-authz-policy \
  --source="${TMP}/iap-authz-policy.yaml" --location="$LOCATION"

echo "gateway: projects/${GOOGLE_CLOUD_PROJECT}/locations/${LOCATION}/agentGateways/expense-gw"
