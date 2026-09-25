#!/usr/bin/env bash
#
# Bring up the Fabric test network and deploy the forensic audit chaincode.
# Destroys any existing network first, so this is always a clean start.
#
#   ./scripts/setup.sh
#
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_tools docker jq node npm peer

echo "==> Checking chaincode directory"
for f in index.js package.json lib/forensicAudit.js; do
    if [ ! -f "$CC_PATH/$f" ]; then
        echo "ERROR: missing $CC_PATH/$f"
        exit 1
    fi
done

if ! grep -q '"start"' "$CC_PATH/package.json"; then
    echo "ERROR: chaincode/package.json has no scripts.start entry."
    echo "The peer launches chaincode with 'npm start' — without it the container exits."
    exit 1
fi

echo "==> Installing chaincode dependencies (needed offline later)"
( cd "$CC_PATH" && npm install --silent )

echo "==> Tearing down any existing network"
cd "$NETWORK_DIR"
./network.sh down >/dev/null 2>&1 || true
docker volume prune -f >/dev/null 2>&1 || true

echo "==> Starting network and creating channel '$CHANNEL_NAME'"
./network.sh up createChannel -c "$CHANNEL_NAME"

echo "==> Deploying chaincode '$CC_NAME'"
./network.sh deployCC -ccn "$CC_NAME" -ccp "$CC_PATH" -ccl "$CC_LANG" -ccv 1.0 -ccs 1

echo "1" > "$SEQ_FILE"

echo
echo "==> Committed chaincode definition"
export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID=Org1MSP
export CORE_PEER_TLS_ROOTCERT_FILE="$ORG1_CA"
export CORE_PEER_MSPCONFIGPATH="$ORG_DIR/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp"
export CORE_PEER_ADDRESS=localhost:7051
peer lifecycle chaincode querycommitted --channelID "$CHANNEL_NAME" --name "$CC_NAME" --output json | jq .

echo
"$SCRIPT_DIR/provision-recipients.sh" || {
    echo "WARNING: recipient provisioning failed — the smoke test will not run."
    echo "Try ./scripts/provision-recipients.sh by hand to see why."
}

cat <<EOF

Network is up, chaincode is deployed, recipient identities are provisioned.

Next:
  source $SCRIPT_DIR/env-recipient.sh user-042
  $SCRIPT_DIR/smoke-test.sh

Records must be submitted by the recipient they name, so use
env-recipient.sh here. env-org1.sh is for admin work (redeploy.sh).

EOF
