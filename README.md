# Ambient Expense Agent

A production-ready **ambient agent** that processes expense reports arriving via
Pub/Sub and routes them through an **ADK 2.0 graph-based workflow**. Low-value
expenses are auto-approved instantly; high-value ones go through LLM risk
analysis and **human-in-the-loop approval** before a decision is made.

<table>
  <thead>
    <tr>
      <th colspan="2">Key Features</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>🔄</td>
      <td><strong>ADK 2.0 Graph Workflow:</strong> Conditional routing with function nodes and LLM agents in the same graph — business rules stay in code, LLM handles judgment calls.</td>
    </tr>
    <tr>
      <td>📡</td>
      <td><strong>Ambient & Event-Driven:</strong> Listens for expense events via <a href="https://cloud.google.com/pubsub">Pub/Sub</a> triggers and processes them automatically in the background.</td>
    </tr>
    <tr>
      <td>✋</td>
      <td><strong>Human-in-the-Loop:</strong> High-value expenses pause the workflow with <code>RequestInput</code> until a manager approves or rejects via a dedicated approval UI.</td>
    </tr>
    <tr>
      <td>☁️</td>
      <td><strong>Production-Ready Deployment:</strong> One-command script setup — two <a href="https://cloud.google.com/run">Cloud Run</a> services, Pub/Sub, Cloud Monitoring alerts, IAM, and <a href="https://cloud.google.com/iap">IAP</a>.</td>
    </tr>
  </tbody>
</table>

| Attribute | Description |
| :--- | :--- |
| **Interaction Type** | Ambient (event-driven) with HITL approval |
| **Complexity** | Intermediate |
| **Agent Type** | ADK 2.0 Graph-based Workflow |
| **Trigger Sources** | Pub/Sub push |

## How It Works

