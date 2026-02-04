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
echo "Workspace: ${NAME}"
echo "Repository: ${REPO_OWNER}/${REPO_NAME}"
echo "Branch: ${BRANCH}"
echo "══════════════════════════════════════════════════════════════"

# ══════════════════════════════════════════════════════════════
# Authentication
# ══════════════════════════════════════════════════════════════

authenticate_azure() {
    echo "Logging into Azure..."
    az login --service-principal \
        --username "$CLIENT_ID" \
        --password "$CLIENT_SECRET" \
        --tenant "$TENANT_ID" \
        --allow-no-subscriptions \
        --output none
}

get_fabric_token() {
    echo "Fetching Fabric token..."
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
    
    echo "Creating workspace '${name}'..."
    
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
    echo "✅ Created workspace ${ws_id}"
    echo "$ws_id"
}

# ══════════════════════════════════════════════════════════════
# Git Integration
# ══════════════════════════════════════════════════════════════

build_git_payload() {
    jq -n \
        --arg owner "$REPO_OWNER" \
        --arg project "$REPO_NAME" \
        --arg repo "$REPO_NAME" \
        --arg branch "$BRANCH" \
        --arg connId "$FABRIC_CONNECTION_ID" \
        '{
            gitProviderDetails: {
                gitProviderType: "GitHub",
                ownerName: $owner,
                projectName: $project,
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
    
    echo "Connecting workspace to GitHub..."
    echo "Connection ID: ${FABRIC_CONNECTION_ID}"
    
    local json_payload=$(build_git_payload)
    
    local http_response=$(curl -w "\n%{http_code}" -s -X POST \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "$json_payload" \
        "https://api.fabric.microsoft.com/v1/workspaces/${ws_id}/git/connect")
    
    local http_code=$(echo "$http_response" | tail -n1)
    local connect_resp=$(echo "$http_response" | sed '$d')
    
    if [[ "$http_code" =~ ^2[0-9]{2}$ ]]; then
        echo "✅ Successfully connected to Git repository"
    elif [[ -n "$connect_resp" ]]; then
        local error_code=$(echo "$connect_resp" | jq -r '.errorCode // .error.code // empty' 2>/dev/null || echo "")
        
        if [[ "$error_code" == "WorkspaceAlreadyConnectedToGit" || 
              "$error_code" == "GitIntegrationAlreadyConnected" || 
              "$error_code" == "GitConnectionAlreadyExists" ]]; then
            echo "⚠️  Git integration already exists (skipping)"
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
    local fabric_token=$(get_fabric_token)
    
    local ws_id=$(get_workspace_id "$NAME" "$fabric_token")
    
    if [[ -z "$ws_id" || "$ws_id" == "null" ]]; then
        ws_id=$(create_workspace "$NAME" "$CAPACITY_ID" "$fabric_token")
    else
        echo "✅ Re-using existing workspace ${ws_id}"
    fi
    
    echo "workspace_id=$ws_id" >> "$GITHUB_OUTPUT"
    
    connect_to_git "$ws_id" "$fabric_token"
    
    echo ""
    echo "✅ Fabric workspace ready"
    echo "   https://app.fabric.microsoft.com/groups/${ws_id}"
}

main "$@"