# --- Add specific user as workspace admin using FABRIC API ---
ADMIN_EMAIL="${WORKSPACE_ADMIN_EMAIL:?WORKSPACE_ADMIN_EMAIL not set}"
WORKSPACE_ID="${WS_ID:?WS_ID for target workspace is not set}"

echo ">> Adding ${ADMIN_EMAIL} as Admin to Fabric workspace (${WORKSPACE_ID})"

# Get Fabric token (reuse if you already have one, or fetch fresh)
FABRIC_TOKEN=$(az account get-access-token \
  --resource https://api.fabric.microsoft.com \
  --query accessToken -o tsv)

# Resolve the user's Object ID (AAD GUID) from their email
# USER_OBJECT_ID=$(az ad user show --id "$ADMIN_EMAIL" --query id -o tsv 2>/dev/null || \
#   { echo "❌ Could not resolve AAD objectId for ${ADMIN_EMAIL}. Is the user in your tenant?" >&2; exit 1; })


echo $ADMIN_EMAIL

# The role assignment ID in Fabric is always the user's objectId (for user principals)
ROLE_ASSIGNMENT_ID="${ADMIN_EMAIL}"


ADD_RESP=$(curl -s -X POST \
  -H "Authorization: Bearer ${FABRIC_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
        \"principal\": {
          \"id\": \"${ADMIN_EMAIL}\",
          \"type\": \"User\"
        },
        \"role\": \"Admin\"
      }" \
  "https://api.fabric.microsoft.com/v1/workspaces/${WORKSPACE_ID}/roleAssignments")

if echo "$ADD_RESP" | jq -e '.error' > /dev/null 2>&1; then
  ERROR_CODE=$(echo "$ADD_RESP" | jq -r '.error.code')

  # These codes mean "already exists" – that's fine, we just ensured the role is Admin
  if [[ "$ERROR_CODE" == "Conflict" || "$ERROR_CODE" == "ItemAlreadyExists" ]]; then
    echo ">> User ${ADMIN_EMAIL} already has a role assignment – ensuring it's Admin"

    curl -s -X POST \
      -H "Authorization: Bearer ${FABRIC_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{
            \"principal\": {
              \"id\": \"${USER_OBJECT_ID}\",
              \"type\": \"User\"
            },
            \"role\": \"Admin\"
          }" \
      "https://api.fabric.microsoft.com/v1/workspaces/${WORKSPACE_ID}/roleAssignments" > /dev/null
    
    echo ">> ${ADMIN_EMAIL} confirmed as Admin"
  else
    echo "❌ Failed to assign Admin role to ${ADMIN_EMAIL}" >&2
    echo "$ADD_RESP" >&2
    exit 1
  fi
else
  echo ">> ${ADMIN_EMAIL} successfully added as Admin"
fi