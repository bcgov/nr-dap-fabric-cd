#!/bin/bash

set -e

PREFIX="vt"
ENVIRONMENT="dev"
FILE_PATH=""
REPO=""

show_help() {
    cat << EOF
Usage: $(basename "$0") [options]

Reads GitHub repository variables with a specific prefix and environment,
then writes them to a Fabric-formatted variables.json file.

Options:
    -p, --prefix PREFIX       Variable prefix to filter (default: vt)
    -e, --env ENVIRONMENT     Environment to filter (default: dev)
    -f, --file PATH          Path to variables.json file (required)
    -r, --repo REPO          GitHub repository (owner/repo format)
    -h, --help               Show this help message

Examples:
    $(basename "$0") -f ./variables.json
    $(basename "$0") -p prod -e production -f /path/to/variables.json
    $(basename "$0") -p vt -e dev -f ./config/variables.json -r owner/repo

Note: This script requires GitHub CLI (gh) to be installed and authenticated.
EOF
    exit 0
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--prefix)
                PREFIX="$2"
                shift 2
                ;;
            -e|--env)
                ENVIRONMENT="$2"
                shift 2
                ;;
            -f|--file)
                FILE_PATH="$2"
                shift 2
                ;;
            -r|--repo)
                REPO="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                ;;
            *)
                echo "Unknown option: $1" >&2
                echo "Use -h or --help for usage information" >&2
                exit 1
                ;;
        esac
    done
}

validate_file_path() {
    if [[ -z "$FILE_PATH" ]]; then
        echo "Error: File path is required. Use -f or --file to specify the path." >&2
        echo "Use -h or --help for usage information" >&2
        exit 1
    fi
}

build_github_command() {
    local cmd="gh variable list"
    if [[ -n "$REPO" ]]; then
        cmd="$cmd --repo $REPO"
    fi
    echo "$cmd"
}

fetch_filtered_variables() {
    local gh_cmd=$(build_github_command)
    eval "$gh_cmd" | grep "^${PREFIX}_${ENVIRONMENT}_" || true
}

strip_prefix_from_name() {
    local name=$1
    echo "${name#${PREFIX}_${ENVIRONMENT}_}"
}

escape_json_value() {
    local value=$1
    echo "$value" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed 's/$/\\n/' | tr -d '\n' | sed 's/\\n$//'
}

add_variable_to_json() {
    local json_vars=$1
    local name=$2
    local value=$3
    
    echo "$json_vars" | jq --arg name "$name" --arg value "$value" \
        '. += [{
            "name": $name,
            "note": "",
            "type": "String",
            "value": $value
        }]'
}

process_variables() {
    local filtered_vars=$1
    local json_vars="[]"
    
    while IFS=$'\t' read -r name value updated; do
        if [[ -n "$name" ]]; then
            local clean_name=$(strip_prefix_from_name "$name")
            local escaped_value=$(escape_json_value "$value")
            json_vars=$(add_variable_to_json "$json_vars" "$clean_name" "$escaped_value")
            echo "  Processing: $clean_name" >&2
        fi
    done <<< "$filtered_vars"
    
    echo "$json_vars"
}

create_fabric_json() {
    local variables=$1
    jq -n --argjson variables "$variables" \
        '{
            "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/variableLibrary/definition/variables/1.0.0/schema.json",
            "variables": $variables
        }'
}

read_existing_variables() {
    if [[ -f "$FILE_PATH" ]]; then
        echo "Reading existing variables from file..." >&2
        jq -r '.variables // []' "$FILE_PATH" 2>/dev/null || echo "[]"
    else
        echo "[]"
    fi
}

merge_variables() {
    local existing_vars=$1
    local new_vars=$2
    
    # Create a combined array that updates existing variables and adds new ones
    jq -n --argjson existing "$existing_vars" --argjson new "$new_vars" '
        # Start with existing variables
        $existing as $base |
        # For each new variable, create a map for quick lookup
        ($new | map({(.name): .})) as $new_map |
        # Update existing variables or keep as-is
        ($base | map(
            if ($new_map[.name]) then
                $new_map[.name]
            else
                .
            end
        )) as $updated |
        # Find new variables that weren'\''t in existing
        ($new | map(select(.name as $n | ($base | map(.name) | index($n)) == null))) as $additions |
        # Combine updated and additions
        $updated + $additions
    '
}

ensure_directory_exists() {
    local dir_path=$(dirname "$FILE_PATH")
    if [[ ! -d "$dir_path" ]]; then
        echo "Creating directory: $dir_path" >&2
        mkdir -p "$dir_path"
    fi
}

write_to_file() {
    local json=$1
    echo "$json" > "$FILE_PATH"
}

display_summary() {
    local variable_count=$1
    local updated_count=$2
    local added_count=$3
    local unchanged_count=$4
    
    echo "" >&2
    echo "✓ Successfully wrote variables to: $FILE_PATH" >&2
    echo "  Total variables: $variable_count" >&2
    if [[ $updated_count -gt 0 ]] || [[ $added_count -gt 0 ]] || [[ $unchanged_count -gt 0 ]]; then
        echo "  Updated: $updated_count" >&2
        echo "  Added: $added_count" >&2
        echo "  Unchanged: $unchanged_count" >&2
    fi
}

main() {
    parse_arguments "$@"
    validate_file_path
    
    echo "Fetching variables from GitHub..." >&2
    echo "Prefix: $PREFIX" >&2
    echo "Environment: $ENVIRONMENT" >&2
    echo "Output file: $FILE_PATH" >&2
    
    local filtered_vars=$(fetch_filtered_variables)
    
    if [[ -z "$filtered_vars" ]]; then
        echo "Warning: No variables found with prefix '${PREFIX}_${ENVIRONMENT}_'" >&2
        if [[ ! -f "$FILE_PATH" ]]; then
            echo "Creating empty variables.json file..." >&2
            local final_json=$(create_fabric_json "[]")
            ensure_directory_exists
            write_to_file "$final_json"
            display_summary 0 0 0 0
        else
            echo "Keeping existing file unchanged." >&2
            local existing_count=$(jq '.variables | length' "$FILE_PATH")
            echo "" >&2
            echo "✓ File unchanged: $FILE_PATH" >&2
            echo "  Total variables: $existing_count" >&2
        fi
        return 0
    fi
    
    # Read existing variables if file exists
    local existing_vars=$(read_existing_variables)
    
    # Process new variables from GitHub
    local new_vars=$(process_variables "$filtered_vars")
    
    # Merge existing and new variables
    echo "Merging variables..." >&2
    local merged_vars=$(merge_variables "$existing_vars" "$new_vars")
    
    # Calculate statistics
    local existing_count=$(echo "$existing_vars" | jq 'length')
    local new_count=$(echo "$new_vars" | jq 'length')
    local total_count=$(echo "$merged_vars" | jq 'length')
    local added_count=$((total_count - existing_count))
    local updated_count=$((new_count - added_count))
    local unchanged_count=$((existing_count - updated_count))
    
    # Ensure counts don't go negative (in case of edge cases)
    [[ $added_count -lt 0 ]] && added_count=0
    [[ $unchanged_count -lt 0 ]] && unchanged_count=0
    
    local final_json=$(create_fabric_json "$merged_vars")
    
    ensure_directory_exists
    write_to_file "$final_json"
    display_summary "$total_count" "$updated_count" "$added_count" "$unchanged_count"
}

main "$@"