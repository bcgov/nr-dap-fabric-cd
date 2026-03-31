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

initialize_and_sync() {
    local ws_id="$1"
    local token="$2"

    echo "Checking git status..." >&2
    local status_resp=$(curl -s \
        -H "Authorization: Bearer ${token}" \
        "https://api.fabric.microsoft.com/v1/workspaces/${ws_id}/git/status")

    local required_action=$(echo "$status_resp" | jq -r '.requiredAction // empty')
    local workspace_head=$(echo "$status_resp"  | jq -r '.workspaceHead  // empty')
    local remote_hash=$(echo "$status_resp"     | jq -r '.remoteCommitHash // empty')

    echo "ℹ requiredAction=${required_action}, workspaceHead=${workspace_head:-null}, remoteCommitHash=${remote_hash:-null}" >&2

    # ── Case 1: already initialized and in sync ──────────────────
    if [[ -z "$required_action" || "$required_action" == "None" ]]; then
        echo "✅ Workspace already in sync — nothing to do" >&2
        return 0
    fi

    # ── Case 2: never initialized (workspaceHead is empty/null) ──
    if [[ -z "$workspace_head" ]]; then
        echo "Initializing git connection (first-time sync)..." >&2

        local init_resp=$(curl -w "\n%{http_code}" -s -X POST \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d '{"initializationStrategy": "PreferRemote"}' \
            "https://api.fabric.microsoft.com/v1/workspaces/${ws_id}/git/initializeConnection")

        local init_code=$(echo "$init_resp" | tail -n1)
        local init_body=$(echo "$init_resp" | sed '$d')

        if [[ ! "$init_code" =~ ^2[0-9]{2}$ ]]; then
            echo "❌ initializeConnection failed (HTTP $init_code):" >&2
            echo "$init_body" >&2
            exit 1
        fi

        echo "✅ initializeConnection succeeded (HTTP $init_code)" >&2

        # Re-fetch status to get workspaceHead now that init is done
        status_resp=$(curl -s \
            -H "Authorization: Bearer ${token}" \
            "https://api.fabric.microsoft.com/v1/workspaces/${ws_id}/git/status")

        required_action=$(echo "$status_resp" | jq -r '.requiredAction // empty')
        workspace_head=$(echo "$status_resp"  | jq -r '.workspaceHead  // empty')
        remote_hash=$(echo "$status_resp"     | jq -r '.remoteCommitHash // empty')

        echo "ℹ post-init status: requiredAction=${required_action}, workspaceHead=${workspace_head:-null}" >&2

        # If already in sync after init, we are done
        if [[ -z "$required_action" || "$required_action" == "None" ]]; then
            echo "✅ Workspace in sync after init — nothing more to do" >&2
            return 0
        fi
    fi

    # ── Case 3: initialized but needs UpdateFromGit ───────────────
    if [[ "$required_action" == "UpdateFromGit" ]]; then
        if [[ -z "$remote_hash" ]]; then
            echo "❌ UpdateFromGit required but remoteCommitHash is missing" >&2
            exit 1
        fi

        echo "Performing UpdateFromGit (remoteCommitHash=${remote_hash}, workspaceHead=${workspace_head:-null})..." >&2

        local update_payload
        if [[ -n "$workspace_head" ]]; then
            update_payload=$(jq -n \
                --arg remote "$remote_hash" \
                --arg head "$workspace_head" \
                '{"remoteCommitHash": $remote, "workspaceHead": $head, "conflictResolution": {"conflictResolutionType": "Workspace", "conflictResolutionPolicy": "PreferRemote"}}')
        else
            update_payload=$(jq -n \
                --arg remote "$remote_hash" \
                '{"remoteCommitHash": $remote, "conflictResolution": {"conflictResolutionType": "Workspace", "conflictResolutionPolicy": "PreferRemote"}}')
        fi

        local update_resp=$(curl -w "\n%{http_code}" -s -X POST \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$update_payload" \
            "https://api.fabric.microsoft.com/v1/workspaces/${ws_id}/git/updateFromGit")

        local update_code=$(echo "$update_resp" | tail -n1)
        local update_body=$(echo "$update_resp" | sed '$d')

        if [[ "$update_code" =~ ^2[0-9]{2}$ ]]; then
            echo "✅ UpdateFromGit succeeded (HTTP $update_code)" >&2
        else
            echo "❌ UpdateFromGit failed (HTTP $update_code):" >&2
            echo "$update_body" >&2
            exit 1
        fi

        return 0
    fi

    echo "⚠️  Unhandled requiredAction='${required_action}' — skipping sync" >&2
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
    echo "workspace_name=$NAME" >> "$GITHUB_OUTPUT"
    
    connect_to_git "$WS_ID" "$FABRIC_TOKEN"
    initialize_and_sync "$WS_ID" "$FABRIC_TOKEN"
    
    echo "" >&2
    echo "All done! Fabric workspace ready." >&2
    echo "https://app.fabric.microsoft.com/groups/${WS_ID}" >&2
}

main "$@"