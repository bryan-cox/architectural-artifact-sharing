#!/bin/bash
set -euo pipefail

# Deploy Keycloak on the management cluster for External OIDC testing
# Adapted from CI: ci-operator/step-registry/idp/external-oidc/keycloak/server/
# Management cluster kubeconfig must be set before running

export KUBECONFIG=/Users/brcox/aws_dev_kubeconfig

GUEST_CONSOLE="https://console-openshift-console.apps.brcox-sm-dev-hc.hcp-sm-azure.azure.devcluster.openshift.com"
HC_NAMESPACE="clusters"
HC_NAME="brcox-sm-dev-hc"
HCP_NAMESPACE="clusters-brcox-sm-dev-hc"

echo "=== Step 1: Create keycloak namespace ==="
oc create ns keycloak --dry-run=client -o yaml | oc apply -f -

echo ""
echo "=== Step 2: Deploy Keycloak from upstream quickstart ==="
KC_ADMIN_USER="admin-$(< /dev/urandom tr -dc 'a-z0-9' | fold -w 6 | head -n 1 || true)"
KC_ADMIN_PASS="$(< /dev/urandom tr -dc 'a-z0-9' | fold -w 12 | head -n 1 || true)"

curl -sS https://raw.githubusercontent.com/keycloak/keycloak-quickstarts/refs/heads/main/kubernetes/keycloak.yaml \
    | sed -e "/- name: .*KC_DB/, +1 d" -e "s/replicas: .*/replicas: 1/" \
    | oc apply -n keycloak -f -

oc delete deployment/postgres -n keycloak --ignore-not-found
oc set env sts/keycloak KC_BOOTSTRAP_ADMIN_USERNAME=$KC_ADMIN_USER KC_BOOTSTRAP_ADMIN_PASSWORD=$KC_ADMIN_PASS -n keycloak

echo ""
echo "=== Step 3: Create edge route ==="
oc create route edge keycloak --service=keycloak -n keycloak --dry-run=client -o yaml | oc apply -f -

KEYCLOAK_HOST="https://$(oc get -n keycloak route keycloak --template='{{ .spec.host }}')"
echo "Keycloak URL: $KEYCLOAK_HOST"

echo ""
echo "=== Step 4: Prepare client and user configuration ==="
mkdir -p /tmp/.keycloak

# CLI client (public, for device code / direct access grants)
cat > /tmp/.keycloak/client-oc-cli-test.json << EOF
{
  "clientId" : "oc-cli-test",
  "enabled" : true,
  "redirectUris" : [ "http://localhost:8080" ],
  "webOrigins" : [ "http://localhost:8080" ],
  "standardFlowEnabled" : true,
  "directAccessGrantsEnabled" : true,
  "publicClient" : true,
  "frontchannelLogout" : true,
  "protocol" : "openid-connect",
  "attributes" : {
    "oidc.ciba.grant.enabled" : "false",
    "backchannel.logout.session.required" : "true",
    "oauth2.device.authorization.grant.enabled" : "false",
    "backchannel.logout.revoke.offline.tokens" : "false",
    "access.token.lifespan" : "150",
    "client.session.idle.timeout" : "7200"
  }
}
EOF

# Console client (confidential, for authorization code flow)
CONSOLE_CLIENT_SECRET="$(< /dev/urandom tr -dc 'a-z0-9' | fold -w 32 | head -n 1 || true)"
cat > /tmp/.keycloak/client-console-test.json << EOF
{
  "clientId" : "console-test",
  "enabled" : true,
  "secret" : "$CONSOLE_CLIENT_SECRET",
  "redirectUris" : [ "$GUEST_CONSOLE/auth/callback" ],
  "webOrigins" : [ "$GUEST_CONSOLE" ],
  "standardFlowEnabled" : true,
  "directAccessGrantsEnabled" : true,
  "publicClient" : false,
  "frontchannelLogout" : true,
  "protocol" : "openid-connect",
  "attributes" : {
    "oidc.ciba.grant.enabled" : "false",
    "backchannel.logout.session.required" : "true",
    "oauth2.device.authorization.grant.enabled" : "false",
    "backchannel.logout.revoke.offline.tokens" : "false",
    "access.token.lifespan" : "150",
    "client.session.idle.timeout" : "7200"
  }
}
EOF

