#!/usr/bin/env bash
#
# Act as Org1 for peer CLI commands. MUST be sourced, not executed:
#
#   source ./scripts/env-org1.sh
#
# Resolve our own path under both bash and zsh.
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    _SELF="${BASH_SOURCE[0]}"
    _SOURCED=$([ "${BASH_SOURCE[0]}" != "${0}" ] && echo yes || echo no)
elif [ -n "${(%):-%x}" ] 2>/dev/null; then
    _SELF="${(%):-%x}"
    _SOURCED=yes
else
    echo "ERROR: unsupported shell — use bash or zsh"
    return 1 2>/dev/null || exit 1
fi

if [ "$_SOURCED" = "no" ]; then
    echo "ERROR: source this script, do not run it:"
    echo "  source $_SELF"
    exit 1
fi

source "$(cd "$(dirname "$_SELF")" && pwd)/common.sh" || return 1

export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID=Org1MSP
export CORE_PEER_TLS_ROOTCERT_FILE="$ORG1_CA"
export CORE_PEER_MSPCONFIGPATH="$ORG_DIR/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp"
export CORE_PEER_ADDRESS=localhost:7051

echo "Acting as Org1MSP (Admin@org1.example.com) -> localhost:7051"
