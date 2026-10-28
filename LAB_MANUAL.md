# [FDE] Agent Identity Foundations: Challenge Lab (APEX013) — Complete Lab Guide & Solutions

## Lab Overview

In the previous lab (*Build Enterprise Agents*), you built a Code Assist Agent whose two specialist sub-agents had their tool credentials baked in:
- **`github_agent`** on **Vertex AI Agent Runtime** read a GitHub personal access token from its `.env`.
- **`salesforce_agent`** on **Cloud Run** read a Salesforce Connected App consumer key and secret from its `.env`.

In this lab, you remove both hardcoded secrets and replace them with **Agent Identity Auth Manager**:
- Configure an **API-key auth provider** (`github-mcp-auth-provider`) for the GitHub MCP server.
- Configure a **2-legged OAuth (2LO) auth provider** (`salesforce-2lo-auth-provider`) for Salesforce.
- Refactor both ADK agents to resolve credentials dynamically at tool-call time.
- Enable **Agent Identity** (SPIFFE principal) on the Agent Runtime agent and grant it `roles/agentidentity.user`.
- Grant the Cloud Run agent's **Service Account** `roles/agentidentity.user` and verify both agents end-to-end over A2A.

---

## Task 1. Prepare Your Environment for Agent Identity

### 1.1 Set Environment Variables

```bash
gcloud auth login
export PROJECT_ID="your-gcp-project-id"
gcloud auth application-default login

export LOCATION="us-central1"
export REGION="us-central1"
gcloud config set project "${PROJECT_ID}"
export PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')
export ORGANIZATION_ID=$(gcloud projects get-ancestors "${PROJECT_ID}" --format=json | jq -r '.[] | select(.type=="organization") | .id')
echo "Project: ${PROJECT_ID} (${PROJECT_NUMBER}), Org: ${ORGANIZATION_ID}, Location: ${LOCATION}, Agents: ${REGION}"
```

### 1.2 Run Lab Prerequisites Script

```bash
gcloud storage cp -r gs://${PROJECT_ID}-bucket/apex_labs .
bash apex_labs/lab2_prereqs.sh
export PATH="$HOME/.local/bin:$PATH"
```

### 1.3 Create `.env` for `github-agent`

```bash
cd ~/agents/github-agent
cat << EOF > .env
GOOGLE_CLOUD_PROJECT=$PROJECT_ID
GOOGLE_CLOUD_LOCATION=global
GOOGLE_GENAI_USE_VERTEXAI=True
MODEL=gemini-3.5-flash
GITHUB_MCP_URL=https://api.githubcopilot.com/mcp/
GITHUB_AUTH_PROVIDER_URI=projects/$PROJECT_ID/locations/$LOCATION/authProviders/github-mcp-auth-provider
EOF

agents-cli info
```

### 1.4 Enable the Agent Identity APIs (Solution)

```bash
gcloud services enable \
  iam.googleapis.com \
  agentidentity.googleapis.com \
  aiplatform.googleapis.com \
  agentidentitycredentials.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com
```

---

## Task 2. Create the GitHub API-Key Auth Provider

### 2.1 Store GitHub PAT in a Shell Variable

```bash
read -rs GITHUB_PAT && echo
```

### 2.2 Create `github-mcp-auth-provider` (Solution)

```bash
gcloud alpha agent-identity auth-providers create github-mcp-auth-provider \
  --project="${PROJECT_ID}" \
  --location="${LOCATION}" \
  --api-key="${GITHUB_PAT}"
```

### 2.3 Verify and Export URI

```bash
gcloud alpha agent-identity auth-providers list \
  --project="${PROJECT_ID}" \
  --location="${LOCATION}"

export GITHUB_AUTH_PROVIDER_URI="projects/${PROJECT_ID}/locations/${LOCATION}/authProviders/github-mcp-auth-provider"
echo "${GITHUB_AUTH_PROVIDER_URI}"
```

---

## Task 3. Move the GitHub Agent onto the Auth Provider

### 3.1 Complete `~/agents/github-agent/agent/agent.py` (Solution)

See [`agents/github-agent/agent/agent.py`](agents/github-agent/agent/agent.py) for the complete solved file:

- **TODO 1**:
  ```python
  CredentialManager.register_auth_provider(GcpAuthProvider())
  ```
- **TODO 2**:
  ```python
  github_auth_scheme = GcpAuthProviderScheme(name=GITHUB_AUTH_PROVIDER_URI)
  ```
- **TODO 3**:
  ```python
  toolset = McpToolset(
      connection_params=StreamableHTTPConnectionParams(url=GITHUB_MCP_URL),
      auth_scheme=github_auth_scheme,
      tool_filter=GITHUB_TOOL_FILTER,
      header_provider=github_header_provider,
  )
  return toolset
  ```

### 3.2 Deploy with Agent Identity Enabled

```bash
cd ~/agents/github-agent
chmod 777 ./deploy_with_identity.sh
REGION=us-central1 A2A_APP_NAME=agent AUTH_PROVIDER_NAME=github-mcp-auth-provider DISPLAY_NAME=github-agent-v2 ./deploy_with_identity.sh
```

Set the resulting identity and engine ID variables:

```bash
export GITHUB_AGENT_IDENTITY="principal://agents.global.org-${ORGANIZATION_ID}.system.id.goog/resources/aiplatform/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${GITHUB_ENGINE_ID}"
export GITHUB_ENGINE_ID="<PASTE_REASONING_ENGINE_ID>"
export GITHUB_AGENT_URL="https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${GITHUB_ENGINE_ID}"
```

### 3.3 Grant the Agent's SPIFFE Principal Access to the Auth Provider (Solution)

