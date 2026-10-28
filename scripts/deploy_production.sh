#!/usr/bin/env bash
# =============================================================================
# deploy_production.sh
# End-to-End Production Deployment for Agent Identity Foundations
# =============================================================================
# Provisions:
#   1. Required Google Cloud APIs & Reasoning Engine Service Agent IAM roles
#   2. Agent Identity Auth Manager Providers:
#      - github-mcp-auth-provider (API Key)
#      - salesforce-2lo-auth-provider (2-Legged OAuth / Client Credentials)
#   3. github-agent on Vertex AI Agent Runtime with SPIFFE Agent Identity
#   4. salesforce-agent on Cloud Run with Service Account ADC Identity
#   5. Least-privilege IAM bindings (roles/agentidentity.user + telemetry/model)
#   6. End-to-end A2A verification queries against both deployed agents
# =============================================================================

set -euo pipefail

export PATH="${HOME}/.local/bin:${PATH}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
LOCATION="${LOCATION:-us-central1}"
REGION="${REGION:-us-central1}"

if [[ -z "${PROJECT_ID}" ]]; then
  read -rp "Enter Google Cloud Project ID: " PROJECT_ID
fi

gcloud config set project "${PROJECT_ID}"
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
ORGANIZATION_ID="$(gcloud projects get-ancestors "${PROJECT_ID}" --format=json | jq -r '.[] | select(.type=="organization") | .id')"
USER_EMAIL="$(gcloud config get-value account 2>/dev/null || true)"

echo "==> Target Project : ${PROJECT_ID} (${PROJECT_NUMBER})"
echo "==> Organization   : ${ORGANIZATION_ID}"
echo "==> Location/Region: ${LOCATION} / ${REGION}"
echo

# -----------------------------------------------------------------------------
# 1. Collect Credentials for Auth Providers
# -----------------------------------------------------------------------------
if [[ -z "${GITHUB_PAT:-}" ]]; then
  read -rsp "Enter GitHub Personal Access Token (repo, read:org): " GITHUB_PAT
  echo
fi

if [[ -z "${SF_DOMAIN:-}" ]]; then
  read -rp "Enter Salesforce My Domain (e.g. yourorg.develop.my.salesforce.com): " SF_DOMAIN
fi
SF_DOMAIN="${SF_DOMAIN#https://}"
SF_DOMAIN="${SF_DOMAIN#http://}"
SF_DOMAIN="${SF_DOMAIN%%/}"

if [[ -z "${SF_CLIENT_ID:-}" ]]; then
  read -rp "Enter Salesforce Connected App Consumer Key (Client ID): " SF_CLIENT_ID
fi

if [[ -z "${SF_CLIENT_SECRET:-}" ]]; then
  read -rsp "Enter Salesforce Connected App Consumer Secret: " SF_CLIENT_SECRET
  echo
fi

# -----------------------------------------------------------------------------
# 2. Enable APIs & Configure Reasoning Engine Service Agent
# -----------------------------------------------------------------------------
echo "==> Enabling required Google Cloud APIs..."
gcloud services enable \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  agentidentity.googleapis.com \
  agentidentitycredentials.googleapis.com \
  aiplatform.googleapis.com \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  logging.googleapis.com \
  cloudtrace.googleapis.com \
  --project="${PROJECT_ID}"

gcloud beta services identity create --service=aiplatform.googleapis.com --project="${PROJECT_ID}" >/dev/null 2>&1 || true

RE_SA="service-${PROJECT_NUMBER}@gcp-sa-aiplatform-re.iam.gserviceaccount.com"
for ROLE in roles/aiplatform.user roles/logging.logWriter roles/cloudtrace.agent; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${RE_SA}" \
    --role="${ROLE}" \
    --condition=None >/dev/null
done

# -----------------------------------------------------------------------------
# 3. Create or Update Auth Providers in Agent Identity Auth Manager
# -----------------------------------------------------------------------------
echo "==> Provisioning github-mcp-auth-provider..."
if gcloud alpha agent-identity auth-providers describe github-mcp-auth-provider \
     --project="${PROJECT_ID}" --location="${LOCATION}" >/dev/null 2>&1; then
  gcloud alpha agent-identity auth-providers update github-mcp-auth-provider \
    --project="${PROJECT_ID}" \
    --location="${LOCATION}" \
    --api-key="${GITHUB_PAT}"
else
  gcloud alpha agent-identity auth-providers create github-mcp-auth-provider \
    --project="${PROJECT_ID}" \
    --location="${LOCATION}" \
    --api-key="${GITHUB_PAT}"
fi
unset GITHUB_PAT

echo "==> Provisioning salesforce-2lo-auth-provider..."
if gcloud alpha agent-identity auth-providers describe salesforce-2lo-auth-provider \
     --project="${PROJECT_ID}" --location="${LOCATION}" >/dev/null 2>&1; then
  gcloud alpha agent-identity auth-providers update salesforce-2lo-auth-provider \
    --project="${PROJECT_ID}" \
    --location="${LOCATION}" \
    --two-legged-oauth-client-id="${SF_CLIENT_ID}" \
    --two-legged-oauth-client-secret="${SF_CLIENT_SECRET}" \
    --two-legged-oauth-token-endpoint="https://${SF_DOMAIN}/services/oauth2/token"
else
  gcloud alpha agent-identity auth-providers create salesforce-2lo-auth-provider \
    --project="${PROJECT_ID}" \
    --location="${LOCATION}" \
    --two-legged-oauth-client-id="${SF_CLIENT_ID}" \
    --two-legged-oauth-client-secret="${SF_CLIENT_SECRET}" \
    --two-legged-oauth-token-endpoint="https://${SF_DOMAIN}/services/oauth2/token"
