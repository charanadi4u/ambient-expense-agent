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

set -euo pipefail

# ---------------------------------------------------------------------------
# Shell teardown script replacing Terraform destroy for Ambient Expense Agent.
# ---------------------------------------------------------------------------

PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")
REGION=${REGION:-us-central1}
BACKEND_SERVICE=${BACKEND_SERVICE:-ambient-expense-agent}
FRONTEND_SERVICE=${FRONTEND_SERVICE:-expense-approval-ui}
NOTIFICATION_EMAIL=${NOTIFICATION_EMAIL:-vicky.swain@gmail.com}

if [ -z "${PROJECT_ID}" ]; then
  echo "Error: PROJECT_ID is not set."
  echo "Run: gcloud config set project <your-project-id>"
  exit 1
fi

PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')

echo "==> [1/6] Deleting Monitoring Policies & Channels..."
# Delete Alert Policy
POLICY_NAME=$(gcloud monitoring policies list \
  --project="${PROJECT_ID}" \
  --filter="displayName='Expense Agent - High-Value Expense Review'" \
  --format="value(name)" | head -n 1)

if [ -n "${POLICY_NAME}" ]; then
  gcloud monitoring policies delete "${POLICY_NAME}" --project="${PROJECT_ID}" --quiet || true
fi

CHANNEL_NAME=$(gcloud beta monitoring channels list --project="${PROJECT_ID}" --format="json" | python -c "import sys, json; print(next((x['name'] for x in json.load(sys.stdin) if x.get('displayName') == 'Expense Agent - Review Alerts'), ''))")

if [ -n "${CHANNEL_NAME}" ]; then
  gcloud beta monitoring channels delete "${CHANNEL_NAME}" --project="${PROJECT_ID}" --quiet || true
fi

# Delete Log-Based Metric
if gcloud logging metrics describe expense-review-alerts --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud logging metrics delete expense-review-alerts --project="${PROJECT_ID}" --quiet || true
fi

echo "==> [2/6] Deleting Pub/Sub Subscriptions & Topics..."
# Delete push subscription
if gcloud pubsub subscriptions describe expense-reports-push --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud pubsub subscriptions delete expense-reports-push --project="${PROJECT_ID}" --quiet || true
fi

# Delete topics
for TOPIC in expense-reports expense-reports-dead-letter; do
  if gcloud pubsub topics describe "${TOPIC}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud pubsub topics create "${TOPIC}" --project="${PROJECT_ID}" --quiet >/dev/null 2>&1 || true # Fallback/Check
    gcloud pubsub topics delete "${TOPIC}" --project="${PROJECT_ID}" --quiet || true
  fi
done

echo "==> [3/6] Deleting Cloud Run Services..."
for SERVICE in "${FRONTEND_SERVICE}" "${BACKEND_SERVICE}"; do
  if gcloud run services describe "${SERVICE}" --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud run services delete "${SERVICE}" --region="${REGION}" --project="${PROJECT_ID}" --quiet || true
  fi
done

echo "==> [4/6] Deleting Service Accounts..."
for SA in expense-agent-invoker approval-ui-invoker; do
  if gcloud iam service-accounts describe "${SA}@${PROJECT_ID}.iam.gserviceaccount.com" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud iam service-accounts delete "${SA}@${PROJECT_ID}.iam.gserviceaccount.com" --project="${PROJECT_ID}" --quiet || true
  fi
done

echo "==> [5/6] Cleaning up project-level IAM bindings..."
gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/aiplatform.user" \
  --quiet >/dev/null || true

gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/artifactregistry.writer" \
  --quiet >/dev/null || true

gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/storage.objectViewer" \
  --quiet >/dev/null || true

echo "==> [6/6] Cleanup complete!"