# Group mapper (adds "groups" claim to ID token)
cat > /tmp/.keycloak/groupmapper-for-clients.json << EOF
{
  "name" : "groupmapper",
  "protocol" : "openid-connect",
  "protocolMapper" : "oidc-group-membership-mapper",
  "consentRequired" : false,
  "config" : {
    "full.path" : "false",
    "userinfo.token.claim" : "true",
    "id.token.claim" : "true",
    "access.token.claim" : "false",
    "claim.name" : "groups"
  }
}
EOF

# Test user (just 1 for manual testing, not 50 like CI)
TEST_USER="keycloak-testuser-1"
TEST_PASS="$(< /dev/urandom tr -dc 'a-z0-9' | fold -w 12 | head -n 1 || true)"

# Setup script that runs inside the Keycloak pod via postStart
cat > /tmp/.keycloak/setup-script.sh << 'SETUPEOF'
set -euo pipefail
export PATH=$PATH:/opt/keycloak/bin
echo "Waiting for Keycloak server to start..."
timeout 5m bash -c 'while true; do
    kcadm.sh config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" \
        --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" --config=/tmp/.keycloak-kcadm.config
    if [ "$?" == "0" ] ; then
        break
    fi
    sleep 10
    done
' || { echo "Timeout waiting for Keycloak server"; exit 1; }

echo "Setting session timeout"
kcadm.sh update realms/master -s ssoSessionIdleTimeout=7200 --config=/tmp/.keycloak-kcadm.config

echo "Creating clients"
kcadm.sh create clients -r master --config=/tmp/.keycloak-kcadm.config -f /tmp/.keycloak/client-oc-cli-test.json &> /tmp/cmd_output
CLIENT_OC_CLI_TEST_ID=$(grep -Eo "'.+'" /tmp/cmd_output | grep -Eo "[^']+")
kcadm.sh create clients -r master --config=/tmp/.keycloak-kcadm.config -f /tmp/.keycloak/client-console-test.json &> /tmp/cmd_output
CLIENT_CONSOLE_TEST_ID=$(grep -Eo "'.+'" /tmp/cmd_output | grep -Eo "[^']+")

echo "Creating group mapper for clients"
kcadm.sh create clients/"$CLIENT_OC_CLI_TEST_ID"/protocol-mappers/models \
    -f /tmp/.keycloak/groupmapper-for-clients.json --config=/tmp/.keycloak-kcadm.config
kcadm.sh create clients/"$CLIENT_CONSOLE_TEST_ID"/protocol-mappers/models \
    -f /tmp/.keycloak/groupmapper-for-clients.json --config=/tmp/.keycloak-kcadm.config

echo "Creating group"
kcadm.sh create groups -r master -s name="keycloak-testgroup-1" --config=/tmp/.keycloak-kcadm.config &> /tmp/cmd_output
TEST_GROUP_ID=$(grep -Eo "'.+'" /tmp/cmd_output | grep -Eo "[^']+")

echo "Creating test user"
IFS=','
for i in $(cat /tmp/.keycloak/testusers)
do
    TEST_USER_NAME="$(cut -d ':' -f 1 <<< $i)"
    TEST_USER_PASSWORD="$(cut -d ':' -f 2 <<< $i)"
    kcadm.sh create users -r master -s username="$TEST_USER_NAME" -s enabled=true -s firstName="$TEST_USER_NAME" -s lastName=KC \
        -s email="$TEST_USER_NAME"@example.com -s emailVerified=true --config=/tmp/.keycloak-kcadm.config &> /tmp/cmd_output
    TEST_USER_ID=$(grep -Eo "'.+'" /tmp/cmd_output | grep -Eo "[^']+")
    kcadm.sh set-password -r master --username "$TEST_USER_NAME" --new-password "$TEST_USER_PASSWORD" \
        --temporary=false --config=/tmp/.keycloak-kcadm.config
    kcadm.sh update users/"$TEST_USER_ID"/groups/"$TEST_GROUP_ID" -r master -s realm=master -s userId="$TEST_USER_ID" \
        -s groupId="$TEST_GROUP_ID" --no-merge --config=/tmp/.keycloak-kcadm.config
