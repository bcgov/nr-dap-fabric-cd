#!/bin/bash
#./deployments/spn_evaluator.sh
#===============================================================================
# Fabric Service Principal Permission Tester
# Tests which API permissions are working for a given service principal
#===============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Default values
VERBOSE=false
OUTPUT_FORMAT="table"
FABRIC_API_URL="https://api.fabric.microsoft.com/v1"
POWER_BI_API_URL="https://api.powerbi.com/v1.0/myorg"
RUN_WRITE_TESTS=false
CLEANUP=true
TEST_PREFIX="__SPN_TEST_$(date +%s)__"

# Declare associative arrays for test results (must be at global scope)
declare -A TEST_RESULTS=()
declare -A TEST_DETAILS=()

# Track created resources for cleanup
declare -a CREATED_WORKSPACES=()
declare -a CREATED_DATASETS=()

#===============================================================================
# Helper Functions
#===============================================================================

print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║       Fabric Service Principal Permission Tester                  ║"
    echo "║                                                                   ║"
    echo "║  Tests API permissions for Microsoft Fabric Service Principals    ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Tests which Microsoft Fabric API permissions are working for a service principal.

OPTIONS:
    -t, --tenant-id      Azure AD Tenant ID (or set AZURE_TENANT_ID env var)
    -c, --client-id      Service Principal Client ID (or set AZURE_CLIENT_ID env var)
    -s, --client-secret  Service Principal Secret (or set AZURE_CLIENT_SECRET env var)
    -o, --output         Output format: table, json, csv (default: table)
    -w, --write-tests    Run write/create permission tests (creates temporary resources)
    --no-cleanup         Don't delete resources created during write tests
    -v, --verbose        Enable verbose output
    -h, --help           Show this help message

ENVIRONMENT VARIABLES:
    AZURE_TENANT_ID      Azure AD Tenant ID
    AZURE_CLIENT_ID      Service Principal Client ID
    AZURE_CLIENT_SECRET  Service Principal Client Secret

EXAMPLES:
    # Using command line arguments
    $(basename "$0") -t <tenant-id> -c <client-id> -s <client-secret>

    # Using environment variables
    export AZURE_TENANT_ID="your-tenant-id"
    export AZURE_CLIENT_ID="your-client-id"
    export AZURE_CLIENT_SECRET="your-client-secret"
    $(basename "$0")

    # Include write/create permission tests
    $(basename "$0") -w

    # JSON output
    $(basename "$0") -o json

EOF
    exit 0
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

# Helper function to display test result
show_test_result() {
    local status=$1
    local detail=$2
    
    if [[ "$OUTPUT_FORMAT" == "table" ]]; then
        case $status in
            "ALLOWED")
                echo -e "${GREEN}✓ ALLOWED${NC} $detail"
                ;;
            "FORBIDDEN"|"DENIED")
                echo -e "${RED}✗ DENIED${NC} $detail"
                ;;
            "UNAUTHORIZED")
                echo -e "${YELLOW}⚠ UNAUTH${NC} $detail"
                ;;
            "NO_CAPACITY")
                echo -e "${YELLOW}⚠ NO_CAP${NC} $detail"
                ;;
            *)
                echo -e "${YELLOW}? ${status}${NC} $detail"
                ;;
        esac
    fi
}

