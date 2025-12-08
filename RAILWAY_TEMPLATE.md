# Railway Template: Incident Response & Log Analysis

This template provides a comprehensive incident response and log analysis system that integrates with Railway infrastructure and provides intelligent alerts via Slack notifications powered by AI analysis.

## Features

- **Real-time Log Streaming**: Monitors Railway services for log events
- **AI-Powered Analysis**: Uses OpenAI to analyze incidents and provide remediation suggestions
- **Slack Integration**: Sends intelligent notifications to your Slack workspace
- **Service Monitoring**: Tracks Railway service health and performance
- **Incident Triage**: Automatic categorization and prioritization of incidents

## Required Environment Variables

To use this template, you must configure the following environment variables:

### 🚀 Core (must be set by user)

- `SECRET_KEY_BASE`: Phoenix secret (generate with `mix phx.gen.secret`)
- `RAILWAY_API_TOKEN`: Railway API token (Dashboard → Account → API Tokens)
- `OPENAI_API_KEY`: OpenAI API key (app will not start without it)

### 🔔 Slack (required)

- `SLACK_BOT_TOKEN`: Bot token (starts with `xoxb-`; scopes `chat:write`, `channels:read`, `users:read`)
- `SLACK_SIGNING_SECRET`: Signing secret from Slack app → Basic Information
- `SLACK_CHANNEL_ID`: Channel ID (starts with `C` or `G`)

### 🗄️ Auto-provided by Railway (no action)

- `DATABASE_URL`: From the bundled Postgres service (ensure the Postgres addon is attached)
- Railway injects: `PORT`, `RAILWAY_PUBLIC_DOMAIN` (used as `PHX_HOST` fallback), `RAILWAY_PROJECT_ID`, `RAILWAY_ENVIRONMENT_ID`, `RAILWAY_ENVIRONMENT`, `RAILWAY_SERVICE_ID`, `RAILWAY_SERVICE_NAME`, `RAILWAY_PROJECT_NAME`, `RAILWAY_ENVIRONMENT_NAME`, `RAILWAY_PRIVATE_DOMAIN`, `RAILWAY_STATIC_URL`, `RAILWAY_SERVICE_RAILWAY_TEMPLATE_URL`
- `PHX_SERVER` defaulted to true in the template; `MIX_ENV` defaulted to `prod`
- `PHX_HOST` is optional (code falls back to `RAILWAY_PUBLIC_DOMAIN`)
- `DNS_CLUSTER_QUERY` is optional (only set if clustering multiple instances)

### 📡 Monitoring targets (optional)

- `RAILWAY_MONITORED_PROJECTS`: Comma-separated Railway project IDs
- `RAILWAY_MONITORED_ENVIRONMENTS`: Comma-separated environment IDs (defaults to `production` if blank)
- `RAILWAY_MONITORED_SERVICES`: Comma-separated service IDs (optional; pairs with the projects/environments above)

### 🤖 LLM provider options (optional)

- `LLM_DEFAULT_PROVIDER`: `openai` or `anthropic` (default: `openai`)
- `ANTHROPIC_API_KEY`: Claude API key (optional)

### ⚙️ Advanced tuning (optional; code has sane defaults)

If you need overrides, you can still set:
`RAILWAY_POLLING_INTERVAL`, `RAILWAY_MAX_RETRY_ATTEMPTS`, `RAILWAY_MAX_BACKOFF`,
`RAILWAY_HEARTBEAT_INTERVAL`, `RAILWAY_HEARTBEAT_TIMEOUT`, `RAILWAY_RATE_LIMIT_HR`,
`RAILWAY_RATE_LIMIT_SEC`, `RAILWAY_BATCH_MIN_SIZE`, `RAILWAY_BATCH_MAX_SIZE`,
`RAILWAY_BATCH_WINDOW_MIN`, `RAILWAY_BATCH_WINDOW_MAX`, `RAILWAY_BUFFER_RETENTION`,
`RAILWAY_MEMORY_LIMIT`, `RAILWAY_GRAPHQL_ENDPOINT`, `RAILWAY_WS_ENDPOINT`

## Setup Instructions

### 1. Railway Setup

1. **Deploy this template** to your Railway account
2. **Get Railway API Token**:

   - Go to Railway Dashboard → Account → API Tokens
   - Create a new token with read permissions
   - Add `RAILWAY_API_TOKEN` to your environment variables

