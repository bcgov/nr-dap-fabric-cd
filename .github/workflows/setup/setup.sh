#!/bin/bash
#===============================================================================
# GitHub Actions Setup Script - Fixed Variable Handling
#===============================================================================

set -u # Error on unset variables (Removed -e to handle variable errors manually)

# Initialize variables
REPO_FULL=""
AZURE_TENANT_ID=""
AZURE_SUBSCRIPTION_ID=""
AZURE_CLIENT_ID=""
AZURE_CLIENT_SECRET=""
FABRIC_CONNECTION_ID=""
WORKSPACE_ADMIN_ID=""
DEV_CAPACITY_ID=""
TEST_CAPACITY_ID=""
PROD_CAPACITY_ID=""
DEV_WORKSPACE_ID=""
TEST_WORKSPACE_ID=""
PROD_WORKSPACE_ID=""
SKIP_INTERACTIVE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

# Parse Arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--repo) REPO_FULL="$2"; shift 2 ;;
        --tenant-id) AZURE_TENANT_ID="$2"; shift 2 ;;
        --subscription-id) AZURE_SUBSCRIPTION_ID="$2"; shift 2 ;;
        --client-id) AZURE_CLIENT_ID="$2"; shift 2 ;;
        --client-secret) AZURE_CLIENT_SECRET="$2"; shift 2 ;;
        --fabric-conn) FABRIC_CONNECTION_ID="$2"; shift 2 ;;
        --admin-id) WORKSPACE_ADMIN_ID="$2"; shift 2 ;;
        --dev-cap) DEV_CAPACITY_ID="$2"; shift 2 ;;
        --test-cap) TEST_CAPACITY_ID="$2"; shift 2 ;;
        --prod-cap) PROD_CAPACITY_ID="$2"; shift 2 ;;
        --dev-ws) DEV_WORKSPACE_ID="$2"; shift 2 ;;
        --test-ws) TEST_WORKSPACE_ID="$2"; shift 2 ;;
        --prod-ws) PROD_WORKSPACE_ID="$2"; shift 2 ;;
        --yes) SKIP_INTERACTIVE=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $1"; }

check_prerequisites() {
    log_info "Checking prerequisites..."
    command -v gh >/dev/null 2>&1 || { log_error "gh missing"; exit 1; }
    command -v jq >/dev/null 2>&1 || { log_error "jq missing"; exit 1; }
    
    if ! gh auth status >/dev/null 2>&1; then
        log_error "Not authenticated. Run: gh auth login"
        exit 1
    fi

    if [[ -z "$REPO_FULL" ]]; then
        read -p "Enter Repository (e.g., user/repo): " REPO_FULL
    fi

    log_info "Targeting Repo: $REPO_FULL"
}

set_gh_secret() {
    local name=$1
    local value=$2
    if [[ -n "$value" ]]; then
        # Secrets usually overwrite fine
        printf "%s" "$value" | gh secret set "$name" -R "$REPO_FULL" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            log_success "Set Secret: $name"
        else
            log_error "Failed to set Secret: $name"
        fi
    fi
}

set_gh_variable() {
    local name=$1
    local value=$2
    
    if [[ -n "$value" ]]; then
        # Capture error output
        OUTPUT=$(gh variable set "$name" --body "$value" -R "$REPO_FULL" 2>&1)
        EXIT_CODE=$?

        if [ $EXIT_CODE -eq 0 ]; then
            log_success "Set Variable: $name"
        else
            # If failed, check if it's because it exists (older gh CLI versions)
            # In newer versions, set overwrites. In older, it fails. 
            # We assume failure needs attention or manual fix if strict.
            log_error "Failed to set Variable: $name"
            echo "    Error: $OUTPUT"
        fi
    else
        log_warning "Skipping Variable $name (Empty value)"
    fi
}

apply_config() {
    log_info "Generating Credentials..."
    AZURE_CREDENTIALS=$(jq -n \
        --arg clientId "$AZURE_CLIENT_ID" \
        --arg clientSecret "$AZURE_CLIENT_SECRET" \
        --arg subscriptionId "$AZURE_SUBSCRIPTION_ID" \
        --arg tenantId "$AZURE_TENANT_ID" \
        '{clientId: $clientId, clientSecret: $clientSecret, subscriptionId: $subscriptionId, tenantId: $tenantId}')

    log_info "Applying Secrets..."
    set_gh_secret "AZURE_CREDENTIALS" "$AZURE_CREDENTIALS"
    set_gh_secret "AZURE_TENANT_ID" "$AZURE_TENANT_ID"
    set_gh_secret "AZURE_CLIENT_ID" "$AZURE_CLIENT_ID"
    set_gh_secret "AZURE_CLIENT_SECRET" "$AZURE_CLIENT_SECRET"

    log_info "Applying Variables..."
    set_gh_variable "DEV_CAPACITY_ID" "$DEV_CAPACITY_ID"
    set_gh_variable "TEST_CAPACITY_ID" "$TEST_CAPACITY_ID"
    set_gh_variable "PROD_CAPACITY_ID" "$PROD_CAPACITY_ID"
    
    set_gh_variable "DEV_WORKSPACE_ID" "$DEV_WORKSPACE_ID"
    set_gh_variable "TEST_WORKSPACE_ID" "$TEST_WORKSPACE_ID"
    set_gh_variable "PROD_WORKSPACE_ID" "$PROD_WORKSPACE_ID"
    
    set_gh_variable "FABRIC_CONNECTION_ID" "$FABRIC_CONNECTION_ID"
    set_gh_variable "WORKSPACE_ADMIN_ID" "$WORKSPACE_ADMIN_ID"
}

verify_results() {
    echo ""
    echo "---------------------------------------------------"
    log_info "Verifying Saved Variables in GitHub..."
    echo "---------------------------------------------------"
    # List variables to prove they are there
    gh variable list -R "$REPO_FULL"
    echo "---------------------------------------------------"
    echo "If you see the variables above, they are saved."
    echo "Check the 'Variables' tab here: https://github.com/${REPO_FULL}/settings/variables/actions"
}

main() {
    check_prerequisites
    apply_config
    verify_results
}

main "$@"