fi
unset SF_CLIENT_SECRET

export GITHUB_AUTH_PROVIDER_URI="projects/${PROJECT_ID}/locations/${LOCATION}/authProviders/github-mcp-auth-provider"
export SALESFORCE_AUTH_PROVIDER_URI="projects/${PROJECT_ID}/locations/${LOCATION}/authProviders/salesforce-2lo-auth-provider"

# -----------------------------------------------------------------------------
# 4. Deploy GitHub Agent to Vertex AI Agent Runtime with SPIFFE Identity
# -----------------------------------------------------------------------------
echo "==> Preparing and deploying github-agent to Vertex AI Agent Runtime..."
cd "${REPO_ROOT}/agents/github-agent"
cat << EOF > .env
GOOGLE_CLOUD_PROJECT=${PROJECT_ID}
GOOGLE_CLOUD_LOCATION=global
GOOGLE_GENAI_USE_VERTEXAI=True
MODEL=gemini-3.5-flash
GITHUB_MCP_URL=https://api.githubcopilot.com/mcp/
GITHUB_AUTH_PROVIDER_URI=${GITHUB_AUTH_PROVIDER_URI}
EOF

chmod +x ./deploy_with_identity.sh
REGION="${REGION}" \
A2A_APP_NAME="agent" \
AUTH_PROVIDER_NAME="github-mcp-auth-provider" \
DISPLAY_NAME="github-agent-v2" \
./deploy_with_identity.sh

# Resolve the deployed engine ID and effective SPIFFE identity
GITHUB_ENGINE_NAME="$(curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(next((e['name'] for e in d.get('reasoningEngines',[]) if e.get('displayName')=='github-agent-v2'), ''))")"
export GITHUB_ENGINE_ID="$(basename "${GITHUB_ENGINE_NAME}")"
EFFECTIVE_IDENTITY="$(curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://${REGION}-aiplatform.googleapis.com/v1beta1/${GITHUB_ENGINE_NAME}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('spec',{}).get('effectiveIdentity',''))")"
export GITHUB_AGENT_IDENTITY="principal://${EFFECTIVE_IDENTITY}"
export GITHUB_AGENT_URL="https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${GITHUB_ENGINE_ID}"

echo "==> Granting ${GITHUB_AGENT_IDENTITY} access to github-mcp-auth-provider..."
gcloud alpha agent-identity auth-providers add-iam-policy-binding github-mcp-auth-provider \
  --project="${PROJECT_ID}" \
  --location="${LOCATION}" \
  --role="roles/agentidentity.user" \
  --member="${GITHUB_AGENT_IDENTITY}"

if [[ -n "${USER_EMAIL}" ]]; then
  gcloud alpha agent-identity auth-providers add-iam-policy-binding github-mcp-auth-provider \
    --project="${PROJECT_ID}" \
    --location="${LOCATION}" \
    --role="roles/agentidentity.user" \
    --member="user:${USER_EMAIL}"
fi

# -----------------------------------------------------------------------------
# 5. Deploy Salesforce Agent to Cloud Run
# -----------------------------------------------------------------------------
echo "==> Preparing and deploying salesforce-agent to Cloud Run..."
cd "${REPO_ROOT}/agents/salesforce-agent"
cat << EOF > .env
GOOGLE_CLOUD_PROJECT=${PROJECT_ID}
GOOGLE_CLOUD_LOCATION=global
GOOGLE_GENAI_USE_VERTEXAI=True
MODEL=gemini-3.5-flash
SALESFORCE_DOMAIN=${SF_DOMAIN}
SALESFORCE_AUTH_PROVIDER_URI=${SALESFORCE_AUTH_PROVIDER_URI}
EOF

uv lock
agents-cli deploy --project "${PROJECT_ID}" --region "${REGION}" \
  --no-confirm-project \
  --max-instances 4 \
  --update-env-vars "$(grep -v '^#' .env | grep -v '^$' | grep -v '^GOOGLE_CLOUD_PROJECT' | paste -sd,)"

export SF_SA="$(gcloud run services describe salesforce-agent --region "${REGION}" \
  --format='value(spec.template.spec.serviceAccountName)')"

echo "==> Granting serviceAccount:${SF_SA} access to salesforce-2lo-auth-provider..."
gcloud alpha agent-identity auth-providers add-iam-policy-binding salesforce-2lo-auth-provider \
  --project="${PROJECT_ID}" \
  --location="${LOCATION}" \
  --role="roles/agentidentity.user" \
  --member="serviceAccount:${SF_SA}"

for ROLE in roles/serviceusage.serviceUsageConsumer roles/aiplatform.user roles/logging.logWriter roles/cloudtrace.agent; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SF_SA}" \
    --role="${ROLE}" \
    --condition=None >/dev/null
done

if [[ -n "${USER_EMAIL}" ]]; then
  gcloud alpha agent-identity auth-providers add-iam-policy-binding salesforce-2lo-auth-provider \
    --project="${PROJECT_ID}" \
    --location="${LOCATION}" \
    --role="roles/agentidentity.user" \
    --member="user:${USER_EMAIL}"
fi

gcloud run services update salesforce-agent --region="${REGION}" --no-iap
export SF_URL="$(gcloud run services describe salesforce-agent --region "${REGION}" --format='value(status.url)')"

echo
echo "============================================================================="
echo "Deployment Complete!"
echo "  GitHub Agent URL     : ${GITHUB_AGENT_URL}"
echo "  GitHub SPIFFE ID     : ${GITHUB_AGENT_IDENTITY}"
echo "  Salesforce Agent URL : ${SF_URL}"
echo "  Salesforce SA        : ${SF_SA}"
echo "============================================================================="
