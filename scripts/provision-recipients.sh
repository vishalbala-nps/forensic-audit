#!/usr/bin/env bash
#
# Create the recipient identities the demo and test fixtures expect.
#
#   ./scripts/provision-recipients.sh
#
# Identities live in the running network's crypto material, so teardown.sh
# destroys them. setup.sh calls this automatically; run it by hand if you
# need to recreate them.
#
# Idempotent: identities that already exist are left alone.
#
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Must match the recipient_id values in testdata/ and the chaincode's
# identity check. Adding a name here is all it takes to add a recipient.
RECIPIENTS_ORG1="user-042 user-117"
RECIPIENTS_ORG2="user-203"

created=0
skipped=0
failed=0

provision() {
    local name="$1" org="$2" domain
    case "$org" in
        Org1) domain=org1.example.com ;;
        Org2) domain=org2.example.com ;;
    esac

    if [ -d "$ORG_DIR/peerOrganizations/$domain/users/$name@$domain/msp" ]; then
        echo "  exists   $name ($org)"
        skipped=$((skipped + 1))
        return 0
    fi

    if "$SCRIPT_DIR/new-recipient.sh" "$name" "$org" >/dev/null 2>&1; then
        echo "  created  $name ($org)"
        created=$((created + 1))
    else
        echo "  FAILED   $name ($org)"
        "$SCRIPT_DIR/new-recipient.sh" "$name" "$org" 2>&1 | sed 's/^/           /'
        failed=$((failed + 1))
    fi
}

if [ ! -d "$ORG_DIR/peerOrganizations" ]; then
    echo "ERROR: no crypto material found."
    echo "The network is down — run ./scripts/setup.sh first."
    exit 1
fi

echo "Provisioning recipient identities"

for name in $RECIPIENTS_ORG1; do
    provision "$name" Org1
done
for name in $RECIPIENTS_ORG2; do
    provision "$name" Org2
done

echo "  $created created, $skipped already present, $failed failed"

if [ "$failed" -gt 0 ]; then
    exit 1
fi

cat <<EOF

Use one:
  source $SCRIPT_DIR/env-recipient.sh user-042
  ./scripts/smoke-test.sh
EOF