done
echo "Checking group membership"
kcadm.sh get groups/"$TEST_GROUP_ID"/members --fields username --format csv --config=/tmp/.keycloak-kcadm.config | grep -q "$TEST_USER_NAME"
echo "Keycloak setup done!"
SETUPEOF

echo ""
echo "=== Step 5: Create ConfigMap and mount into Keycloak pod ==="
oc delete configmap setup-script -n keycloak --ignore-not-found
oc create configmap setup-script -n keycloak \
    --from-file=/tmp/.keycloak/client-oc-cli-test.json \
    --from-file=/tmp/.keycloak/client-console-test.json \
    --from-file=/tmp/.keycloak/groupmapper-for-clients.json \
    --from-literal=testusers="${TEST_USER}:${TEST_PASS}" \
    --from-file=/tmp/.keycloak/setup-script.sh

oc set volumes sts/keycloak -n keycloak --add --type=configmap --configmap-name=setup-script --mount-path=/tmp/.keycloak --overwrite

echo ""
echo "=== Step 6: Add postStart lifecycle hook ==="
oc patch sts/keycloak -n keycloak -p='
spec:
  template:
    spec:
      containers:
      - name: keycloak
        lifecycle:
          postStart:
            exec:
              command:
              - /bin/bash
              - -c
              - |
                bash /tmp/.keycloak/setup-script.sh &> /tmp/postStart.log || true
'

echo ""
echo "=== Step 7: Wait for Keycloak to be ready ==="
echo "Waiting 60s for rollout to begin..."
sleep 60
timeout 10m bash -c 'while true; do
    if oc wait pod/keycloak-0 --for=condition=Ready -n keycloak --timeout=400s 2>/dev/null; then
        R1=$(oc get sts/keycloak -n keycloak -o=jsonpath="{.status.updateRevision}")
        R2=$(oc get po/keycloak-0 -n keycloak -o=jsonpath="{.metadata.labels.controller-revision-hash}")
        if [ "$R2" == "$R1" ]; then
            break
        fi
        sleep 20
    fi
done
' || { echo "Timeout waiting for Keycloak"; exit 1; }

echo ""
echo "=== Step 8: Verify Keycloak setup completed ==="
oc rsh -n keycloak sts/keycloak cat /tmp/postStart.log
echo ""
oc rsh -n keycloak sts/keycloak cat /opt/keycloak/version.txt
echo ""

echo ""
echo "=== Step 9: Extract router CA for issuerCertificateAuthority ==="
mkdir -p /tmp/router-ca
oc extract cm/default-ingress-cert -n openshift-config-managed --to=/tmp/router-ca --confirm

echo ""
echo "=== Step 10: Verify Keycloak OIDC endpoint is accessible ==="
if curl -sSI --cacert /tmp/router-ca/ca-bundle.crt "$KEYCLOAK_HOST/realms/master/.well-known/openid-configuration" | grep -Eq 'HTTP/[^ ]+ 200'; then
    echo "Keycloak OIDC endpoint is accessible!"
else
    echo "ERROR: Keycloak OIDC endpoint is NOT accessible!"
    exit 1
fi

echo ""
echo "============================================"
echo "Keycloak deployment complete!"
echo "============================================"
echo ""
echo "KEYCLOAK_HOST=$KEYCLOAK_HOST"
echo "ISSUER_URL=$KEYCLOAK_HOST/realms/master"
echo "CLI_CLIENT_ID=oc-cli-test"
echo "CONSOLE_CLIENT_ID=console-test"
echo "CONSOLE_CLIENT_SECRET=$CONSOLE_CLIENT_SECRET"
echo "TEST_USER=$TEST_USER"
echo "TEST_PASS=$TEST_PASS"
echo "CA_BUNDLE=/tmp/router-ca/ca-bundle.crt"
echo ""
echo "Next: Reconfigure the HostedCluster to use Keycloak as the OIDC provider"
