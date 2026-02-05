#!/usr/bin/env bash
set -euo pipefail

# ══════════════════════════════════════════════════════════════
# Configuration & Validation
# ══════════════════════════════════════════════════════════════

BRANCH="${BRANCH_NAME:-${GITHUB_REF_NAME}}"
PREFIX="${WS_PREFIX:?WS_PREFIX is required}"
CAPACITY_ID="${CAPACITY_ID:?CAPACITY_ID is required}"
CLIENT_ID="${AZURE_CLIENT_ID:?AZURE_CLIENT_ID is required}"
CLIENT_SECRET="${AZURE_CLIENT_SECRET:?AZURE_CLIENT_SECRET is required}"
TENANT_ID="${AZURE_TENANT_ID:?AZURE_TENANT_ID is required}"
FABRIC_CONNECTION_ID="${FABRIC_CONNECTION_ID:?FABRIC_CONNECTION_ID is required}"

REPO_FULL="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY env var missing}"
REPO_OWNER="${REPO_FULL%%/*}"
REPO_NAME="${REPO_FULL#*/}"

SAFE_BRANCH="${BRANCH//\//-}"
NAME="${PREFIX}-${SAFE_BRANCH}"

echo "══════════════════════════════════════════════════════════════"
echo "Target Workspace: '${NAME}'"
echo "Repo: ${REPO_OWNER}/${REPO_NAME} (Branch: ${BRANCH})"
echo "══════════════════════════════════════════════════════════════"

# ══════════════════════════════════════════════════════════════
# Authentication
# ══════════════════════════════════════════════════════════════

authenticate_azure() {
    echo "Logging into Azure via Service Principal..." >&2
    az login --service-principal \
        --username "$CLIENT_ID" \
        --password "$CLIENT_SECRET" \
        --tenant "$TENANT_ID" \
        --allow-no-subscriptions \
        --output none
}

get_fabric_token() {
    echo "Fetching Fabric Access Token..." >&2
    az account get-access-token \
        --resource https://api.fabric.microsoft.com \
        --query accessToken \
        -o tsv
}

# ══════════════════════════════════════════════════════════════
# Workspace Operations
# ══════════════════════════════════════════════════════════════

get_workspace_id() {
    local ws_name="$1"
    local token="$2"
    
    curl -s -H "Authorization: Bearer ${token}" \
        "https://api.fabric.microsoft.com/v1/workspaces" | \
        jq -r --arg name "$ws_name" '.value[] | select(.displayName == $name) | .id'
}

create_workspace() {
    local name="$1"
    local capacity="$2"
    local token="$3"
    
    echo "Workspace not found. Creating '${name}' on capacity ${capacity}..." >&2
    
    local http_response=$(curl -w "\n%{http_code}" -s -X POST \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"displayName\":\"${name}\",\"capacityId\":\"${capacity}\"}" \
        "https://api.fabric.microsoft.com/v1/workspaces")
    
    local http_code=$(echo "$http_response" | tail -n1)
    local create_resp=$(echo "$http_response" | sed '$d')
    
    if [[ ! "$http_code" =~ ^2[0-9]{2}$ ]]; then
        echo "❌ Failed to create workspace (HTTP $http_code):" >&2
        echo "$create_resp" >&2
        exit 1
    fi
    
    local ws_id=$(echo "$create_resp" | jq -r '.id')
    echo "✅ Created workspace ${ws_id}" >&2
    echo "$ws_id"
}

# ══════════════════════════════════════════════════════════════
# Git Integration
# ══════════════════════════════════════════════════════════════

build_git_payload() {
    jq -n \
        --arg owner "$REPO_OWNER" \
        --arg repo "$REPO_NAME" \
        --arg branch "$BRANCH" \
        --arg connId "$FABRIC_CONNECTION_ID" \
        '{
            gitProviderDetails: {
                gitProviderType: "GitHub",
                ownerName: $owner,
                repositoryName: $repo,
                branchName: $branch,
                directoryName: "/"
            },
            myGitCredentials: {
                source: "ConfiguredConnection",
                connectionId: $connId
            }
        }'
}

connect_to_git() {
    local ws_id="$1"
    local token="$2"
    
    echo "Connecting workspace to GitHub Repository..." >&2
    echo "Connection ID: ${FABRIC_CONNECTION_ID}" >&2
    
    local json_payload=$(build_git_payload)
    
    local http_response=$(curl -w "\n%{http_code}" -s -X POST \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "$json_payload" \
        "https://api.fabric.microsoft.com/v1/workspaces/${ws_id}/git/connect")
    
    local http_code=$(echo "$http_response" | tail -n1)
    local connect_resp=$(echo "$http_response" | sed '$d')
    
    if [[ "$http_code" =~ ^2[0-9]{2}$ ]]; then
        echo "✅ Successfully connected to Git repository" >&2
    elif [[ -n "$connect_resp" ]]; then
        local error_code=$(echo "$connect_resp" | jq -r '.errorCode // .error.code // empty' 2>/dev/null || echo "")
        
        if [[ "$error_code" == "WorkspaceAlreadyConnectedToGit" || 
              "$error_code" == "GitIntegrationAlreadyConnected" || 
              "$error_code" == "GitConnectionAlreadyExists" ]]; then
            echo "⚠️  Git integration already exists (Skipping)" >&2
        else
            echo "❌ Failed to connect Git (HTTP $http_code):" >&2
            echo "$connect_resp" >&2
            exit 1
        fi
    else
        echo "❌ Failed to connect Git - received empty response" >&2
        exit 1
    fi
}

# ══════════════════════════════════════════════════════════════
# Main Execution
# ══════════════════════════════════════════════════════════════

main() {
    authenticate_azure
    FABRIC_TOKEN=$(get_fabric_token)
    
    WS_ID=$(get_workspace_id "$NAME" "$FABRIC_TOKEN")
    
    if [[ -z "$WS_ID" || "$WS_ID" == "null" ]]; then
        WS_ID=$(create_workspace "$NAME" "$CAPACITY_ID" "$FABRIC_TOKEN")
    else
        echo "✅ Re-using existing workspace ${WS_ID}" >&2
    fi
    
    echo "workspace_id=$WS_ID" >> "$GITHUB_OUTPUT"
    
    connect_to_git "$WS_ID" "$FABRIC_TOKEN"
    
    echo "" >&2
    echo "All done! Fabric workspace ready." >&2
    echo "https://app.fabric.microsoft.com/groups/${WS_ID}" >&2
}

main "$@"