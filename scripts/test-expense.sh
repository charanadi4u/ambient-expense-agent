#!/usr/bin/env bash
#
# Copyright 2026 Google LLC
# Helper script to publish a test expense of $250.00 to Pub/Sub.

PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "charan-245405")

echo "Publishing test expense to Google Cloud Pub/Sub..."
echo "Payload: \$350.00 travel expense by alice@company.com"

# Create a temporary payload
PAYLOAD='{"amount":350.00,"submitter":"alice@company.com","category":"travel","description":"Flight to NYC for client meeting","date":"2026-04-10"}'

# Publish to topic
gcloud pubsub topics publish expense-reports \
  --project="${PROJECT_ID}" \
  --message="${PAYLOAD}"

echo "Done! The expense has been sent to the agent. Check the approval UI in a few seconds."
