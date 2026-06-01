#!/usr/bin/env bash
#
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -uo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")
REGION=${REGION:-us-central1}
BACKEND_SERVICE=${BACKEND_SERVICE:-ambient-expense-agent}
FRONTEND_SERVICE=${FRONTEND_SERVICE:-expense-approval-ui}
ALERT_POLICY_NAME="Expense Agent - High-Value Expense Review"
NOTIFICATION_CHANNEL_NAME="Expense Agent - Review Alerts"

if [ -z "${PROJECT_ID}" ]; then
  echo -e "${RED}Error: PROJECT_ID is not set in gcloud config.${NC}"
  echo "Run: gcloud config set project <your-project-id>"
  exit 1
fi

echo "Checking resources for Project: ${PROJECT_ID} in Region: ${REGION}..."
echo "------------------------------------------------------------"

all_passed=true

check_status() {
  local name=$1
  local status=$2
  if [ "${status}" = "0" ]; then
    echo -e "  [${GREEN} OK ${NC}] ${name}"
  else
    echo -e "  [${RED}FAIL${NC}] ${name}"
    all_passed=false
  fi
}

# 1. Check APIs
echo "1. Checking Enabled APIs..."
for API in aiplatform.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com iap.googleapis.com monitoring.googleapis.com pubsub.googleapis.com run.googleapis.com; do
  gcloud services list --enabled --filter="config.name:${API}" --project="${PROJECT_ID}" --format="value(config.name)" | grep -q "${API}"
  check_status "${API}" $?
done

# 2. Check Artifact Registry
echo "2. Checking Artifact Registry..."
gcloud artifacts repositories describe expense-agent --location="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1
check_status "Repository: expense-agent" $?

# 3. Check Service Accounts
echo "3. Checking Service Accounts..."
for SA in expense-agent-invoker approval-ui-invoker; do
  gcloud iam service-accounts describe "${SA}@${PROJECT_ID}.iam.gserviceaccount.com" --project="${PROJECT_ID}" >/dev/null 2>&1
  check_status "Service Account: ${SA}" $?
done

# 4. Check Cloud Run Services
echo "4. Checking Cloud Run Services..."
gcloud run services describe "${BACKEND_SERVICE}" --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1
check_status "Backend Service: ${BACKEND_SERVICE}" $?

gcloud run services describe "${FRONTEND_SERVICE}" --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1
check_status "Frontend Service: ${FRONTEND_SERVICE}" $?

# 5. Check Pub/Sub Topics & Subscription
echo "5. Checking Pub/Sub Resources..."
for TOPIC in expense-reports expense-reports-dead-letter; do
  gcloud pubsub topics describe "${TOPIC}" --project="${PROJECT_ID}" >/dev/null 2>&1
  check_status "Topic: ${TOPIC}" $?
done

gcloud pubsub subscriptions describe expense-reports-push --project="${PROJECT_ID}" >/dev/null 2>&1
check_status "Subscription: expense-reports-push" $?

# 6. Check Logging Metrics & Monitoring
echo "6. Checking Monitoring & Alerting..."
gcloud logging metrics describe expense-review-alerts --project="${PROJECT_ID}" >/dev/null 2>&1
check_status "Log Metric: expense-review-alerts" $?

# Check Notification Channel
CHANNEL_NAME=$(gcloud beta monitoring channels list --project="${PROJECT_ID}" --format="json" | python -c "import sys, json; print(next((x['name'] for x in json.load(sys.stdin) if x.get('displayName') == '${NOTIFICATION_CHANNEL_NAME}'), ''))" 2>/dev/null)
if [ -n "${CHANNEL_NAME}" ]; then
  check_status "Notification Channel: ${NOTIFICATION_CHANNEL_NAME}" 0
else
  check_status "Notification Channel: ${NOTIFICATION_CHANNEL_NAME}" 1
fi

# Check Alert Policy
POLICY_NAME=$(gcloud monitoring policies list --project="${PROJECT_ID}" --filter="displayName='${ALERT_POLICY_NAME}'" --format="value(name)" 2>/dev/null | head -n 1)
if [ -n "${POLICY_NAME}" ]; then
  check_status "Alert Policy: ${ALERT_POLICY_NAME}" 0
else
  check_status "Alert Policy: ${ALERT_POLICY_NAME}" 1
fi

echo "------------------------------------------------------------"
if [ "${all_passed}" = true ]; then
  echo -e "${GREEN}All resources have been created successfully!${NC}"
else
  echo -e "${RED}Some resources are missing or misconfigured. Please run deploy.sh again.${NC}"
fi
