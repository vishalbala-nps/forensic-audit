#!/usr/bin/env bash
#
# Tail the logs you actually need when something breaks.
#
#   ./scripts/logs.sh cc        chaincode container — your throw() messages land here
#   ./scripts/logs.sh peer1     Org1 peer — endorsement and validation failures
#   ./scripts/logs.sh peer2     Org2 peer
#   ./scripts/logs.sh orderer   ordering service
#   ./scripts/logs.sh errors    recent errors across both peers, no follow
#
# Triage:
#   chaincode container not running  -> packaging (scripts.start, main, filename case)
#   running but every invoke fails   -> contract logic, read the cc log
#   invoke returns 200 but no record -> endorsement policy, read the peer log
#
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

TARGET="${1:-cc}"

case "$TARGET" in
    cc)
        NAME=$(docker ps --format '{{.Names}}' | grep -- "-${CC_NAME}_" | head -1 || true)
        if [ -z "$NAME" ]; then
            echo "No running chaincode container for '$CC_NAME'."
            echo "That usually means a packaging problem rather than a logic bug."
            echo
            docker ps -a --format 'table {{.Names}}\t{{.Status}}' | grep -- "$CC_NAME" || \
                echo "No chaincode container exists at all — was deployCC run?"
            exit 1
        fi
        echo "==> $NAME"
        docker logs -f --tail 100 "$NAME"
        ;;
    peer1)   docker logs -f --tail 100 peer0.org1.example.com ;;
    peer2)   docker logs -f --tail 100 peer0.org2.example.com ;;
    orderer) docker logs -f --tail 100 orderer.example.com ;;
    errors)
        for p in peer0.org1.example.com peer0.org2.example.com; do
            echo "==== $p ===="
            docker logs "$p" 2>&1 | grep -iE 'error|invalid|ENDORSEMENT_POLICY_FAILURE|MVCC' | tail -20
            echo
        done
        ;;
    *)
        echo "Usage: $0 [cc|peer1|peer2|orderer|errors]"
        exit 1
        ;;
esac
