#!/usr/bin/env bash
# Shared configuration and path resolution.
# Sourced by every other script in this directory. Not meant to be run directly.

CHANNEL_NAME="${CHANNEL_NAME:-mychannel}"
CC_NAME="${CC_NAME:-forensic}"
CC_LANG="javascript"
ORDERER_ADDR="localhost:7050"
ORDERER_HOSTNAME="orderer.example.com"

# Resolve this script's directory even when sourced from elsewhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CC_PATH="$REPO_ROOT/chaincode"

if [ -z "${FABRIC_SAMPLES:-}" ]; then
    echo "ERROR: FABRIC_SAMPLES is not set."
    echo
    echo "  export FABRIC_SAMPLES=/path/to/fabric-samples"
    echo
    echo "If you have not installed Fabric yet, see the README."
    return 1 2>/dev/null || exit 1
fi

FABRIC_SAMPLES="$(cd "$FABRIC_SAMPLES" && pwd)"
NETWORK_DIR="$FABRIC_SAMPLES/test-network"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "ERROR: $NETWORK_DIR does not exist."
    echo "FABRIC_SAMPLES should point at the fabric-samples directory itself."
    return 1 2>/dev/null || exit 1
fi

ORG_DIR="$NETWORK_DIR/organizations"
ORDERER_CA="$ORG_DIR/ordererOrganizations/example.com/tlsca/tlsca.example.com-cert.pem"
ORG1_CA="$ORG_DIR/peerOrganizations/org1.example.com/tlsca/tlsca.org1.example.com-cert.pem"
ORG2_CA="$ORG_DIR/peerOrganizations/org2.example.com/tlsca/tlsca.org2.example.com-cert.pem"

export PATH="$FABRIC_SAMPLES/bin:$PATH"
export FABRIC_CFG_PATH="$FABRIC_SAMPLES/config"

# Sequence number for chaincode upgrades, tracked across redeploys.
SEQ_FILE="$REPO_ROOT/.cc-sequence"

require_tools() {
    local missing=0
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "ERROR: required command not found: $cmd"
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || return 1
}

require_env() {
    if [ -z "${CORE_PEER_LOCALMSPID:-}" ]; then
        echo "ERROR: peer environment not set."
        echo "  source $SCRIPT_DIR/env-org1.sh"
        return 1
    fi
}

network_is_up() {
    docker ps --format '{{.Names}}' | grep -q '^peer0.org1.example.com$'
}
