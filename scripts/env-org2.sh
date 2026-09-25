#!/usr/bin/env bash
#
# Act as Org2 for peer CLI commands. MUST be sourced, not executed:
#
#   source ./scripts/env-org2.sh
#
# Useful for proving a record is readable from a different organization's peer.
#
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "ERROR: source this script, do not run it:"
    echo "  source ${BASH_SOURCE[0]}"
    exit 1
fi

source "$(dirname "${BASH_SOURCE[0]}")/common.sh" || return 1

export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID=Org2MSP
export CORE_PEER_TLS_ROOTCERT_FILE="$ORG2_CA"
export CORE_PEER_MSPCONFIGPATH="$ORG_DIR/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp"
export CORE_PEER_ADDRESS=localhost:9051
export LEDGER_IDENTITY_CN="Admin@org2.example.com"

echo "Acting as Org2MSP (Admin@org2.example.com) -> localhost:9051"
