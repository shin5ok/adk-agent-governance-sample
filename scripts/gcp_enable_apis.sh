#!/usr/bin/env bash
# Agent Identity / Registry / Gateway / Model Armor に必要な API を有効化
set -euo pipefail
: "${GOOGLE_CLOUD_PROJECT:?set GOOGLE_CLOUD_PROJECT}"

gcloud services enable \
  aiplatform.googleapis.com \
  agentregistry.googleapis.com \
  agentidentitycredentials.googleapis.com \
  networkservices.googleapis.com \
  networksecurity.googleapis.com \
  modelarmor.googleapis.com \
  compute.googleapis.com \
  iam.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  --project "$GOOGLE_CLOUD_PROJECT"
