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
# Shell deployment script replacing Terraform for Ambient Expense Agent.
# ---------------------------------------------------------------------------

PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")
REGION=${REGION:-us-central1}
BACKEND_SERVICE=${BACKEND_SERVICE:-ambient-expense-agent}
FRONTEND_SERVICE=${FRONTEND_SERVICE:-expense-approval-ui}
AGENT_NAME=${AGENT_NAME:-expense_agent}
NOTIFICATION_EMAIL=${NOTIFICATION_EMAIL:-vicky.swain@gmail.com}

if [ -z "${PROJECT_ID}" ]; then
  echo "Error: PROJECT_ID is not set."
  echo "Run: gcloud config set project <your-project-id>"
  exit 1
fi

if [ "${NOTIFICATION_EMAIL}" = "your-email@example.com" ]; then
  echo "Error: Please set a valid NOTIFICATION_EMAIL."
  echo "Usage: export NOTIFICATION_EMAIL=you@example.com && ./scripts/deploy.sh"
  exit 1
fi

REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/expense-agent"
BACKEND_IMAGE="${REGISTRY}/backend"
FRONTEND_IMAGE="${REGISTRY}/frontend"

echo "==> [1/9] Enabling required APIs..."
gcloud services enable \
  aiplatform.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  iap.googleapis.com \
  monitoring.googleapis.com \
  pubsub.googleapis.com \
  run.googleapis.com \
  --project="${PROJECT_ID}" --quiet

PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')

echo "==> [2/9] Setting up Artifact Registry..."
if ! gcloud artifacts repositories describe expense-agent --location="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud artifacts repositories create expense-agent \
    --repository-format=docker \
    --location="${REGION}" \
    --project="${PROJECT_ID}" --quiet
fi

# Ensure Cloud Build compute SA has access to registry
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/artifactregistry.writer" \
  --quiet >/dev/null

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/storage.objectViewer" \
  --quiet >/dev/null

echo "==> [3/9] Building container images (parallel)..."
gcloud builds submit . \
  --tag "${BACKEND_IMAGE}" \
  --project="${PROJECT_ID}" --quiet &
BACKEND_BUILD_PID=$!

gcloud builds submit frontend/ \
  --tag "${FRONTEND_IMAGE}" \
  --project="${PROJECT_ID}" --quiet &
FRONTEND_BUILD_PID=$!

wait "${BACKEND_BUILD_PID}"
wait "${FRONTEND_BUILD_PID}"

echo "==> [4/9] Creating Service Accounts..."
for SA in expense-agent-invoker approval-ui-invoker; do
  if ! gcloud iam service-accounts describe "${SA}@${PROJECT_ID}.iam.gserviceaccount.com" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud iam service-accounts create "${SA}" \
      --display-name="Ambient Expense Agent - ${SA}" \
      --project="${PROJECT_ID}"
  fi
done

echo "==> [5/9] Deploying Backend Cloud Run Service..."
gcloud run deploy "${BACKEND_SERVICE}" \
  --image="${BACKEND_IMAGE}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --no-allow-unauthenticated \
  --min-instances=1 \
  --no-cpu-throttling \
  --quiet

BACKEND_URL=$(gcloud run services describe "${BACKEND_SERVICE}" --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)')

echo "==> [6/9] Deploying Frontend Cloud Run Service..."
gcloud beta run deploy "${FRONTEND_SERVICE}" \
  --image="${FRONTEND_IMAGE}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --no-allow-unauthenticated \
  --min-instances=1 \
  --no-cpu-throttling \
  --service-account="approval-ui-invoker@${PROJECT_ID}.iam.gserviceaccount.com" \
  --set-env-vars="BACKEND_URL=${BACKEND_URL},USE_SERVICE_AUTH=true,PUBSUB_SUBSCRIPTION=expense-reports-push,APP_NAME=${AGENT_NAME}" \
  --iap \
  --quiet

FRONTEND_URL=$(gcloud run services describe "${FRONTEND_SERVICE}" --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)')

echo "==> [7/9] Setting up IAM Bindings..."
# Grant Vertex AI User to default Compute SA
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/aiplatform.user" \
  --quiet >/dev/null

# Allow Pub/Sub Invoker SA and Frontend Invoker SA to invoke Backend service
gcloud run services add-iam-policy-binding "${BACKEND_SERVICE}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:expense-agent-invoker@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/run.invoker" \
  --quiet >/dev/null

gcloud run services add-iam-policy-binding "${BACKEND_SERVICE}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:approval-ui-invoker@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/run.invoker" \
  --quiet >/dev/null

# Allow Pub/Sub service agent to create OIDC tokens
gcloud iam service-accounts add-iam-policy-binding "expense-agent-invoker@${PROJECT_ID}.iam.gserviceaccount.com" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --project="${PROJECT_ID}" \
  --quiet >/dev/null

# Grant user IAP access to Frontend service
gcloud beta iap web add-iam-policy-binding \
  --resource-type=cloud-run \
  --service="${FRONTEND_SERVICE}" \
  --region="${REGION}" \
  --member="user:${NOTIFICATION_EMAIL}" \
  --role="roles/iap.httpsResourceAccessor" \
  --project="${PROJECT_ID}" \
  --quiet >/dev/null

