# Ambient Expense Agent - Deployment & Verification Guide

This guide walks you through the step-by-step setup, OAuth configuration, and payload testing for the event-driven Ambient Expense Agent on Google Cloud Platform.

---

## Deployed GCP Services & Resources

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

## 1. Prerequisites & Deployment

### Step A: Configure the OAuth Consent Screen
Identity-Aware Proxy (IAP) requires a configured OAuth consent screen to verify user logins.
1. Open the [Google Cloud Console OAuth Consent Screen page](https://console.cloud.google.com/apis/oauthconsent).
2. Choose **External** user type and click **Create**.
3. Fill in the required fields:
   * **App name**: `Expense Approval UI`
   * **User support email**: Select your email from the dropdown.
   * **Developer contact information**: Enter your email.
4. Click **Save and Continue** through the remaining screens, then return to the Dashboard.

### Step B: Run the Deployment Script
Run the script using Git Bash to provision all GCP APIs, Cloud Run services, Pub/Sub topics, IAM bindings, logging metrics, and monitoring alerts:
```bash
export NOTIFICATION_EMAIL="your-email@example.com"
chmod +x scripts/*.sh
./scripts/deploy.sh
```

---

## 2. Configuring IAP (OAuth Client Linkage)

Because the project uses an **External** OAuth Consent Screen, Google cannot automatically provision a default client. You must create and link it manually:

### Step 1: Create a Web OAuth Client ID
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

### Step 2: Link Credentials to IAP
1. Navigate to the **Identity-Aware Proxy** console page.
2. Find the row for **`expense-approval-ui`** under the **Cloud Run** section.
3. Click the three vertical dots (More actions) on the far right and select **Edit OAuth Client** (or *Configure Custom OAuth Credentials*).
4. Paste the **Client ID** and **Client Secret** into their fields and click **Save**.
5. Go to the **Audience** section on the left-hand navigation pane of the Google Auth Platform, scroll to **Test users**, click **Add Users**, and add your email to authorize your account.

## 3. Testing the Application (Pub/Sub)

### What is Pub/Sub? (For Non-Experts)
Think of **Pub/Sub (Publish/Subscribe)** as a post office. 
* **The Topic (`expense-reports`)** is like a public mailbox.
* **The Subscription** is like a postman who immediately delivers any envelope placed in the mailbox directly to the backend AI agent's door.
* **The Payload (JSON)** is the letter inside the envelope containing the expense details.

To test the system, we need to drop an "envelope" into the mailbox. You can do this in **two ways**:

---

### Option A: Using the GCP Console UI (No Commands Needed)
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

### Option B: Using the One-Click CLI Script
If you have a terminal open, you can run a pre-packaged script that automatically handles the publication for you:
```bash
# Run this from Git Bash
./scripts/test-expense.sh
```

---

### Step 3: Verify Results
1. **Email Alert**: In 2–5 minutes, you will receive an alert email containing a link to review the high-value expense.
2. **Approval Dashboard**: Access the frontend app URL:
   `https://expense-approval-ui-4iyhzljhnq-uc.a.run.app/approval`
   Log in using your authorized Google Account. Click **Refresh** to see the pending approval with the AI's risk assessment, where you can **Approve** or **Reject** the expense.

---

## 4. Teardown & Clean-up

To clean up and delete all resources created during this tutorial, run the cleanup script:
```bash
./scripts/destroy.sh
```
