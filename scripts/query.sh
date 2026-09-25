#!/usr/bin/env bash
#
# Read from the ledger.
#
#   ./scripts/query.sh <watermark_id>   look up one record
#   ./scripts/query.sh --all            list every record
#
# Queries hit whichever peer CORE_PEER_ADDRESS points at. Source env-org2.sh
# and run the same lookup to prove both organizations hold the same record.
#
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_tools jq peer
require_env

ARG="${1:-}"
if [ -z "$ARG" ]; then
    echo "Usage: $0 <watermark_id> | --all"
    exit 1
fi

if [ "$ARG" = "--all" ]; then
    CTOR='{"function":"GetAllRecords","Args":[]}'
else
    CTOR="{\"function\":\"LookupByWatermark\",\"Args\":[\"$ARG\"]}"
fi

echo "Querying as $CORE_PEER_LOCALMSPID at $CORE_PEER_ADDRESS"
echo

set +e
OUTPUT=$(peer chaincode query -C "$CHANNEL_NAME" -n "$CC_NAME" -c "$CTOR" 2>&1)
RC=$?
set -e

if [ $RC -ne 0 ]; then
    if echo "$OUTPUT" | grep -q "no record found"; then
        echo "No record found for watermark: $ARG"
        exit 2
    fi
    echo "$OUTPUT"
    exit $RC
fi

echo "$OUTPUT" | jq .