The agent is built as an ADK 2.0 [`Workflow`](https://adk.dev/workflows/) with
conditional routing. The $100 threshold lives in code, not in a prompt — only
high-value expenses hit the LLM. See
[`expense_agent/agent.py`](expense_agent/agent.py) for the full graph definition.

```
  Expense arrives (Pub/Sub)
            │
     parse & extract data
            │
      route by amount
       │          │
   < $100       >= $100
       │          │
  auto-approve   LLM reviews risk
   (done)        & emails alert
                  │
            manager approves
             or rejects
             (approval UI)
                  │
            agent logs decision
             & takes action
```

### Deployment Architecture

The agent deploys as two [Cloud Run](https://cloud.google.com/run) services
with [Cloud Monitoring](https://cloud.google.com/monitoring) for email alerts:

- **Backend** — runs the ADK agent. Pub/Sub pushes expense messages to it
  directly (authenticated via service account).
- **Frontend** — the approval UI. Protected by
  [Identity-Aware Proxy (IAP)](https://cloud.google.com/iap) so only
  authorized managers can access it. Calls the backend on behalf of the user.
- **Monitoring** — when the agent flags a high-value expense, it emits a
  structured log. A log-based metric triggers an email alert to the manager
  with a link to the approval UI.

```
                       ┌─────────────────────────┐
  Pub/Sub ───────────► │  Backend  (Cloud Run)   │
                       │  ADK agent + triggers   │
                       └──────┬─────────▲────────┘
                              │         │
                    structured log      │
                              │         │
                       ┌──────▼──────┐  │
                       │  Cloud      │  │
                       │  Monitoring │  │
                       └──────┬──────┘  │
                              │         │
                        email alert     │
                              │         │
                       ┌──────▼──────┐  │
                       │  Manager    │  │
                       └──────┬──────┘  │
                              │         │
                       ┌──────▼─────────┴────────┐
  Browser ── login ──► │  Frontend  (Cloud Run)  │
                       │  Approval UI (IAP)      │
                       └─────────────────────────┘
```

## Getting Started

**Prerequisites:** [Python 3.11+](https://www.python.org/downloads/), [uv](https://github.com/astral-sh/uv)

### 1. Clone the repository

```bash
git clone https://github.com/google/adk-samples.git
cd adk-samples/python/agents/ambient-expense-agent
```

### 2. Configure authentication

Create a `.env` file (see [`.env.example`](.env.example)).

**Option A: [Google AI Studio](https://aistudio.google.com/app/apikey)**

```bash
echo "GOOGLE_API_KEY=YOUR_AI_STUDIO_API_KEY" >> .env
```

**Option B: [Google Cloud Vertex AI](https://cloud.google.com/vertex-ai)**

```bash
echo "GOOGLE_GENAI_USE_VERTEXAI=TRUE" >> .env
echo "GOOGLE_CLOUD_PROJECT=YOUR_PROJECT_ID" >> .env
echo "GOOGLE_CLOUD_LOCATION=global" >> .env
gcloud auth application-default login
```

### 3. Install and run

Start the backend:

```bash
make install && make dev
```

In a separate terminal, start the approval UI:

```bash
make install-frontend && make dev-frontend
```

### 4. Try it out

Open the ADK playground to interact with the agent directly:

```bash
make playground
```

This starts the ADK web UI at `http://localhost:8501`.

To test the full Pub/Sub trigger flow, send an expense in another terminal:

```bash
curl -s http://localhost:8080/apps/expense_agent/trigger/pubsub \
  -H "Content-Type: application/json" \
  -d "{\"message\":{\"data\":\"$(echo '{"amount":250,"submitter":"alice@company.com","category":"travel","description":"Flight to NYC","date":"2026-04-10"}' | base64)\",\"attributes\":{\"source\":\"test\"}},\"subscription\":\"test-sub\"}"
```

This $250 expense triggers review + HITL approval. Open the approval UI
at `http://localhost:8081/approval` to approve or reject it.

> **Tip:** Expenses under $100 are auto-approved — change `amount` to
> `45` to test that path.

## Cloud Deployment

Deploy both services and all supporting infrastructure with a single command.

**Prerequisites:** [Google Cloud SDK](https://cloud.google.com/sdk/docs/install)

```bash
gcloud config set project YOUR_PROJECT_ID
export NOTIFICATION_EMAIL=finance@example.com
./scripts/deploy.sh
```

This builds container images (in parallel) and deploys everything via the
deployment script: two Cloud Run services, Pub/Sub (with dead-letter), Cloud
Monitoring alerts, IAM, and IAP.

> **Note:** IAP can take **5–10 minutes** to fully propagate after the
> initial deployment. If you see a `403 Forbidden` when opening the
> approval UI, wait a few minutes and refresh.

### Test the deployed agent

```bash
make remote-test
```

This publishes a $250 travel expense. The agent will route it to the review
agent, analyze risk factors, email an alert to `NOTIFICATION_EMAIL`, and pause
for human approval. Open the approval UI (URL printed by the deploy script) to
approve or reject.

### Cleanup

```bash
./scripts/destroy.sh
```

## Customization

| What to change | How |
| --- | --- |
| **Approval threshold** | Change `review_threshold` in `expense_agent/config.py` |
| **LLM model** | Change `model` in `expense_agent/config.py` |
| **Expense schema** | Edit the `ExpenseData` Pydantic model in `expense_agent/agent.py` |
| **Review logic** | Edit the `review_agent` instruction in `expense_agent/agent.py` |
| **Approval UI** | Edit `frontend/static/approval.html` |
| **Downstream actions** | Add workflow nodes for Slack, databases, or notifications |
| **Multi-level routing** | Add routes (e.g., `ESCALATE` for expenses > $1000) |
| **Notification channel** | Replace email with Slack, PagerDuty, or SMS in `scripts/deploy.sh` ([docs](https://cloud.google.com/monitoring/support/notification-options)) |
| **Email content** | The alert email uses a static template. To include dynamic expense data (amount, submitter) in the email, switch from log-based metrics to [custom metrics with template variables](https://cloud.google.com/monitoring/alerts/doc-variables) |

## Troubleshooting

- For general ADK issues, see the [ADK documentation](https://adk.dev).
- For trigger endpoint details, see [Ambient Agents](https://adk.dev/runtime/ambient-agents/).
- For Cloud Run deployment, see [Deploy to Cloud Run](https://adk.dev/deploy/cloud-run/).

## Disclaimer

This agent sample is provided for illustrative purposes only. It serves as a basic example of an agent and a foundational starting point for individuals or teams to develop their own agents.

Users are solely responsible for any further development, testing, security hardening, and deployment of agents based on this sample. We recommend thorough review, testing, and the implementation of appropriate safeguards before using any derived agent in a live or critical system.

---

## Deployment & Verification Guide

This guide walks you through the step-by-step setup, OAuth configuration, and payload testing for the event-driven Ambient Expense Agent on Google Cloud Platform.

---

### Deployed GCP Services & Resources

The deployment process provisions **2 core Cloud Run services** along with their supporting infrastructure. In total, the following **10 GCP resources** are created and managed:

| Resource Type | Count | Name(s) | Description |
| :--- | :--- | :--- | :--- |
| **Cloud Run Services** | 2 | `ambient-expense-agent`<br>`expense-approval-ui` | The backend AI agent workflow and the frontend IAP-secured manager approval dashboard. |
| **Pub/Sub Topics** | 2 | `expense-reports`<br>`expense-reports-dead-letter` | The main message entry point and the dead-letter topic for failed message processing. |
| **Pub/Sub Subscription** | 1 | `expense-reports-push` | Authenticated push subscription delivering messages to the backend service. |
| **Service Accounts** | 2 | `expense-agent-invoker`<br>`approval-ui-invoker` | Identity resources granting least-privilege invocation access to Backend/PubSub. |
| **Artifact Registry** | 1 | `expense-agent` | Private Docker registry storing the backend and frontend container images. |
| **Logging Metric** | 1 | `expense-review-alerts` | Custom log-based counter counting flagged expense reviews. |
| **Monitoring Notification Channel** | 1 | `Expense Agent - Review Alerts` | Email channel mapping alerts to the reviewer email. |
| **Monitoring Alert Policy** | 1 | `Expense Agent - High-Value Expense Review` | Policy triggering alerts when the logging metric exceeds 0. |

---

### 1. Prerequisites & Deployment

#### Step A: Configure the OAuth Consent Screen
Identity-Aware Proxy (IAP) requires a configured OAuth consent screen to verify user logins.
1. Open the [Google Cloud Console OAuth Consent Screen page](https://console.cloud.google.com/apis/oauthconsent).
2. Choose **External** user type and click **Create**.
3. Fill in the required fields:
   * **App name**: `Expense Approval UI`
   * **User support email**: Select your email from the dropdown.
   * **Developer contact information**: Enter your email.
4. Click **Save and Continue** through the remaining screens, then return to the Dashboard.

#### Step B: Run the Deployment Script
Run the script using Git Bash to provision all GCP APIs, Cloud Run services, Pub/Sub topics, IAM bindings, logging metrics, and monitoring alerts:
```bash
export NOTIFICATION_EMAIL="your-email@example.com"
chmod +x scripts/*.sh
./scripts/deploy.sh
```

---

### 2. Configuring IAP (OAuth Client Linkage)

Because the project uses an **External** OAuth Consent Screen, Google cannot automatically provision a default client. You must create and link it manually:

#### Step 1: Create a Web OAuth Client ID
1. Open the [Google Cloud Console Credentials Page](https://console.cloud.google.com/apis/credentials).
2. Click **+ Create Credentials** at the top and select **OAuth client ID**.
3. Select **Web application** in the *Application type* dropdown.
4. Set the **Name** to `Expense Approval IAP Client`.
5. Under **Authorized redirect URIs**, click **+ Add URI** and temporarily enter your frontend app URL as a placeholder:
   ```text
   https://expense-approval-ui-4iyhzljhnq-uc.a.run.app
   ```
6. Click **Create**. A dialog will show your **Client ID** and **Client Secret**. Copy both values.
7. Close the dialog, click the **Edit (pencil) icon** next to the newly created credential, and update the **Authorized redirect URI** to:
   ```text
   https://iap.googleapis.com/v1/oauth/clientIds/YOUR_CLIENT_ID:handleRedirect
   ```
   *(Be sure to replace `YOUR_CLIENT_ID` with the actual Client ID you copied, then click **Save**).*

#### Step 2: Link Credentials to IAP
1. Navigate to the **Identity-Aware Proxy** console page.
2. Find the row for **`expense-approval-ui`** under the **Cloud Run** section.
3. Click the three vertical dots (More actions) on the far right and select **Edit OAuth Client** (or *Configure Custom OAuth Credentials*).
4. Paste the **Client ID** and **Client Secret** into their fields and click **Save**.
5. Go to the **Audience** section on the left-hand navigation pane of the Google Auth Platform, scroll to **Test users**, click **Add Users**, and add your email to authorize your account.

### 3. Testing the Application (Pub/Sub)

#### What is Pub/Sub? (For Non-Experts)
Think of **Pub/Sub (Publish/Subscribe)** as a post office. 
* **The Topic (`expense-reports`)** is like a public mailbox.
* **The Subscription** is like a postman who immediately delivers any envelope placed in the mailbox directly to the backend AI agent's door.
* **The Payload (JSON)** is the letter inside the envelope containing the expense details.

To test the system, we need to drop an "envelope" into the mailbox. You can do this in **two ways**:

---

#### Option A: Using the GCP Console UI (No Commands Needed)
1. Open the [Google Cloud Pub/Sub Topics Page](https://console.cloud.google.com/cloudpubsub/topic/list).
2. Click on the topic named **`expense-reports`**.
3. Click the **Messages** tab near the top of the page.
4. Click the **Publish Message** button.
5. In the **Message body** field, paste this text:
   ```json
   {"amount": 250.00, "submitter": "alice@company.com", "category": "travel", "description": "Flight to NYC for client meeting", "date": "2026-04-10"}
   ```
6. Click the **Publish** button at the bottom of the form. That's it!

---

#### Option B: Using the One-Click CLI Script
If you have a terminal open, you can run a pre-packaged script that automatically handles the publication for you:
```bash
# Run this from Git Bash
./scripts/test-expense.sh
```

---

#### Step 3: Verify Results
1. **Email Alert**: In 2–55 minutes, you will receive an alert email containing a link to review the high-value expense.
2. **Approval Dashboard**: Access the frontend app URL:
   `https://expense-approval-ui-4iyhzljhnq-uc.a.run.app/approval`
   Log in using your authorized Google Account. Click **Refresh** to see the pending approval with the AI's risk assessment, where you can **Approve** or **Reject** the expense.

---

### 4. Teardown & Clean-up

To clean up and delete all resources created during this tutorial, run the cleanup script:
```bash
./scripts/destroy.sh
```
