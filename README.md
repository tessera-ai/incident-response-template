# Railway Template: Incident Response & Log Analysis

🚨 **Deploy this template to get an intelligent incident response system that monitors your Railway services and provides AI-powered alerts via Slack.**

[![Deploy on Railway](https://railway.app/button.svg)](https://railway.app/new/template?template=https://github.com/your-org/incident-response-template)

## Features

- **🔍 Real-time Log Streaming**: Monitors Railway services for log events and anomalies
- **🤖 AI-Powered Analysis**: Uses OpenAI to analyze incidents and provide intelligent remediation suggestions
- **🚨 Slack Integration**: Sends smart notifications to your Slack workspace with severity assessment and action recommendations
- **📊 Service Monitoring**: Tracks Railway service health, performance, and deployment events
- **🎯 Incident Triage**: Automatic categorization and prioritization of incidents based on impact
- **🔒 Audit Trail**: Complete history of incidents, actions, and conversations for compliance

## Quick Start

### 1. Deploy This Template

Click the "Deploy on Railway" button above to deploy this template to your Railway account.

### 2. Configure Required Environment Variables

Go to your service's **Variables** tab in Railway and add the required variables.

> **Detailed, up-to-date variable list and defaults:** see `RAILWAY_TEMPLATE.md` (primary source for required/optional env vars and defaults).

## 📋 Setup Guides

For the full, authoritative variable list (required, optional, defaults), see `RAILWAY_TEMPLATE.md`.

### 🔗 Getting Your Railway API Token

1. Go to [Railway Dashboard → API Tokens](https://railway.app/account/tokens)
2. Click **"Create New Token"**
3. Give it a name (e.g., "Incident Response System")
4. Copy the token
5. Add it as `RAILWAY_API_TOKEN` in your Railway variables

> **Required permissions**: Read access to projects you want to monitor

### 🎯 Finding Your Railway Project IDs

1. Go to [Railway Dashboard](https://railway.app)
2. Select any project you want to monitor
3. Click **Settings** → copy the **Project ID**
4. Add it to `RAILWAY_MONITORED_PROJECTS` (comma-separated for multiple)

**Example:**

```bash
RAILWAY_MONITORED_PROJECTS=80661543-f4f8-473e-ae39-0e49270938de,another-project-id
```

### 🤖 Getting Your OpenAI API Key

1. Go to [OpenAI Platform → API Keys](https://platform.openai.com/api-keys)
2. Click **"Create new secret key"**
3. Copy the key (starts with `sk-proj-`)
4. Add it as `OPENAI_API_KEY` in Railway variables

> **Required**: The application will NOT start without this key

---

## 💬 Setting Up Slack Integration

### Step 1: Create a Slack App

1. Go to [Slack API Apps](https://api.slack.com/apps)
2. Click **"Create New App"** → **"From scratch"**
3. Name it (e.g., "Railway Agent") and select your workspace
4. Click **"Create App"**

### Step 2: Configure Bot Token Scopes

1. In your app settings, go to **OAuth & Permissions**
2. Under **Bot Token Scopes**, add:
   - `chat:write` - Send messages
   - `commands` - Slash commands
   - `im:history` - Read DM history (for conversations)

### Step 3: Enable Interactivity

1. Go to **Interactivity & Shortcuts**
2. Turn on **Interactivity**
3. Set the **Request URL** to:
   ```
   https://your-app.railway.app/api/slack/interactive
   ```
   (Replace `your-app.railway.app` with your actual Railway domain)

### Step 4: Add Slash Command (Optional)

1. Go to **Slash Commands**
2. Click **"Create New Command"**
3. Configure:
   - **Command**: `/tessera` (or your preferred name)
   - **Request URL**: `https://your-app.railway.app/api/slack/slash`
   - **Description**: "Interact with Railway Agent"

### Step 5: Install to Workspace

1. Go to **OAuth & Permissions**
2. Click **"Install to Workspace"**
3. Authorize the app

### Step 6: Get Your Credentials

After installation:

| Credential             | Where to Find                                                            |
| ---------------------- | ------------------------------------------------------------------------ |
| `SLACK_BOT_TOKEN`      | **OAuth & Permissions** → **Bot User OAuth Token** (starts with `xoxb-`) |
| `SLACK_SIGNING_SECRET` | **Basic Information** → **App Credentials** → **Signing Secret**         |

### Finding Your Slack Channel ID

1. Open Slack and go to the channel where you want alerts
2. Right-click the channel name → **"View channel details"**
3. At the bottom of the popup, copy the **Channel ID** (starts with `C`)

> **Important**: Invite the bot to your channel! Type `/invite @YourBotName` in the channel.

---

## Usage

### Automatic Monitoring

Once configured, Railway Agent automatically:

1. Connects to Railway log streams for your monitored projects
2. Analyzes logs for error patterns and anomalies
3. Sends Slack alerts when incidents are detected
4. Suggests (or automatically executes) remediation actions

### Slack Alerts

When an incident is detected, you'll receive a Slack message with:

- **Severity** and **confidence level**
- **Root cause analysis**
- **Suggested remediation action**
- Action buttons:
  - **Auto-Fix** - Execute suggested remediation
  - **Start Chat** - Begin conversational troubleshooting
  - **View Logs** - Open Railway logs
  - **Ignore** - Dismiss the alert

### Slash Commands

Use the `/tessera` command (or your configured command) in Slack:

```
/tessera restart api-service
/tessera scale memory api-service 2048
/tessera rollback api-service
/tessera status api-service
```

### Dashboard

Access the dashboard at `https://your-app.railway.app` to:

- View recent incidents and their status
- Toggle auto-remediation per service
- Monitor remediation action history
- Filter incidents by severity or status

---

## Troubleshooting

### No incidents detected

- Check that `RAILWAY_API_TOKEN` has access to the monitored projects
- Verify `RAILWAY_MONITORED_PROJECTS` contains valid project IDs
- Check Railway logs for WebSocket connection status

### Slack notifications not working

- Verify `SLACK_BOT_TOKEN` and `SLACK_SIGNING_SECRET` are correct
- Ensure the bot is invited to the target channel
- Check that `SLACK_CHANNEL_ID` is the channel ID (not the channel name)

### LLM analysis failing

- Verify `OPENAI_API_KEY` is valid and has credits
- Check for rate limits in the application logs
- Pattern-based detection continues even if LLM is unavailable

---

## Health Check

The app exposes a health endpoint at `/health`:

```bash
curl https://your-app.railway.app/health
```

Response:

```json
{
  "status": "healthy",
  "timestamp": "2025-12-05T12:00:00Z",
  "version": "0.1.0"
}
```

---

## License

MIT
