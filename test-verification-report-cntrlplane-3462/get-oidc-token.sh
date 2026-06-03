#!/bin/bash
TENANT="520cf09d-...73b09"
APPID="d638131c-...dbc1"
SECRET="<SET_YOUR_CLIENT_SECRET_HERE>"
TOKEN_URL="https://login.microsoftonline.com/${TENANT}/oauth2/v2.0"

echo "=== Step 1: Requesting device code ==="
RESPONSE=$(curl -s -X POST "${TOKEN_URL}/devicecode" \
  -d "client_id=${APPID}&scope=openid+profile+email")

echo "$RESPONSE" | jq .

DEVICE_CODE=$(echo "$RESPONSE" | jq -r '.device_code')
USER_CODE=$(echo "$RESPONSE" | jq -r '.user_code')
VERIFY_URL=$(echo "$RESPONSE" | jq -r '.verification_uri')

echo ""
echo "=== ACTION REQUIRED ==="
echo "Go to: ${VERIFY_URL}"
echo "Enter code: ${USER_CODE}"
echo ""
read -p "Press Enter after you've completed the sign-in in your browser..."

echo ""
echo "=== Step 2: Exchanging device code for tokens ==="
TOKEN_RESPONSE=$(curl -s -X POST "${TOKEN_URL}/token" \
  -d "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code&client_id=${APPID}&device_code=${DEVICE_CODE}")

ID_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.id_token')

if [ "$ID_TOKEN" = "null" ] || [ -z "$ID_TOKEN" ]; then
  echo "ERROR: Failed to get ID token"
  echo "$TOKEN_RESPONSE" | jq .
  exit 1
fi

echo "ID token obtained successfully."
echo ""
echo "=== Step 3: Testing authentication against guest cluster ==="
echo "ID_TOKEN=${ID_TOKEN}" > /tmp/oidc-token.env
echo "Token saved to /tmp/oidc-token.env"
echo ""

SERVER="https://api-brcox-sm-dev-hc.brcox.hcp-sm-azure.azure.devcluster.openshift.com:443"
echo "KAS endpoint: ${SERVER}"
echo ""
kubectl --server="${SERVER}" --token="${ID_TOKEN}" --insecure-skip-tls-verify auth whoami 2>&1
