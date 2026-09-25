#!/usr/bin/env bash
#
# Submit a decryption record to the ledger.
#
#   ./scripts/invoke.sh testdata/record-valid.json
#   ./scripts/invoke.sh testdata/record-valid.json --single-org   # policy failure demo
#
# --single-org endorses with Org1 only. The command appears to succeed but the
# transaction is marked ENDORSEMENT_POLICY_FAILURE at commit and nothing is written.
#
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_tools jq peer
require_env

RECORD_FILE="${1:-}"
if [ -z "$RECORD_FILE" ] || [ ! -f "$RECORD_FILE" ]; then
    echo "Usage: $0 <record.json> [--single-org]"
    exit 1
fi

if ! jq empty "$RECORD_FILE" 2>/dev/null; then
    echo "ERROR: $RECORD_FILE is not valid JSON"
    exit 1
fi

PEER_ARGS=(--peerAddresses localhost:7051 --tlsRootCertFiles "$ORG1_CA")
if [ "${2:-}" != "--single-org" ]; then
    PEER_ARGS+=(--peerAddresses localhost:9051 --tlsRootCertFiles "$ORG2_CA")
else
    echo "NOTE: endorsing with Org1 only — expect ENDORSEMENT_POLICY_FAILURE at commit."
fi

# jq -Rs . reads the file as one raw string and emits it as an escaped JSON
# string literal, which is what Args expects. Hand-escaping this is a trap.
PAYLOAD="$(jq -Rs 'rtrimstr("\n")' "$RECORD_FILE")"

set +e
OUTPUT=$(peer chaincode invoke \
    -o "$ORDERER_ADDR" --ordererTLSHostnameOverride "$ORDERER_HOSTNAME" \
    --tls --cafile "$ORDERER_CA" \
    -C "$CHANNEL_NAME" -n "$CC_NAME" \
    "${PEER_ARGS[@]}" \
    --waitForEvent \
    -c "{\"function\":\"RecordDecryption\",\"Args\":[$PAYLOAD]}" 2>&1)
RC=$?
set -e

echo "$OUTPUT"

if [ $RC -ne 0 ]; then
    echo
    echo "Invoke failed. Chaincode logs:"
    echo "  $SCRIPT_DIR/logs.sh cc"
    exit $RC
fi

if echo "$OUTPUT" | grep -q "status (VALID)"; then
    WM=$(jq -r '.watermark_id' "$RECORD_FILE")
    echo
    echo "Committed. Read it back with:"
    echo "  $SCRIPT_DIR/query.sh $WM"
else
    echo
    echo "WARNING: transaction did not commit as VALID."
    echo "Check the peer log:  $SCRIPT_DIR/logs.sh peer1"
    exit 1
fi
