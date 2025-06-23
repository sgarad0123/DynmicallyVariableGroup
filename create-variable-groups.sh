#!/bin/bash

set -e

PAT="$1"

if [[ -z "$PAT" ]]; then
  echo "❌ ERROR: Missing PAT"
  exit 1
fi

ENCODED_PAT=$(printf ":%s" "$PAT" | base64 | tr -d '\n')
AUTH_HEADER="Authorization: Basic $ENCODED_PAT"

ORG="$org"
PROJECT="$project"

if [[ -z "$ORG" || -z "$PROJECT" ]]; then
  echo "❌ ERROR: org or project not defined"
  exit 1
fi

# Get project ID
PROJECT_API_URL="https://dev.azure.com/$ORG/_apis/projects/$PROJECT?api-version=7.1-preview.1"
PROJECT_ID=$(curl -s -H "$AUTH_HEADER" "$PROJECT_API_URL" | jq -r '.id')

if [[ "$PROJECT_ID" == "null" || -z "$PROJECT_ID" ]]; then
  echo "❌ ERROR: Failed to fetch project ID for $PROJECT"
  exit 1
fi

echo "✅ Project ID: $PROJECT_ID"

# Find all vg#_name from env
env | grep '^vg[0-9]_name=' | while IFS='=' read -r VAR_NAME VG_NAME; do
  INDEX=$(echo "$VAR_NAME" | grep -oP '^vg\K[0-9]+')
  KEYS_VAR="vg${INDEX}_keys"
  VALUES_VAR="vg${INDEX}_values"

  KEYS_RAW=$(printenv "$KEYS_VAR")
  VALUES_RAW=$(printenv "$VALUES_VAR")

  if [[ -z "$KEYS_RAW" || -z "$VALUES_RAW" ]]; then
    echo "⚠️ Skipping $VG_NAME due to missing keys or values"
    continue
  fi

  IFS=',' read -r -a KEYS <<< "$KEYS_RAW"
  IFS=',' read -r -a VALUES <<< "$VALUES_RAW"

  if [[ "${#KEYS[@]}" -ne "${#VALUES[@]}" ]]; then
    echo "❌ ERROR: Mismatch in key/value count for $VG_NAME"
    continue
  fi

  # Build variable JSON
  VARIABLES_JSON="{"
  for i in "${!KEYS[@]}"; do
    KEY_TRIMMED=$(echo "${KEYS[$i]}" | xargs)
    VALUE_TRIMMED=$(echo "${VALUES[$i]}" | xargs)
    VARIABLES_JSON+="\"$KEY_TRIMMED\": {\"value\": \"$VALUE_TRIMMED\", \"isSecret\": false}"
    [[ $i -lt $((${#KEYS[@]} - 1)) ]] && VARIABLES_JSON+=","
  done
  VARIABLES_JSON+="}"

  # Final body
  BODY=$(jq -n \
    --arg name "$VG_NAME" \
    --argjson variables "$VARIABLES_JSON" \
    --arg projectId "$PROJECT_ID" \
    --arg projectName "$PROJECT" \
    '{
      type: "Vsts",
      name: $name,
      variables: $variables,
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
  echo "📤 Creating Variable Group: $VG_NAME"

  URL="https://dev.azure.com/$ORG/$PROJECT/_apis/distributedtask/variablegroups?api-version=7.1-preview.2"
  RESPONSE_FILE=$(mktemp)
  HTTP_CODE=$(curl --http1.1 -s -w "%{http_code}" -o "$RESPONSE_FILE" -X POST \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d @payload.json "$URL")

  if [[ "$HTTP_CODE" -ge 400 || "$HTTP_CODE" -eq 000 ]]; then
    echo "❌ ERROR: Failed to create variable group $VG_NAME"
    cat "$RESPONSE_FILE"
  else
    echo "✅ Created variable group $VG_NAME"
  fi

done
