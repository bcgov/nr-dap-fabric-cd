#!/usr/bin/env bash
set -euo pipefail

# ══════════════════════════════════════════════════════════════
# 1. Inputs & Environment Setup
# ══════════════════════════════════════════════════════════════

# These should be set in the workflow 'env' or passed as inputs
BRANCH="${BRANCH_NAME:-${GITHUB_REF_NAME}}" # Default to current git branch
PREFIX="${WS_PREFIX:?WS_PREFIX is required}"
CAPACITY_ID="${CAPACITY_ID:?CAPACITY_ID is required}"

# Service Principal Credentials (Passed via env)
CLIENT_ID="${AZURE_CLIENT_ID:?AZURE_CLIENT_ID is required}"
CLIENT_SECRET="${AZURE_CLIENT_SECRET:?AZURE_CLIENT_SECRET is required}"
TENANT_ID="${AZURE_TENANT_ID:?AZURE_TENANT_ID is required}"

# Connection ID for the GitHub connection created in Fabric Portal
FABRIC_CONNECTION_ID="${FABRIC_CONNECTION_ID:?FABRIC_CONNECTION_ID is required}"

# Parse GitHub Repository details (e.g., "owner/repo-name")
REPO_FULL="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY env var missing}"
REPO_OWNER="${REPO_FULL%%/*}"
REPO_NAME="${REPO_FULL#*/}"

# Construct Workspace Name
# Replace slashes in branch names with hyphens (e.g. feature/abc -> feature-abc)
SAFE_BRANCH="${BRANCH//\//-}"
NAME="${PREFIX}-${SAFE_BRANCH}"

echo "══════════════════════════════════════════════════════════════"
echo ">> Target Workspace: '${NAME}'"
echo ">> Repo: ${REPO_OWNER}/${REPO_NAME} (Branch: ${BRANCH})"
echo "══════════════════════════════════════════════════════════════"

# ══════════════════════════════════════════════════════════════
# 2. Authentication
# ══════════════════════════════════════════════════════════════

echo ">> Logging into Azure via Service Principal..."
az login --service-principal \
  --username "$CLIENT_ID" \
  --password "$CLIENT_SECRET" \
  --tenant "$TENANT_ID" \
  --allow-no-subscriptions \
  --output none

echo ">> Fetching Fabric Access Token..."
FABRIC_TOKEN=$(az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)

# ══════════════════════════════════════════════════════════════
# 3. Check / Create Workspace
# ══════════════════════════════════════════════════════════════

get_workspace_id() {
  local ws_name="$1"
  curl -s -H "Authorization: Bearer ${FABRIC_TOKEN}" \
    "https://api.fabric.microsoft.com/v1/workspaces" | \
    jq -r --arg name "$ws_name" '.value[] | select(.displayName == $name) | .id'
}

WS_ID=$(get_workspace_id "$NAME")

if [[ -z "$WS_ID" || "$WS_ID" == "null" ]]; then
  echo ">> Workspace not found. Creating '${NAME}' on capacity ${CAPACITY_ID}..."
  
  HTTP_RESPONSE=$(curl -w "\n%{http_code}" -s -X POST \
    -H "Authorization: Bearer ${FABRIC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"displayName\":\"${NAME}\",\"capacityId\":\"${CAPACITY_ID}\"}" \
    "https://api.fabric.microsoft.com/v1/workspaces")
  
  HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n1)
  CREATE_RESP=$(echo "$HTTP_RESPONSE" | sed '$d')
  
  if [[ ! "$HTTP_CODE" =~ ^2[0-9]{2}$ ]]; then
    echo "❌ Failed to create workspace (HTTP $HTTP_CODE):" >&2
    echo "$CREATE_RESP" >&2
    exit 1
  fi
  
  WS_ID=$(echo "$CREATE_RESP" | jq -r '.id')
  echo ">> ✅ Created workspace ${WS_ID}"
else
  echo ">> ✅ Re-using existing workspace ${WS_ID}"
fi

# Set GitHub Action Output Variable
echo "workspace_id=$WS_ID" >> "$GITHUB_OUTPUT"

# ══════════════════════════════════════════════════════════════
# 4. Connect to Git (GitHub)
# ══════════════════════════════════════════════════════════════

echo ">> Connecting workspace to GitHub Repository..."
echo ">> Connection ID: ${FABRIC_CONNECTION_ID}"

# Prepare JSON Payload for GitHub
# Note: gitProviderType is now "GitHub"
JSON_PAYLOAD=$(jq -n \
  --arg org "$REPO_OWNER" \
  --arg repo "$REPO_NAME" \
  --arg branch "$BRANCH" \
  --arg connId "$FABRIC_CONNECTION_ID" \
  '{
    gitProviderDetails: {
      gitProviderType: "GitHub",
      organizationName: $org,
      repositoryName: $repo,
      branchName: $branch,
      directoryName: "/"
    },
    myGitCredentials: {
      source: "ConfiguredConnection",
      connectionId: $connId
    }
  }')

HTTP_RESPONSE=$(curl -w "\n%{http_code}" -s -X POST \
  -H "Authorization: Bearer ${FABRIC_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$JSON_PAYLOAD" \
  "https://api.fabric.microsoft.com/v1/workspaces/${WS_ID}/git/connect")

HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n1)
CONNECT_RESP=$(echo "$HTTP_RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" =~ ^2[0-9]{2}$ ]]; then
  echo ">> ✅ Successfully connected to Git repository"
elif [[ -n "$CONNECT_RESP" ]]; then
  # Check for idempotency (already connected)
  ERROR_CODE=$(echo "$CONNECT_RESP" | jq -r '.errorCode // .error.code // empty' 2>/dev/null || echo "")
  
  if [[ "$ERROR_CODE" == "WorkspaceAlreadyConnectedToGit" || "$ERROR_CODE" == "GitIntegrationAlreadyConnected" || "$ERROR_CODE" == "GitConnectionAlreadyExists" ]]; then
    echo ">> ⚠️  Git integration already exists (Skipping)"
  else
    echo "❌ Failed to connect Git (HTTP $HTTP_CODE):" >&2
    echo "$CONNECT_RESP" >&2
    exit 1
  fi
else
  echo "❌ Failed to connect Git - received empty response" >&2
  exit 1
fi

# ══════════════════════════════════════════════════════════════
# 5. Final Success
# ══════════════════════════════════════════════════════════════
echo ">> All done! Fabric workspace ready."
echo ">> https://app.fabric.microsoft.com/groups/${WS_ID}"