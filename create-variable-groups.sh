#!/bin/bash

set -e

PAT="$1"

if [[ -z "$PAT" ]]; then
  echo "❌ ERROR: Missing PAT"
  exit 1
fi

# Encode PAT for Basic Auth
ENCODED_PAT=$(printf ":%s" "$PAT" | base64 | tr -d '\n')
AUTH_HEADER="Authorization: Basic $ENCODED_PAT"

# Support both lowercase and uppercase for org/project
ORG="${org:-${ORG}}"
PROJECT="${project:-${PROJECT}}"

echo "🔍 org: $ORG"
echo "🔍 project: $PROJECT"

if [[ -z "$ORG" || -z "$PROJECT" ]]; then
  echo "❌ ERROR: org or project not defined"
  exit 1
fi

# Fetch project ID
PROJECT_API_URL="https://dev.azure.com/$ORG/_apis/projects/$PROJECT?api-version=7.1-preview.1"
PROJECT_ID=$(curl -s -H "$AUTH_HEADER" "$PROJECT_API_URL" | jq -r '.id')

if [[ "$PROJECT_ID" == "null" || -z "$PROJECT_ID" ]]; then
  echo "❌ ERROR: Failed to fetch project ID for $PROJECT"
  exit 1
fi

echo "✅ Found project ID: $PROJECT_ID"

echo "🔎 Checking environment for vgX variables..."
env | grep -Ei 'vg[0-9]+_name='

# Loop through vgX_name (case-insensitive)
env | grep -Ei '^vg[0-9]+_name=' | while IFS='=' read -r VAR_NAME VG_NAME; do
  INDEX=$(echo "$VAR_NAME" | grep -oEi '[0-9]+')
  
  KEYS_VAR_LOWER="vg${INDEX}_keys"
  VALUES_VAR_LOWER="vg${INDEX}_values"
  KEYS_VAR_UPPER="VG${INDEX}_KEYS"
  VALUES_VAR_UPPER="VG${INDEX}_VALUES"

  KEYS_RAW="${!KEYS_VAR_LOWER:-${!KEYS_VAR_UPPER}}"
  VALUES_RAW="${!VALUES_VAR_LOWER:-${!VALUES_VAR_UPPER}}"

  if [[ -z "$KEYS_RAW" || -z "$VALUES_RAW" ]]; then
    echo "⚠️ Skipping $VG_NAME due to missing keys or values"
    echo "  ➤ $KEYS_VAR_LOWER or $KEYS_VAR_UPPER: $KEYS_RAW"
    echo "  ➤ $VALUES_VAR_LOWER or $VALUES_VAR_UPPER: $VALUES_RAW"
    continue
  fi

  IFS=',' read -ra KEYS <<< "$KEYS_RAW"
  IFS=',' read -ra VALUES <<< "$VALUES_RAW"

  if [[ "${#KEYS[@]}" -ne "${#VALUES[@]}" ]]; then
    echo "❌ ERROR: Mismatch in number of keys and values for $VG_NAME"
    continue
  fi

  echo "🔧 Creating Variable Group: $VG_NAME"

  # Construct variables JSON object manually
  VARIABLES_JSON="{"
  for i in "${!KEYS[@]}"; do
    K="${KEYS[$i]}"
    V="${VALUES[$i]}"
    VARIABLES_JSON+="\"${K//\"/}\\\": { \"value\": \"${V//\"/}\", \"isSecret\": false }"
    [[ $i -lt $((${#KEYS[@]} - 1)) ]] && VARIABLES_JSON+=","
  done
  VARIABLES_JSON+="}"

  # Write variable JSON to a file
  echo "$VARIABLES_JSON" > variables.json

  echo "📂 Variable JSON written to variables.json:"
  cat variables.json

  # Final body with --slurpfile to safely load object
  BODY=$(jq -n \
    --arg name "$VG_NAME" \
    --arg projectId "$PROJECT_ID" \
    --arg projectName "$PROJECT" \
    --slurpfile variables variables.json \
    '{
      type: "Vsts",
      name: $name,
      variables: $variables[0],
      variableGroupProjectReferences: [
        {
          projectReference: {
            id: $projectId,
            name: $projectName
          },
          name: $name
        }
      ]
    }')

  echo "$BODY" > payload.json
  echo "📄 JSON payload saved to payload.json"
  jq . payload.json

  URL="https://dev.azure.com/$ORG/$PROJECT/_apis/distributedtask/variablegroups?api-version=7.1-preview.2"
  RESPONSE_FILE=$(mktemp)

  echo "🌐 Sending POST to: $URL"

  HTTP_CODE=$(curl --http1.1 -s -w "%{http_code}" -o "$RESPONSE_FILE" -X POST \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d @payload.json "$URL")

  echo "📡 HTTP response code: $HTTP_CODE"
  echo "📨 API Response:"
  cat "$RESPONSE_FILE"

  if [[ "$HTTP_CODE" -ge 400 || "$HTTP_CODE" -eq 000 ]]; then
    echo "❌ ERROR: Failed to create variable group $VG_NAME"
  else
    echo "✅ Variable group $VG_NAME created successfully!"
  fi
done