# Helper function to get first accessible workspace ID
get_first_workspace_id() {
    local token=$1
    
    local response
    response=$(curl -s "${FABRIC_API_URL}/workspaces" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" 2>/dev/null) || true
    
    local workspace_id=""
    workspace_id=$(echo "$response" | jq -r '.value[0].id // empty' 2>/dev/null) || true
    
    echo "$workspace_id"
}

# Helper function to get first accessible Power BI workspace ID
get_first_pbi_workspace_id() {
    local token=$1
    
    local response
    response=$(curl -s "${POWER_BI_API_URL}/groups" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" 2>/dev/null) || true
    
    local workspace_id=""
    workspace_id=$(echo "$response" | jq -r '.value[0].id // empty' 2>/dev/null) || true
    
    echo "$workspace_id"
}

#===============================================================================
# Authentication
#===============================================================================

get_access_token() {
    local resource=$1
    local token_url="https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token"
    
    log_verbose "Requesting token for resource: $resource"
    
    local response
    response=$(curl -s -X POST "$token_url" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "client_id=${CLIENT_ID}" \
        -d "client_secret=${CLIENT_SECRET}" \
        -d "scope=${resource}/.default" \
        -d "grant_type=client_credentials" 2>&1)
    
    local token
    token=$(echo "$response" | jq -r '.access_token // empty' 2>/dev/null)
    
    if [[ -z "$token" ]]; then
        local error_desc
        error_desc=$(echo "$response" | jq -r '.error_description // .error // "Unknown error"' 2>/dev/null)
        echo "ERROR:$error_desc"
        return 1
    fi
    
    echo "$token"
}

#===============================================================================
# API Testing Functions
#===============================================================================

test_api_endpoint() {
    local name=$1
    local url=$2
    local token=$3
    local method=${4:-GET}
    local expected_success=${5:-200}
    
    log_verbose "Testing: $name -> $url"
    
    # Show progress
    if [[ "$OUTPUT_FORMAT" == "table" ]]; then
        printf "  Testing: %-45s " "$name"
    fi
    
    local response
    local http_code
    local body
    local status="DENIED"
    local detail=""
    
    response=$(curl -s -w "\n%{http_code}" -X "$method" "$url" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" 2>&1) || true
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        status="ALLOWED"
        # Try to get count of items if available
        local count=""
        count=$(echo "$body" | jq -r '.value | length // empty' 2>/dev/null) || true
        if [[ -n "$count" ]]; then
            detail="($count items)"
        fi
    elif [[ "$http_code" == "401" ]]; then
        status="UNAUTHORIZED"
        detail="Token invalid or expired"
    elif [[ "$http_code" == "403" ]]; then
        status="FORBIDDEN"
        local error_msg=""
        error_msg=$(echo "$body" | jq -r '.error.message // .message // empty' 2>/dev/null) || true
        detail="${error_msg:0:50}"
    elif [[ "$http_code" == "404" ]]; then
        status="NOT_FOUND"
        detail="Endpoint or resource not found"
    else
        status="ERROR"
        detail="HTTP $http_code"
    fi
    
    # Store results
    TEST_RESULTS["$name"]="$status"
    TEST_DETAILS["$name"]="$detail"
    
    show_test_result "$status" "$detail"
    
    return 0
}

#===============================================================================
# Main Testing Logic
#===============================================================================

run_fabric_api_tests() {
    local token=$1
    
    echo ""
    echo -e "${BOLD}Testing Fabric API Permissions...${NC}"
    echo "─────────────────────────────────────────────────────────────────"
    
    # Workspace permissions
    test_api_endpoint "List Workspaces" "${FABRIC_API_URL}/workspaces" "$token"
    
    # Capacity permissions
    test_api_endpoint "List Capacities" "${FABRIC_API_URL}/capacities" "$token"
    
    # Items (general)
    test_api_endpoint "List Items (all types)" "${FABRIC_API_URL}/workspaces?includeItems=true" "$token"
    
    # Domains
    test_api_endpoint "List Domains" "${FABRIC_API_URL}/admin/domains" "$token"
    
    # Connections
    test_api_endpoint "List Connections" "${FABRIC_API_URL}/connections" "$token"
    
    # External Data Shares
    test_api_endpoint "List External Data Shares" "${FABRIC_API_URL}/admin/items/externalDataShares" "$token"
    
    # Tenant Settings (Admin)
    test_api_endpoint "Get Tenant Settings" "${FABRIC_API_URL}/admin/tenantsettings" "$token"
    
    # Get a workspace ID for workspace-scoped tests
    local workspace_id=""
    workspace_id=$(get_first_workspace_id "$token")
    
    if [[ -n "$workspace_id" ]]; then
        # Workspace-scoped item tests
        test_api_endpoint "List Dataflows" "${FABRIC_API_URL}/workspaces/${workspace_id}/dataflows" "$token"
        test_api_endpoint "List Lakehouses" "${FABRIC_API_URL}/workspaces/${workspace_id}/lakehouses" "$token"
        test_api_endpoint "List Notebooks" "${FABRIC_API_URL}/workspaces/${workspace_id}/notebooks" "$token"
        test_api_endpoint "List Semantic Models" "${FABRIC_API_URL}/workspaces/${workspace_id}/semanticModels" "$token"
        test_api_endpoint "List Reports (Fabric)" "${FABRIC_API_URL}/workspaces/${workspace_id}/reports" "$token"
        test_api_endpoint "List Data Pipelines" "${FABRIC_API_URL}/workspaces/${workspace_id}/dataPipelines" "$token"
        test_api_endpoint "List Warehouses" "${FABRIC_API_URL}/workspaces/${workspace_id}/warehouses" "$token"
        test_api_endpoint "List Eventstreams" "${FABRIC_API_URL}/workspaces/${workspace_id}/eventstreams" "$token"
        test_api_endpoint "List KQL Databases" "${FABRIC_API_URL}/workspaces/${workspace_id}/kqlDatabases" "$token"
        test_api_endpoint "List Spark Job Definitions" "${FABRIC_API_URL}/workspaces/${workspace_id}/sparkJobDefinitions" "$token"
    else
        log_warning "No accessible workspaces found - skipping workspace-scoped tests"
    fi
}

run_powerbi_api_tests() {
    local token=$1
    
    echo ""
    echo -e "${BOLD}Testing Power BI API Permissions...${NC}"
    echo "─────────────────────────────────────────────────────────────────"
    
    # Groups (Workspaces)
    test_api_endpoint "List Groups/Workspaces" "${POWER_BI_API_URL}/groups" "$token"
    
    # Datasets in My Workspace
    test_api_endpoint "List Datasets (My Workspace)" "${POWER_BI_API_URL}/datasets" "$token"
    
    # Reports in My Workspace
    test_api_endpoint "List Reports (My Workspace)" "${POWER_BI_API_URL}/reports" "$token"
    
    # Dashboards in My Workspace
    test_api_endpoint "List Dashboards (My Workspace)" "${POWER_BI_API_URL}/dashboards" "$token"
    
    # Apps
    test_api_endpoint "List Apps" "${POWER_BI_API_URL}/apps" "$token"
    
    # Gateways
    test_api_endpoint "List Gateways" "${POWER_BI_API_URL}/gateways" "$token"
    
    # Pipelines
    test_api_endpoint "List Pipelines" "${POWER_BI_API_URL}/pipelines" "$token"
    
    # Imports
    test_api_endpoint "List Imports" "${POWER_BI_API_URL}/imports" "$token"
    
    # Capacities
    test_api_endpoint "List Capacities (PBI)" "${POWER_BI_API_URL}/capacities" "$token"
    
    # Available Features
    test_api_endpoint "Get Available Features" "${POWER_BI_API_URL}/availableFeatures" "$token"
    
    # Get a workspace ID for workspace-scoped tests
    local workspace_id=""
    workspace_id=$(get_first_pbi_workspace_id "$token")
    
    if [[ -n "$workspace_id" ]]; then
        # Workspace-scoped tests
        test_api_endpoint "List Datasets (Workspace)" "${POWER_BI_API_URL}/groups/${workspace_id}/datasets" "$token"
        test_api_endpoint "List Reports (Workspace)" "${POWER_BI_API_URL}/groups/${workspace_id}/reports" "$token"
        test_api_endpoint "List Dashboards (Workspace)" "${POWER_BI_API_URL}/groups/${workspace_id}/dashboards" "$token"
        test_api_endpoint "List Dataflows (Workspace)" "${POWER_BI_API_URL}/groups/${workspace_id}/dataflows" "$token"
        test_api_endpoint "List Users (Workspace)" "${POWER_BI_API_URL}/groups/${workspace_id}/users" "$token"
    else
        log_warning "No accessible workspaces found - skipping workspace-scoped PBI tests"
    fi
}

run_admin_api_tests() {
    local token=$1
    
    echo ""
    echo -e "${BOLD}Testing Admin API Permissions...${NC}"
    echo "─────────────────────────────────────────────────────────────────"
    
    # Admin Workspaces
    test_api_endpoint "Admin: List Workspaces" "${POWER_BI_API_URL}/admin/groups?\$top=1" "$token"
    
    # Tenant Keys
    test_api_endpoint "Admin: Get Encryption Keys" "${POWER_BI_API_URL}/admin/tenantKeys" "$token"
    
    # Catalog - Datasets
    test_api_endpoint "Admin: Get Datasets" "${POWER_BI_API_URL}/admin/datasets?\$top=1" "$token"
    
    # Catalog - Reports
    test_api_endpoint "Admin: Get Reports" "${POWER_BI_API_URL}/admin/reports?\$top=1" "$token"
    
    # Catalog - Dashboards
    test_api_endpoint "Admin: Get Dashboards" "${POWER_BI_API_URL}/admin/dashboards?\$top=1" "$token"
    
    # Catalog - Dataflows
    test_api_endpoint "Admin: Get Dataflows" "${POWER_BI_API_URL}/admin/dataflows?\$top=1" "$token"
    
    # Capacity
    test_api_endpoint "Admin: Get Capacities" "${POWER_BI_API_URL}/admin/capacities" "$token"
    
    # Refreshables
    test_api_endpoint "Admin: List Refreshables" "${POWER_BI_API_URL}/admin/capacities/refreshables" "$token"
    
    # Activity Events
    test_api_endpoint "Admin: Get Activity Events" "${POWER_BI_API_URL}/admin/activityevents" "$token"
    
    # Modified Workspaces
    test_api_endpoint "Admin: Get Modified Workspaces" "${POWER_BI_API_URL}/admin/workspaces/modified" "$token"
    
    # Apps
    test_api_endpoint "Admin: Get Apps" "${POWER_BI_API_URL}/admin/apps?\$top=1" "$token"
    
    # Imports
    test_api_endpoint "Admin: Get Imports" "${POWER_BI_API_URL}/admin/imports?\$top=1" "$token"
}

#===============================================================================
# Write/Create Test Functions
#===============================================================================

test_create_workspace() {
    local token=$1
    local workspace_name="${TEST_PREFIX}Workspace"
    
    log_verbose "Testing: Create Workspace -> ${POWER_BI_API_URL}/groups"
    
    # Show progress
    if [[ "$OUTPUT_FORMAT" == "table" ]]; then
        printf "  Testing: %-45s " "Create Workspace"
    fi
    
    local payload
    payload=$(cat <<EOF
{
    "name": "${workspace_name}"
}
EOF
)
    
    local response
    local http_code
    local body
    
    response=$(curl -s -w "\n%{http_code}" -X POST "${POWER_BI_API_URL}/groups" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1) || true
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    local status="DENIED"
    local detail=""
    
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        status="ALLOWED"
        local workspace_id=""
        workspace_id=$(echo "$body" | jq -r '.id // empty' 2>/dev/null) || true
        if [[ -n "$workspace_id" ]]; then
            CREATED_WORKSPACES+=("$workspace_id")
            detail="Created: ${workspace_id:0:8}..."
        fi
    elif [[ "$http_code" == "401" ]]; then
        status="UNAUTHORIZED"
        detail="Token invalid or expired"
    elif [[ "$http_code" == "403" ]]; then
        status="FORBIDDEN"
        local error_msg=""
        error_msg=$(echo "$body" | jq -r '.error.message // .message // empty' 2>/dev/null) || true
        detail="${error_msg:0:50}"
    else
        status="ERROR"
        local error_msg=""
        error_msg=$(echo "$body" | jq -r '.error.message // .message // empty' 2>/dev/null) || true
        detail="HTTP $http_code: ${error_msg:0:30}"
    fi
    
    TEST_RESULTS["Create Workspace"]="$status"
    TEST_DETAILS["Create Workspace"]="$detail"
    
    show_test_result "$status" "$detail"
}

test_create_workspace_fabric() {
    local token=$1
    local workspace_name="${TEST_PREFIX}FabricWS"
    
    log_verbose "Testing: Create Workspace (Fabric API) -> ${FABRIC_API_URL}/workspaces"
    
    # Show progress
    if [[ "$OUTPUT_FORMAT" == "table" ]]; then
        printf "  Testing: %-45s " "Create Workspace (Fabric)"
    fi
    
    local payload
    payload=$(cat <<EOF
{
    "displayName": "${workspace_name}"
}
EOF
)
    
    local response
    local http_code
    local body
    
    response=$(curl -s -w "\n%{http_code}" -X POST "${FABRIC_API_URL}/workspaces" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1) || true
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    local status="DENIED"
    local detail=""
    
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        status="ALLOWED"
        local workspace_id=""
        workspace_id=$(echo "$body" | jq -r '.id // empty' 2>/dev/null) || true
        if [[ -n "$workspace_id" ]]; then
            CREATED_WORKSPACES+=("$workspace_id")
            detail="Created: ${workspace_id:0:8}..."
        fi
    elif [[ "$http_code" == "401" ]]; then
        status="UNAUTHORIZED"
        detail="Token invalid or expired"
    elif [[ "$http_code" == "403" ]]; then
        status="FORBIDDEN"
        local error_msg=""
        error_msg=$(echo "$body" | jq -r '.error.message // .message // empty' 2>/dev/null) || true
        detail="${error_msg:0:50}"
    else
        status="ERROR"
        local error_msg=""
        error_msg=$(echo "$body" | jq -r '.error.message // .message // empty' 2>/dev/null) || true
        detail="HTTP $http_code: ${error_msg:0:30}"
    fi
    
    TEST_RESULTS["Create Workspace (Fabric)"]="$status"
    TEST_DETAILS["Create Workspace (Fabric)"]="$detail"
    
    show_test_result "$status" "$detail"
}

test_create_dataset() {
    local token=$1
    local dataset_name="${TEST_PREFIX}Dataset"
    
    log_verbose "Testing: Create Dataset (Push) -> ${POWER_BI_API_URL}/datasets"
    
    # Show progress
    if [[ "$OUTPUT_FORMAT" == "table" ]]; then
        printf "  Testing: %-45s " "Create Dataset (Push)"
    fi
    
    # Minimal push dataset definition
    local payload
    payload=$(cat <<EOF
{
    "name": "${dataset_name}",
    "defaultMode": "Push",
    "tables": [
        {
            "name": "TestTable",
            "columns": [
                {
                    "name": "Id",
                    "dataType": "Int64"
                },
                {
                    "name": "Name",
                    "dataType": "String"
                }
            ]
        }
    ]
}
EOF
)
    
    local response
    local http_code
    local body
    
    response=$(curl -s -w "\n%{http_code}" -X POST "${POWER_BI_API_URL}/datasets" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1) || true
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    local status="DENIED"
    local detail=""
    
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        status="ALLOWED"
        local dataset_id=""
        dataset_id=$(echo "$body" | jq -r '.id // empty' 2>/dev/null) || true
        if [[ -n "$dataset_id" ]]; then
            CREATED_DATASETS+=("$dataset_id")
            detail="Created: ${dataset_id:0:8}..."
        fi
    elif [[ "$http_code" == "401" ]]; then
        status="UNAUTHORIZED"
        detail="Token invalid or expired"
    elif [[ "$http_code" == "403" ]]; then
        status="FORBIDDEN"
        local error_msg=""
        error_msg=$(echo "$body" | jq -r '.error.message // .message // empty' 2>/dev/null) || true
        detail="${error_msg:0:50}"
    else
        status="ERROR"
        local error_msg=""
        error_msg=$(echo "$body" | jq -r '.error.message // .message // empty' 2>/dev/null) || true
        detail="HTTP $http_code: ${error_msg:0:30}"
    fi
    
    TEST_RESULTS["Create Dataset (Push)"]="$status"
    TEST_DETAILS["Create Dataset (Push)"]="$detail"
    
    show_test_result "$status" "$detail"
}

test_create_dataset_in_workspace() {
    local token=$1
    local workspace_id=$2
    local dataset_name="${TEST_PREFIX}WSDataset"
    
    log_verbose "Testing: Create Dataset in Workspace -> ${POWER_BI_API_URL}/groups/${workspace_id}/datasets"
    
    # Show progress
    if [[ "$OUTPUT_FORMAT" == "table" ]]; then
        printf "  Testing: %-45s " "Create Dataset in Workspace"
    fi
    
    local payload
    payload=$(cat <<EOF
{
    "name": "${dataset_name}",
    "defaultMode": "Push",
    "tables": [
        {
            "name": "TestTable",
            "columns": [
                {
                    "name": "Id",
                    "dataType": "Int64"
                },
                {
                    "name": "Value",
                    "dataType": "Double"
                }
            ]
        }
    ]
}
EOF
)
    
    local response
    local http_code
    local body
    
    response=$(curl -s -w "\n%{http_code}" -X POST "${POWER_BI_API_URL}/groups/${workspace_id}/datasets" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1) || true
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    local status="DENIED"
    local detail=""
    
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        status="ALLOWED"
        local dataset_id=""
        dataset_id=$(echo "$body" | jq -r '.id // empty' 2>/dev/null) || true
        if [[ -n "$dataset_id" ]]; then
            # Store as workspace_id:dataset_id for cleanup
            CREATED_DATASETS+=("${workspace_id}:${dataset_id}")
            detail="Created: ${dataset_id:0:8}..."
        fi
    elif [[ "$http_code" == "401" ]]; then
        status="UNAUTHORIZED"
        detail="Token invalid or expired"
    elif [[ "$http_code" == "403" ]]; then
        status="FORBIDDEN"
        local error_msg=""
        error_msg=$(echo "$body" | jq -r '.error.message // .message // empty' 2>/dev/null) || true
        detail="${error_msg:0:50}"
    else
        status="ERROR"
        local error_msg=""
        error_msg=$(echo "$body" | jq -r '.error.message // .message // empty' 2>/dev/null) || true
        detail="HTTP $http_code: ${error_msg:0:30}"
    fi
    
    TEST_RESULTS["Create Dataset in Workspace"]="$status"
    TEST_DETAILS["Create Dataset in Workspace"]="$detail"
    
    show_test_result "$status" "$detail"
}

run_write_tests() {
    local pbi_token=$1
    local fabric_token=$2
    
    echo ""
    echo -e "${BOLD}Testing Write/Create Permissions...${NC}"
    echo -e "${YELLOW}(These tests create temporary resources)${NC}"
    echo "─────────────────────────────────────────────────────────────────"
    
    # Test creating workspace via Power BI API
    test_create_workspace "$pbi_token"
    
    # Test creating workspace via Fabric API
    test_create_workspace_fabric "$fabric_token"
    
    # Test creating dataset in "My Workspace"
    test_create_dataset "$pbi_token"
    
    # If we successfully created a workspace, test creating items in it
    if [[ ${#CREATED_WORKSPACES[@]} -gt 0 ]]; then
        local test_workspace="${CREATED_WORKSPACES[0]}"
        
        # Test creating dataset in workspace
        test_create_dataset_in_workspace "$pbi_token" "$test_workspace"
        
        # Test creating Lakehouse in workspace (Fabric API)
        test_create_lakehouse "$fabric_token" "$test_workspace"
        
        # Test creating Semantic Model in workspace (Fabric API)
        test_create_semantic_model "$fabric_token" "$test_workspace"
        
        # Test creating Notebook in workspace (Fabric API)
        test_create_notebook "$fabric_token" "$test_workspace"
        
        # Test adding workspace user/role assignment
        test_add_workspace_user "$pbi_token" "$test_workspace"
    fi
}

test_create_lakehouse() {
    local token=$1
    local workspace_id=$2
    local lakehouse_name="${TEST_PREFIX}Lakehouse"
    
    log_verbose "Testing: Create Lakehouse -> ${FABRIC_API_URL}/workspaces/${workspace_id}/lakehouses"
    
    # Show progress
    if [[ "$OUTPUT_FORMAT" == "table" ]]; then
        printf "  Testing: %-45s " "Create Lakehouse"
    fi
    
    local payload
    payload=$(cat <<EOF
{
    "displayName": "${lakehouse_name}"
}
EOF
)
    
    local response
    local http_code
    local body
    
    response=$(curl -s -w "\n%{http_code}" -X POST "${FABRIC_API_URL}/workspaces/${workspace_id}/lakehouses" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1) || true
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    local status="DENIED"
    local detail=""
    
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        status="ALLOWED"
        local item_id=""
        item_id=$(echo "$body" | jq -r '.id // empty' 2>/dev/null) || true
        detail="Created: ${item_id:0:8}..."
    elif [[ "$http_code" == "401" ]]; then
        status="UNAUTHORIZED"
        detail="Token invalid or expired"
    elif [[ "$http_code" == "403" ]]; then
        status="FORBIDDEN"
        local error_msg=""
        error_msg=$(echo "$body" | jq -r '.error.message // .message // empty' 2>/dev/null) || true
        detail="${error_msg:0:50}"
    elif [[ "$http_code" == "400" ]]; then
        # Check if it's a capacity issue (common for Lakehouses)
        local error_msg=""
        error_msg=$(echo "$body" | jq -r '.error.message // .message // empty' 2>/dev/null) || true
        if [[ "$error_msg" == *"capacity"* ]] || [[ "$error_msg" == *"Capacity"* ]]; then
            status="NO_CAPACITY"
            detail="Requires Fabric capacity"
        else
            status="ERROR"
            detail="HTTP $http_code: ${error_msg:0:30}"
        fi
    else
        status="ERROR"
        local error_msg=""
        error_msg=$(echo "$body" | jq -r '.error.message // .message // empty' 2>/dev/null) || true
        detail="HTTP $http_code: ${error_msg:0:30}"
    fi
    
    TEST_RESULTS["Create Lakehouse"]="$status"
    TEST_DETAILS["Create Lakehouse"]="$detail"
    
    show_test_result "$status" "$detail"
}

test_create_semantic_model() {
    local token=$1
    local workspace_id=$2
    local model_name="${TEST_PREFIX}SemanticModel"
    
    log_verbose "Testing: Create Semantic Model -> ${FABRIC_API_URL}/workspaces/${workspace_id}/semanticModels"
    
    # Show progress
    if [[ "$OUTPUT_FORMAT" == "table" ]]; then
        printf "  Testing: %-45s " "Create Semantic Model"
    fi
    
    local payload
    payload=$(cat <<EOF
{
    "displayName": "${model_name}"
}
EOF
)
    
    local response
    local http_code
    local body
    
    response=$(curl -s -w "\n%{http_code}" -X POST "${FABRIC_API_URL}/workspaces/${workspace_id}/semanticModels" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1) || true
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    local status="DENIED"
    local detail=""
    
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        status="ALLOWED"
        local item_id=""
        item_id=$(echo "$body" | jq -r '.id // empty' 2>/dev/null) || true
        detail="Created: ${item_id:0:8}..."
    elif [[ "$http_code" == "401" ]]; then
        status="UNAUTHORIZED"
        detail="Token invalid or expired"
    elif [[ "$http_code" == "403" ]]; then
        status="FORBIDDEN"
        local error_msg=""
        error_msg=$(echo "$body" | jq -r '.error.message // .message // empty' 2>/dev/null) || true
        detail="${error_msg:0:50}"
    else
        status="ERROR"
        local error_msg=""
        error_msg=$(echo "$body" | jq -r '.error.message // .message // empty' 2>/dev/null) || true
        detail="HTTP $http_code: ${error_msg:0:30}"
    fi
    
    TEST_RESULTS["Create Semantic Model"]="$status"
    TEST_DETAILS["Create Semantic Model"]="$detail"
    
    show_test_result "$status" "$detail"
}

test_create_notebook() {
    local token=$1
    local workspace_id=$2
    local notebook_name="${TEST_PREFIX}Notebook"
    
    log_verbose "Testing: Create Notebook -> ${FABRIC_API_URL}/workspaces/${workspace_id}/notebooks"
    
    # Show progress
    if [[ "$OUTPUT_FORMAT" == "table" ]]; then
        printf "  Testing: %-45s " "Create Notebook"
    fi
    
    local payload
    payload=$(cat <<EOF
{
    "displayName": "${notebook_name}"
}
EOF
)
    
    local response
    local http_code
    local body
    
    response=$(curl -s -w "\n%{http_code}" -X POST "${FABRIC_API_URL}/workspaces/${workspace_id}/notebooks" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1) || true
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    local status="DENIED"
    local detail=""
    
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        status="ALLOWED"
        local item_id=""
        item_id=$(echo "$body" | jq -r '.id // empty' 2>/dev/null) || true
        detail="Created: ${item_id:0:8}..."
    elif [[ "$http_code" == "401" ]]; then
        status="UNAUTHORIZED"
        detail="Token invalid or expired"
    elif [[ "$http_code" == "403" ]]; then
        status="FORBIDDEN"
        local error_msg=""
        error_msg=$(echo "$body" | jq -r '.error.message // .message // empty' 2>/dev/null) || true
        detail="${error_msg:0:50}"
    elif [[ "$http_code" == "400" ]]; then
        local error_msg=""
        error_msg=$(echo "$body" | jq -r '.error.message // .message // empty' 2>/dev/null) || true
        if [[ "$error_msg" == *"capacity"* ]] || [[ "$error_msg" == *"Capacity"* ]]; then
            status="NO_CAPACITY"
            detail="Requires Fabric capacity"
        else
            status="ERROR"
            detail="HTTP $http_code: ${error_msg:0:30}"
        fi
    else
        status="ERROR"
        local error_msg=""
        error_msg=$(echo "$body" | jq -r '.error.message // .message // empty' 2>/dev/null) || true
        detail="HTTP $http_code: ${error_msg:0:30}"
    fi
    
    TEST_RESULTS["Create Notebook"]="$status"
    TEST_DETAILS["Create Notebook"]="$detail"
    
    show_test_result "$status" "$detail"
}

test_add_workspace_user() {
    local token=$1
    local workspace_id=$2
    
    log_verbose "Testing: Add Workspace User -> ${POWER_BI_API_URL}/groups/${workspace_id}/users"
    
    # Show progress
    if [[ "$OUTPUT_FORMAT" == "table" ]]; then
        printf "  Testing: %-45s " "Add Workspace User"
    fi
    
    # We'll try to add a non-existent user (this tests the permission, not the actual add)
    local payload
    payload=$(cat <<EOF
{
    "emailAddress": "test-nonexistent-user@example.com",
    "groupUserAccessRight": "Viewer"
}
EOF
)
    
    local response
    local http_code
    local body
    
    response=$(curl -s -w "\n%{http_code}" -X POST "${POWER_BI_API_URL}/groups/${workspace_id}/users" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1) || true
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    local status="DENIED"
    local detail=""
    
    # Note: 400 with "user not found" means we have permission but user doesn't exist
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        status="ALLOWED"
        detail="Permission granted"
    elif [[ "$http_code" == "400" ]]; then
        local error_msg=""
        error_msg=$(echo "$body" | jq -r '.error.message // .message // empty' 2>/dev/null) || true
        if [[ "$error_msg" == *"not found"* ]] || [[ "$error_msg" == *"does not exist"* ]] || [[ "$error_msg" == *"invalid"* ]]; then
            status="ALLOWED"
            detail="Permission granted (test user invalid)"
        else
            status="ERROR"
            detail="HTTP $http_code: ${error_msg:0:30}"
        fi
    elif [[ "$http_code" == "401" ]]; then
        status="UNAUTHORIZED"
        detail="Token invalid or expired"
    elif [[ "$http_code" == "403" ]]; then
        status="FORBIDDEN"
        local error_msg=""
        error_msg=$(echo "$body" | jq -r '.error.message // .message // empty' 2>/dev/null) || true
        detail="${error_msg:0:50}"
    else
        status="ERROR"
        local error_msg=""
        error_msg=$(echo "$body" | jq -r '.error.message // .message // empty' 2>/dev/null) || true
        detail="HTTP $http_code: ${error_msg:0:30}"
    fi
    
    TEST_RESULTS["Add Workspace User"]="$status"
    TEST_DETAILS["Add Workspace User"]="$detail"
    
    show_test_result "$status" "$detail"
}

cleanup_resources() {
    local token=$1
    
    if [[ "$CLEANUP" != "true" ]]; then
        log_warning "Cleanup disabled. Created resources will remain."
        if [[ ${#CREATED_WORKSPACES[@]} -gt 0 ]]; then
            echo "  Workspaces: ${CREATED_WORKSPACES[*]}"
        fi
        if [[ ${#CREATED_DATASETS[@]} -gt 0 ]]; then
            echo "  Datasets: ${CREATED_DATASETS[*]}"
        fi
        return
    fi
    
    # Only show cleanup header if there's something to clean
    if [[ ${#CREATED_WORKSPACES[@]} -eq 0 ]] && [[ ${#CREATED_DATASETS[@]} -eq 0 ]]; then
        return
    fi
    
    echo ""
    echo -e "${BOLD}Cleaning up test resources...${NC}"
    echo "─────────────────────────────────────────────────────────────────"
    
    # Delete datasets first
    if [[ ${#CREATED_DATASETS[@]} -gt 0 ]]; then
        for dataset_entry in "${CREATED_DATASETS[@]}"; do
            if [[ "$dataset_entry" == *":"* ]]; then
                # Dataset in workspace
                local ws_id="${dataset_entry%%:*}"
                local ds_id="${dataset_entry##*:}"
                log_verbose "Deleting dataset $ds_id from workspace $ws_id"
                if curl -s -X DELETE "${POWER_BI_API_URL}/groups/${ws_id}/datasets/${ds_id}" \
                    -H "Authorization: Bearer $token" > /dev/null 2>&1; then
                    log_success "Deleted dataset: ${ds_id:0:8}..."
                else
                    log_warning "Failed to delete dataset: ${ds_id:0:8}..."
                fi
            else
                # Dataset in My Workspace
                log_verbose "Deleting dataset $dataset_entry"
                if curl -s -X DELETE "${POWER_BI_API_URL}/datasets/${dataset_entry}" \
                    -H "Authorization: Bearer $token" > /dev/null 2>&1; then
                    log_success "Deleted dataset: ${dataset_entry:0:8}..."
                else
                    log_warning "Failed to delete dataset: ${dataset_entry:0:8}..."
                fi
            fi
        done
    fi
    
    # Delete workspaces
    if [[ ${#CREATED_WORKSPACES[@]} -gt 0 ]]; then
        for workspace_id in "${CREATED_WORKSPACES[@]}"; do
            log_verbose "Deleting workspace $workspace_id"
            if curl -s -X DELETE "${POWER_BI_API_URL}/groups/${workspace_id}" \
                -H "Authorization: Bearer $token" > /dev/null 2>&1; then
                log_success "Deleted workspace: ${workspace_id:0:8}..."
            else
                log_warning "Failed to delete workspace: ${workspace_id:0:8}..."
            fi
        done
    fi
}

#===============================================================================
# Output Functions
#===============================================================================

print_results_table() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}                         TEST RESULTS SUMMARY                       ${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    local allowed=0
    local denied=0
    local errors=0
    
    # Count results
    for test_name in "${!TEST_RESULTS[@]}"; do
        local status="${TEST_RESULTS[$test_name]}"
        
        case $status in
            "ALLOWED")
                ((allowed++)) || true
                ;;
            "FORBIDDEN"|"DENIED")
                ((denied++)) || true
                ;;
            *)
                ((errors++)) || true
                ;;
        esac
    done
    
    echo -e "  ${GREEN}Allowed:${NC}  $allowed"
    echo -e "  ${RED}Denied:${NC}   $denied"
    echo -e "  ${YELLOW}Errors:${NC}   $errors"
    echo -e "  ${BLUE}Total:${NC}    $((allowed + denied + errors))"
    echo ""
}

print_results_json() {
    echo "{"
    echo '  "results": ['
    
    local first=true
    local test_names=("${!TEST_RESULTS[@]}")
    
    for test_name in "${test_names[@]}"; do
        if [[ "$first" != "true" ]]; then
            echo ","
        fi
        first=false
        
        local status="${TEST_RESULTS[$test_name]}"
        local detail="${TEST_DETAILS[$test_name]:-}"
        
        # Escape quotes in detail
        detail="${detail//\"/\\\"}"
        
        printf '    {"test": "%s", "status": "%s", "details": "%s"}' \
            "$test_name" "$status" "$detail"
    done
    
    echo ""
    echo "  ],"
    
    local allowed=0 denied=0 errors=0
    for status in "${TEST_RESULTS[@]}"; do
        case $status in
            "ALLOWED") ((allowed++)) || true ;;
            "FORBIDDEN"|"DENIED") ((denied++)) || true ;;
            *) ((errors++)) || true ;;
        esac
    done
    
    echo '  "summary": {'
    echo "    \"allowed\": $allowed,"
    echo "    \"denied\": $denied,"
    echo "    \"errors\": $errors,"
    echo "    \"total\": $((allowed + denied + errors))"
    echo "  }"
    echo "}"
}

print_results_csv() {
    echo "Test Name,Status,Details"
    local test_names=("${!TEST_RESULTS[@]}")
    
    for test_name in "${test_names[@]}"; do
        local status="${TEST_RESULTS[$test_name]}"
        local detail="${TEST_DETAILS[$test_name]:-}"
        # Escape quotes for CSV
        detail="${detail//\"/\"\"}"
        echo "\"$test_name\",\"$status\",\"$detail\""
    done | sort
}

#===============================================================================
# Main
#===============================================================================

main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -t|--tenant-id)
                TENANT_ID="$2"
                shift 2
                ;;
            -c|--client-id)
                CLIENT_ID="$2"
                shift 2
                ;;
            -s|--client-secret)
                CLIENT_SECRET="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_FORMAT="$2"
                shift 2
                ;;
            -w|--write-tests)
                RUN_WRITE_TESTS=true
                shift
                ;;
            --no-cleanup)
                CLEANUP=false
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done
    
    # Use environment variables as fallback
    TENANT_ID="${TENANT_ID:-${AZURE_TENANT_ID:-}}"
    CLIENT_ID="${CLIENT_ID:-${AZURE_CLIENT_ID:-}}"
    CLIENT_SECRET="${CLIENT_SECRET:-${AZURE_CLIENT_SECRET:-}}"
    

    if [[ "$OUTPUT_FORMAT" == "table" ]]; then
        print_banner
    fi
    
    # Validate required parameters
    if [[ -z "$TENANT_ID" || -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
        log_error "Missing required credentials!"
        echo ""
        echo "Please provide:"
        echo "  - Tenant ID (-t or AZURE_TENANT_ID)"
        echo "  - Client ID (-c or AZURE_CLIENT_ID)"
        echo "  - Client Secret (-s or AZURE_CLIENT_SECRET)"
        echo ""
        echo "Run '$(basename "$0") --help' for more information."
        exit 1
    fi
    
    # Check for required tools
    if ! command -v curl &> /dev/null; then
        log_error "curl is required but not installed."
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        log_error "jq is required but not installed."
        exit 1
    fi
    
    if [[ "$OUTPUT_FORMAT" == "table" ]]; then
        log_info "Tenant ID: ${TENANT_ID:0:8}...${TENANT_ID: -4}"
        log_info "Client ID: ${CLIENT_ID:0:8}...${CLIENT_ID: -4}"
        if [[ "$RUN_WRITE_TESTS" == "true" ]]; then
            log_info "Write Tests: ${GREEN}ENABLED${NC} (will create temporary resources)"
            if [[ "$CLEANUP" == "true" ]]; then
                log_info "Cleanup: ${GREEN}ENABLED${NC}"
            else
                log_warning "Cleanup: ${YELLOW}DISABLED${NC} (resources will remain)"
            fi
        fi
        echo ""
    fi
    
    # Get access tokens for different resources
    if [[ "$OUTPUT_FORMAT" == "table" ]]; then
        log_info "Authenticating with Azure AD..."
    fi
    
    # Fabric API token
    FABRIC_TOKEN=$(get_access_token "https://api.fabric.microsoft.com")
    if [[ "$FABRIC_TOKEN" == ERROR:* ]]; then
        log_error "Failed to get Fabric API token: ${FABRIC_TOKEN#ERROR:}"
        exit 1
    fi
    
    # Power BI API token
    PBI_TOKEN=$(get_access_token "https://analysis.windows.net/powerbi/api")
    if [[ "$PBI_TOKEN" == ERROR:* ]]; then
        log_error "Failed to get Power BI API token: ${PBI_TOKEN#ERROR:}"
        exit 1
    fi
    
    if [[ "$OUTPUT_FORMAT" == "table" ]]; then
        log_success "Authentication successful!"
    fi
    
    # Run tests
    run_fabric_api_tests "$FABRIC_TOKEN"
    run_powerbi_api_tests "$PBI_TOKEN"
    run_admin_api_tests "$PBI_TOKEN"
    
    # Run write tests if enabled
    if [[ "$RUN_WRITE_TESTS" == "true" ]]; then
        run_write_tests "$PBI_TOKEN" "$FABRIC_TOKEN"
        
        # Cleanup created resources
        cleanup_resources "$PBI_TOKEN"
    fi
    
    # Output results
    case $OUTPUT_FORMAT in
        json)
            print_results_json
            ;;
        csv)
            print_results_csv
            ;;
        table|*)
            print_results_table
            ;;
    esac
}

main "$@"