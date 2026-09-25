#!/usr/bin/env bash
#
# Redeploy the chaincode after editing it, keeping the existing ledger state.
#
#   ./scripts/redeploy.sh
#
# Fabric requires the sequence number to increment by exactly one on every
# upgrade. This script tracks it in .cc-sequence so you do not have to.
#
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_tools docker npm peer

if ! network_is_up; then
    echo "ERROR: network is not running. Use ./scripts/setup.sh first."
    exit 1
fi

if [ -f "$SEQ_FILE" ]; then
    CURRENT_SEQ=$(cat "$SEQ_FILE")
else
    # Recover the sequence from the ledger if the local file is missing.
    echo "==> .cc-sequence missing, reading committed sequence from the ledger"
    source "$SCRIPT_DIR/env-org1.sh" >/dev/null
    CURRENT_SEQ=$(peer lifecycle chaincode querycommitted \
        --channelID "$CHANNEL_NAME" --name "$CC_NAME" --output json \
        | jq -r '.sequence')
fi

NEXT_SEQ=$((CURRENT_SEQ + 1))
NEXT_VER="1.$NEXT_SEQ"

echo "==> Installing chaincode dependencies"
( cd "$CC_PATH" && npm install --silent )

echo "==> Redeploying as version $NEXT_VER, sequence $NEXT_SEQ"
cd "$NETWORK_DIR"
./network.sh deployCC -ccn "$CC_NAME" -ccp "$CC_PATH" -ccl "$CC_LANG" \
    -ccv "$NEXT_VER" -ccs "$NEXT_SEQ"

echo "$NEXT_SEQ" > "$SEQ_FILE"

echo
echo "Redeployed. Existing ledger records are untouched."