3. **Configure Monitoring**:
   - Get Project IDs from Railway Dashboard URLs
   - Add `RAILWAY_MONITORED_PROJECTS` with comma-separated project IDs

### 2. OpenAI Setup

1. **Create OpenAI Account** at https://platform.openai.com
2. **Generate API Key**:
   - Go to https://platform.openai.com/api-keys
   - Click "Create new secret key"
   - Add `OPENAI_API_KEY` to your environment variables

### 3. Slack Setup

1. **Create Slack App**:

   - Go to https://api.slack.com/apps → "Create New App"
   - Choose "From scratch"
   - Enter app name and select your workspace

2. **Configure Bot Permissions**:

   - Go to "OAuth & Permissions"
   - Add these Bot Token Scopes:
     - `chat:write` - Send messages
     - `channels:read` - Access channel information
     - `users:read` - Access user information

3. **Enable Events**:

   - Go to "Event Subscriptions"
   - Enable Events
   - Add Request URL: `https://your-domain.railway.app/api/slack/events`
   - Subscribe to: `app_mention`, `message.channels`

4. **Get Credentials**:

   - Copy "Bot User OAuth Token" (starts with `xoxb-`)
   - Copy "Signing Secret" from Basic Information
   - Add both to environment variables

5. **Add to Channel**:

   - Install the app to your workspace
   - Invite the bot to your target channel: `/invite @your-app-name`

6. **Get Channel ID**:
   - Right-click on target channel in Slack
   - Copy the channel ID (format: `C0123456789`)

### 4. Final Configuration

Add all required environment variables to your Railway service:

```bash
# Required
SECRET_KEY_BASE=$(mix phx.gen.secret)
RAILWAY_API_TOKEN=your_railway_api_token
OPENAI_API_KEY=your_openai_api_key
SLACK_BOT_TOKEN=xoxb-your-slack-bot-token
SLACK_SIGNING_SECRET=your_slack_signing_secret
SLACK_CHANNEL_ID=C0123456789

# Optional - Monitoring Targets
RAILWAY_MONITORED_PROJECTS=project_id_1,project_id_2
RAILWAY_MONITORED_ENVIRONMENTS=env_id_1,env_id_2
RAILWAY_MONITORED_SERVICES=service_id_1,service_id_2

# Optional tuning
RAILWAY_POLLING_INTERVAL=30
RAILWAY_MAX_RETRY_ATTEMPTS=10
RAILWAY_MAX_BACKOFF=60000
RAILWAY_HEARTBEAT_INTERVAL=30000
RAILWAY_HEARTBEAT_TIMEOUT=45000
RAILWAY_RATE_LIMIT_HR=10000
RAILWAY_RATE_LIMIT_SEC=50
RAILWAY_BATCH_MIN_SIZE=10
RAILWAY_BATCH_MAX_SIZE=1000
RAILWAY_BATCH_WINDOW_MIN=5
RAILWAY_BATCH_WINDOW_MAX=300
RAILWAY_BUFFER_RETENTION=24
RAILWAY_MEMORY_LIMIT=512
```

### 5. Deploy and Test

1. **Redeploy** your Railway service to apply new variables
2. **Test the integration** by sending a message to your Slack channel
3. **Verify logs** in Railway dashboard to ensure everything is working

## Usage

Once configured, the system will:

1. **Monitor** your Railway services for log events and issues
2. **Analyze** incidents using AI to determine severity and root cause
3. **Notify** your Slack channel with intelligent alerts and suggestions
4. **Provide** remediation recommendations based on the analysis

## Monitoring Dashboard

Access your service dashboard at: `https://your-domain.railway.app`

## Troubleshooting

### Common Issues

1. **Application won't start**: Check that `OPENAI_API_KEY` is set correctly
2. **Slack notifications not working**: Verify bot permissions and channel ID
3. **No Railway data**: Ensure `RAILWAY_API_TOKEN` has proper permissions
4. **Rate limiting**: Adjust `RAILWAY_RATE_LIMIT_*` settings if needed

### Health Checks

- Check application logs: `railway logs`
- Verify environment variables: `railway variables`
- Test Slack connection: Send a test message to your channel

## Support

For issues with:

- **Railway**: https://docs.railway.app
- **OpenAI**: https://platform.openai.com/docs
- **Slack API**: https://api.slack.com/docs

---

**Template Version**: 1.0.0
**Last Updated**: 2025-12-08
