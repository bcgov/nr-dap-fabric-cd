#!/usr/bin/env bash
set -euo pipefail

# ══════════════════════════════════════════════════════════════
# Configuration & Validation
# ══════════════════════════════════════════════════════════════

validate_required_vars() {
    local vars=(
        "WS_PREFIX"
        "CAPACITY_ID"
        "AZURE_CLIENT_ID"
        "AZURE_CLIENT_SECRET"
        "AZURE_TENANT_ID"
        "FABRIC_CONNECTION_ID"
        "GITHUB_REPOSITORY"
    )
    
    for var in "${vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            echo "❌ Required variable $var is not set" >&2
            exit 1
        fi
    done
}

parse_repository_info() {
    REPO_FULL="${GITHUB_REPOSITORY}"
    REPO_OWNER="${REPO_FULL%%/*}"
    REPO_NAME="${REPO_FULL#*/}"
}

construct_workspace_name() {
    local branch="${BRANCH_NAME:-${GITHUB_REF_NAME}}"
    local safe_branch="${branch//\//-}"
    echo "${WS_PREFIX}-${safe_branch}"
}

display_configuration() {
    local workspace_name=$1
    local branch="${BRANCH_NAME:-${GITHUB_REF_NAME}}"
    
    echo "══════════════════════════════════════════════════════════════"
    echo "Workspace: ${workspace_name}"
    echo "Repository: ${REPO_OWNER}/${REPO_NAME}"
    echo "Branch: ${branch}"
    echo "══════════════════════════════════════════════════════════════"
}

# ══════════════════════════════════════════════════════════════
# Authentication
# ══════════════════════════════════════════════════════════════

authenticate_azure() {
    echo "Logging into Azure..."
    az login --service-principal \
        --username "$AZURE_CLIENT_ID" \
        --password "$AZURE_CLIENT_SECRET" \
        --tenant "$AZURE_TENANT_ID" \
        --allow-no-subscriptions \
        --output none
}

get_fabric_token() {
    az account get-access-token \
        --resource https://api.fabric.microsoft.com \
        --query accessToken \
        -o tsv
}

# ══════════════════════════════════════════════════════════════
# Workspace Operations
# ══════════════════════════════════════════════════════════════

find_workspace_by_name() {
    local name=$1
    local token=$2
    
    curl -s \
        -H "Authorization: Bearer ${token}" \
        "https://api.fabric.microsoft.com/v1/workspaces" | \
        jq -r --arg name "$name" \
            '.value[] | select(.displayName == $name) | .id'
}

create_workspace() {
    local name=$1
    local capacity_id=$2
    local token=$3
    
    echo "Creating workspace '${name}'..."
    
    local response=$(curl -w "\n%{http_code}" -s -X POST \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"displayName\":\"${name}\",\"capacityId\":\"${capacity_id}\"}" \
        "https://api.fabric.microsoft.com/v1/workspaces")
    
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    if [[ ! "$http_code" =~ ^2[0-9]{2}$ ]]; then
        echo "❌ Failed to create workspace (HTTP ${http_code}):" >&2
        echo "$body" >&2
        exit 1
    fi
    
    echo "$body" | jq -r '.id'
}

get_or_create_workspace() {
    local name=$1
    local capacity_id=$2
    local token=$3
    
    local workspace_id=$(find_workspace_by_name "$name" "$token")
    
    if [[ -z "$workspace_id" || "$workspace_id" == "null" ]]; then
        workspace_id=$(create_workspace "$name" "$capacity_id" "$token")
        echo "✅ Created workspace: ${workspace_id}"
    else
        echo "✅ Using existing workspace: ${workspace_id}"
    fi
    
    echo "$workspace_id"
}

# ══════════════════════════════════════════════════════════════
# Git Integration
# ══════════════════════════════════════════════════════════════

build_git_payload() {
    local branch="${BRANCH_NAME:-${GITHUB_REF_NAME}}"
    
    jq -n \
        --arg owner "$REPO_OWNER" \
        --arg project "$REPO_NAME" \
        --arg repo "$REPO_NAME" \
        --arg branch "$branch" \
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

is_git_already_connected() {
    local error_code=$1
    
    case "$error_code" in
        "WorkspaceAlreadyConnectedToGit"|"GitIntegrationAlreadyConnected"|"GitConnectionAlreadyExists")
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

connect_workspace_to_git() {
    local workspace_id=$1
    local token=$2
    
    echo "Connecting workspace to Git..."
    
    local payload=$(build_git_payload)
    local response=$(curl -w "\n%{http_code}" -s -X POST \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "https://api.fabric.microsoft.com/v1/workspaces/${workspace_id}/git/connect")
    
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" =~ ^2[0-9]{2}$ ]]; then
        echo "✅ Connected to Git repository"
        return 0
    fi
    
    if [[ -n "$body" ]]; then
        local error_code=$(echo "$body" | jq -r '.errorCode // .error.code // empty' 2>/dev/null || echo "")
        
        if is_git_already_connected "$error_code"; then
            echo "⚠️  Git already connected (skipping)"
            return 0
        fi
        
        echo "❌ Failed to connect Git (HTTP ${http_code}):" >&2
        echo "$body" >&2
        exit 1
    fi
    
    echo "❌ Failed to connect Git - empty response" >&2
    exit 1
}

# ══════════════════════════════════════════════════════════════
# Output Handling
# ══════════════════════════════════════════════════════════════

set_github_output() {
    local workspace_id=$1
    echo "workspace_id=${workspace_id}" >> "$GITHUB_OUTPUT"
}

display_completion() {
    local workspace_id=$1
    echo ""
    echo "✅ Workspace ready"
    echo "   https://app.fabric.microsoft.com/groups/${workspace_id}"
}

# ══════════════════════════════════════════════════════════════
# Main Execution
# ══════════════════════════════════════════════════════════════

main() {
    validate_required_vars
    parse_repository_info
    
    local workspace_name=$(construct_workspace_name)
    display_configuration "$workspace_name"
    
    authenticate_azure
    local fabric_token=$(get_fabric_token)
    
    local workspace_id=$(get_or_create_workspace "$workspace_name" "$CAPACITY_ID" "$fabric_token")
    set_github_output "$workspace_id"
    
    connect_workspace_to_git "$workspace_id" "$fabric_token"
    
    display_completion "$workspace_id"
}

main "$@"