# Allow IAP service agent to invoke Frontend service
gcloud run services add-iam-policy-binding "${FRONTEND_SERVICE}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-iap.iam.gserviceaccount.com" \
  --role="roles/run.invoker" \
  --quiet >/dev/null

echo "==> [8/9] Configuring Pub/Sub Topics & Subscription..."
for TOPIC in expense-reports expense-reports-dead-letter; do
  if ! gcloud pubsub topics describe "${TOPIC}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud pubsub topics create "${TOPIC}" --project="${PROJECT_ID}"
  fi
done

if gcloud pubsub subscriptions describe expense-reports-push --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud pubsub subscriptions delete expense-reports-push --project="${PROJECT_ID}"
fi

gcloud pubsub subscriptions create expense-reports-push \
  --topic=expense-reports \
  --push-endpoint="${BACKEND_URL}/apps/${AGENT_NAME}/trigger/pubsub" \
  --push-auth-service-account="expense-agent-invoker@${PROJECT_ID}.iam.gserviceaccount.com" \
  --push-auth-token-audience="${BACKEND_URL}" \
  --ack-deadline=600 \
  --min-retry-delay=10s \
  --max-retry-delay=600s \
  --dead-letter-topic=expense-reports-dead-letter \
  --max-delivery-attempts=5 \
  --expiration-period=never \
  --project="${PROJECT_ID}" \
  --quiet

echo "==> [9/9] Setting up Monitoring & Alerting..."
# Create log-based metric
gcloud logging metrics create expense-review-alerts \
  --description="Counts expense review alerts from the expense agent." \
  --log-filter="resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"${BACKEND_SERVICE}\" AND jsonPayload.alert_type=\"expense_review\"" \
  --project="${PROJECT_ID}" 2>/dev/null || \
gcloud logging metrics update expense-review-alerts \
  --description="Counts expense review alerts from the expense agent." \
  --log-filter="resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"${BACKEND_SERVICE}\" AND jsonPayload.alert_type=\"expense_review\"" \
  --project="${PROJECT_ID}"

CHANNEL_NAME=$(gcloud beta monitoring channels list --project="${PROJECT_ID}" --format="json" | python -c "import sys, json; print(next((x['name'] for x in json.load(sys.stdin) if x.get('displayName') == 'Expense Agent - Review Alerts'), ''))")

if [ -z "${CHANNEL_NAME}" ]; then
  CHANNEL_NAME=$(gcloud beta monitoring channels create \
    --display-name="Expense Agent - Review Alerts" \
    --type="email" \
    --channel-labels="email_address=${NOTIFICATION_EMAIL}" \
    --project="${PROJECT_ID}" \
    --format="value(name)")
fi

# Create/update alert policy
cat <<EOF > alert_policy_payload.json
{
  "displayName": "Expense Agent - High-Value Expense Review",
  "combiner": "OR",
  "conditions": [
    {
      "displayName": "Expense review count > 0",
      "conditionThreshold": {
        "filter": "metric.type=\"logging.googleapis.com/user/expense-review-alerts\" AND resource.type=\"cloud_run_revision\"",
        "comparison": "COMPARISON_GT",
        "thresholdValue": 0.0,
        "duration": "0s",
        "aggregations": [
          {
            "alignmentPeriod": "60s",
            "perSeriesAligner": "ALIGN_COUNT"
          }
        ]
      }
    }
  ],
  "notificationChannels": [
    "${CHANNEL_NAME}"
  ],
  "documentation": {
    "content": "## Expense Review Required\n\nOne or more expenses of **\$100 or more** have been flagged for review by the ambient expense agent.\n\n### What to do\n\n1. **[Open the Approval UI](${FRONTEND_URL}/approval)** to review pending expenses\n2. Check the amount, submitter, category, and the LLM's risk assessment\n3. Click **Approve** or **Reject** — the agent will log your decision and resume the workflow\n",
    "mimeType": "text/markdown"
  },
  "enabled": true
}
EOF

POLICY_NAME=$(gcloud monitoring policies list \
  --project="${PROJECT_ID}" \
  --filter="displayName='Expense Agent - High-Value Expense Review'" \
  --format="value(name)" | head -n 1)

if [ -n "${POLICY_NAME}" ]; then
  gcloud monitoring policies update "${POLICY_NAME}" \
    --policy-from-file=alert_policy_payload.json \
    --project="${PROJECT_ID}" --quiet
else
  gcloud monitoring policies create \
    --policy-from-file=alert_policy_payload.json \
    --project="${PROJECT_ID}" --quiet
fi

rm alert_policy_payload.json

echo ""
echo "==> Deployment Complete!"
echo "  Backend:   ${BACKEND_URL}"
echo "  Frontend:  ${FRONTEND_URL}"
echo "  Approval:  ${FRONTEND_URL}/approval"
echo "  Topic:     expense-reports"
echo "  Alerts:    Expenses >= \$100 -> ${NOTIFICATION_EMAIL}"