```bash
gcloud alpha agent-identity auth-providers add-iam-policy-binding github-mcp-auth-provider \
  --project="${PROJECT_ID}" \
  --location="${LOCATION}" \
  --role="roles/agentidentity.user" \
  --member="${GITHUB_AGENT_IDENTITY}"

# Also grant your user account for local testing
gcloud alpha agent-identity auth-providers add-iam-policy-binding github-mcp-auth-provider \
  --project="${PROJECT_ID}" \
  --location="${LOCATION}" \
  --role="roles/agentidentity.user" \
  --member="user:$(gcloud config get-value account)"
```

### 3.4 Test the Deployed GitHub Agent

```bash
agents-cli run --url "${GITHUB_AGENT_URL}" --mode a2a --app-name agent "List all my open GitHub issues"
```

---

## Task 4. Create the Salesforce 2LO Auth Provider

### 4.1 Set Salesforce Credentials

```bash
export SF_DOMAIN="YOUR_SALESFORCE_MY_DOMAIN"
export SF_CLIENT_ID="YOUR_CONSUMER_KEY"
read -rs SF_CLIENT_SECRET && echo
```

### 4.2 Create `salesforce-2lo-auth-provider` (Solution)

```bash
gcloud alpha agent-identity auth-providers create salesforce-2lo-auth-provider \
  --project="${PROJECT_ID}" \
  --location="${LOCATION}" \
  --two-legged-oauth-client-id="${SF_CLIENT_ID}" \
  --two-legged-oauth-client-secret="${SF_CLIENT_SECRET}" \
  --two-legged-oauth-token-endpoint="https://${SF_DOMAIN}/services/oauth2/token"
```

### 4.3 Verify and Export URI

```bash
gcloud alpha agent-identity auth-providers list \
  --project="${PROJECT_ID}" \
  --location="${LOCATION}"

export SALESFORCE_AUTH_PROVIDER_URI="projects/${PROJECT_ID}/locations/${LOCATION}/authProviders/salesforce-2lo-auth-provider"
echo "${SALESFORCE_AUTH_PROVIDER_URI}"
```

---

## Task 5. Update the Salesforce Agent to Use the Auth Provider

### 5.1 Complete `~/agents/salesforce-agent/app/tools.py` (Solution)

See [`agents/salesforce-agent/app/tools.py`](agents/salesforce-agent/app/tools.py) for the complete solved file:

- **TODO 1**:
  ```python
  CredentialManager.register_auth_provider(GcpAuthProvider())
  salesforce_auth_config = AuthConfig(
      auth_scheme=GcpAuthProviderScheme(name=SALESFORCE_AUTH_PROVIDER_URI)
  )
  ```
- **TODO 2**:
  ```python
  def search_salesforce(query: str, credential: AuthCredential) -> dict:
      ...
      access_token = _extract_token(credential)
  ```
- **TODO 3**:
  ```python
  return AuthenticatedFunctionTool(
      func=search_salesforce, auth_config=salesforce_auth_config
  )
  ```

### 5.2 Update `app/agent.py`, `app/salesforce_client.py`, `.env`, and `pyproject.toml`

See [`agents/salesforce-agent/app/agent.py`](agents/salesforce-agent/app/agent.py) and [`agents/salesforce-agent/app/salesforce_client.py`](agents/salesforce-agent/app/salesforce_client.py).

Update `.env` and `pyproject.toml`:

```bash
cd ~/agents/salesforce-agent
cat << EOF > .env
GOOGLE_CLOUD_PROJECT=${PROJECT_ID}
GOOGLE_CLOUD_LOCATION=global
GOOGLE_GENAI_USE_VERTEXAI=True
MODEL=gemini-3.5-flash
SALESFORCE_DOMAIN=${SF_DOMAIN}
SALESFORCE_AUTH_PROVIDER_URI=projects/${PROJECT_ID}/locations/${LOCATION}/authProviders/salesforce-2lo-auth-provider
EOF

sed -i 's/google-adk\[gcp\]/google-adk[gcp,agent-identity]/' pyproject.toml
uv lock
```

### 5.3 Redeploy to Cloud Run

```bash
cd ~/agents/salesforce-agent
agents-cli deploy --project "${PROJECT_ID}" --region "${REGION}" \
  --no-confirm-project --no-wait \
  --update-env-vars "$(grep -v '^#' .env | grep -v '^$' | grep -v '^GOOGLE_CLOUD_PROJECT' | paste -sd,)"

agents-cli deploy --status
```

### 5.4 Grant the Service Account Access to the Auth Provider (Solution)

```bash
export SF_SA=$(gcloud run services describe salesforce-agent --region "${REGION}" \
  --format='value(spec.template.spec.serviceAccountName)')
echo "${SF_SA}"

gcloud alpha agent-identity auth-providers add-iam-policy-binding salesforce-2lo-auth-provider \
  --project="${PROJECT_ID}" \
  --location="${LOCATION}" \
  --role="roles/agentidentity.user" \
  --member="serviceAccount:${SF_SA}"

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SF_SA}" \
  --role="roles/serviceusage.serviceUsageConsumer"

gcloud alpha agent-identity auth-providers add-iam-policy-binding salesforce-2lo-auth-provider \
  --project="${PROJECT_ID}" \
  --location="${LOCATION}" \
  --role="roles/agentidentity.user" \
  --member="user:$(gcloud config get-value account)"
```

### 5.5 Test the Deployed Salesforce Agent

```bash
gcloud run services update salesforce-agent --region="${REGION}" --no-iap

export SF_URL=$(gcloud run services describe salesforce-agent --region "${REGION}" --format='value(status.url)')
agents-cli run --url "${SF_URL}" --mode a2a "Search for any architecture decision records about timeouts."
```
