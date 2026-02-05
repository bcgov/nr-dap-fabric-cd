WS_NAME="${WS_ID:?No workspace name provided}"
echo "Workspace name: $WS_NAME"

# Fabric-scoped token
TOKEN=$(az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)

# Get list of workspaces and find ID by name
WORKSPACES=$(curl -s -H "Authorization: Bearer $TOKEN" "https://api.fabric.microsoft.com/v1/workspaces")
WS_ID=$(echo "$WORKSPACES" | jq -r --arg name "$WS_NAME" '.value[] | select(.displayName == $name) | .id')

if [ -z "$WS_ID" ]; then
  echo "Workspace with name '$WS_NAME' not found."
  exit 1
fi

echo "Workspace ID: $WS_ID"

# Optional: disconnect Git first (recommended)
curl -X POST -H "Authorization: Bearer $TOKEN" \
  "https://api.fabric.microsoft.com/v1/workspaces/${WS_ID}/git/disconnect" || echo "Already disconnected or not connected"

# Delete (add ?force=true if available in your tenant, otherwise ensure workspace is truly empty)
curl -X DELETE \
     -H "Authorization: Bearer $TOKEN" \
     -d '' \
     --fail \
     --silent \
     "https://api.fabric.microsoft.com/v1/workspaces/${WS_ID}?forceDeletion=true" \
     && echo "Workspace $WS_NAME successfully deleted" \
     || echo "Failed to delete workspace $WS_NAME