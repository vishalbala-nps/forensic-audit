#!/usr/bin/env bash
#
# Package the minimum crypto material a remote ledger client needs.
#
#   ./scripts/bundle-identity.sh user-042
#   ./scripts/bundle-identity.sh user-203 Org2 /tmp/bundle-203
#
# Produces a directory that mirrors the layout ledger.js expects, so the
# container mounts it at /fabric with FABRIC_SAMPLES=/fabric and no code
# changes are needed:
#
#   <out>/test-network/organizations/peerOrganizations/<domain>/
#       tlsca/tlsca.<domain>-cert.pem          verify the peer's TLS cert
#       users/<name>@<domain>/msp/signcerts/   the recipient's certificate
#       users/<name>@<domain>/msp/keystore/    the recipient's PRIVATE KEY
#
# The bundle contains a private key. Treat it like one: transfer it over a
# channel you trust, and give each recipient only their own bundle.
#
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

NAME="${1:-}"
ORG="${2:-Org1}"
OUT="${3:-}"

if [ -z "$NAME" ]; then
    echo "Usage: $0 <recipient-name> [Org1|Org2] [output-dir]"
    exit 1
fi

case "$ORG" in
    Org1|org1) DOMAIN=org1.example.com ;;
    Org2|org2) DOMAIN=org2.example.com ;;
    *) echo "ERROR: organization must be Org1 or Org2"; exit 1 ;;
esac

OUT="${OUT:-$REPO_ROOT/bundles/$NAME}"
FULL="$NAME@$DOMAIN"
SRC_MSP="$ORG_DIR/peerOrganizations/$DOMAIN/users/$FULL/msp"
SRC_TLSCA="$ORG_DIR/peerOrganizations/$DOMAIN/tlsca/tlsca.$DOMAIN-cert.pem"

if [ ! -d "$SRC_MSP" ]; then
    echo "ERROR: no identity '$FULL'."
    echo "Create it first:  ./scripts/new-recipient.sh $NAME $ORG"
    exit 1
fi

if [ ! -f "$SRC_TLSCA" ]; then
    echo "ERROR: TLS CA certificate not found at $SRC_TLSCA"
    exit 1
fi

DEST="$OUT/test-network/organizations/peerOrganizations/$DOMAIN"
rm -rf "$OUT"
mkdir -p "$DEST/tlsca" "$DEST/users/$FULL/msp/signcerts" "$DEST/users/$FULL/msp/keystore"

cp "$SRC_TLSCA" "$DEST/tlsca/"
cp "$SRC_MSP/signcerts/"*.pem "$DEST/users/$FULL/msp/signcerts/"
cp "$SRC_MSP/keystore/"* "$DEST/users/$FULL/msp/keystore/"
[ -f "$SRC_MSP/config.yaml" ] && cp "$SRC_MSP/config.yaml" "$DEST/users/$FULL/msp/"
cp -r "$SRC_MSP/cacerts" "$DEST/users/$FULL/msp/" 2>/dev/null || true

chmod 700 "$DEST/users/$FULL/msp/keystore"
chmod 600 "$DEST/users/$FULL/msp/keystore/"*

cat > "$OUT/README.txt" <<EOF
Identity bundle for $FULL ($ORG).

CONTAINS A PRIVATE KEY. Do not share this bundle with anyone but $NAME.

Run the ledger client against a remote peer:

  docker run --rm \\
    -v "\$(pwd)":/fabric:ro \\
    -e FABRIC_SAMPLES=/fabric \\
    -e ${ORG^^}_PEER=<peer-host>:$([ "$ORG" = "Org2" ] && echo 9051 || echo 7051) \\
    -e DEFAULT_IDENTITY=$NAME \\
    forensic-ledger-client whoami $NAME

No /etc/hosts entry is needed: the client dials the address you give and
validates the peer's TLS certificate against peer0.$DOMAIN via
grpc.ssl_target_name_override.
EOF

echo "Bundle written to $OUT"
find "$OUT" -type f | sed "s|$OUT|  .|" | sort
echo
echo "Size: $(du -sh "$OUT" | cut -f1)"
echo
echo "Contains $NAME's PRIVATE KEY -- transfer it accordingly."
