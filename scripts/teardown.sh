#!/usr/bin/env bash
#
# Stop the test network and remove its volumes.
#
#   ./scripts/teardown.sh
#
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

echo "==> Stopping network"
cd "$NETWORK_DIR"
./network.sh down

echo "==> Pruning volumes"
docker volume prune -f >/dev/null

rm -f "$SEQ_FILE"

echo "Done. Ledger state is gone — next setup.sh starts from an empty ledger."
