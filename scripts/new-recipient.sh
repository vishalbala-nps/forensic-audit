#!/usr/bin/env bash
#
# Create a new named identity, signed by an organization's existing CA.
#
#   ./scripts/new-recipient.sh recipient-042
#   ./scripts/new-recipient.sh recipient-117 Org2
#   ./scripts/new-recipient.sh auditor-01 Org1 --role admin
#
# Why not cryptogen? Cryptogen can only produce users named User1..UserN --
# the Specs block in crypto-config.yaml names PEERS, not users. Since the
# chaincode compares record.recipient_id against the certificate CN, we need
# arbitrary names, so we issue the certificate directly using the org CA key
# that cryptogen already wrote to disk.
#
# This ADDS an identity. It does not touch the network, the ledger, or any
# existing crypto material -- no teardown required.
#
# The MSP config is part of channel configuration and trusts the org's root
# CA, so a certificate signed by that CA is accepted immediately with no
# channel update.
#
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_tools openssl

NAME="${1:-}"
ORG="${2:-Org1}"
ROLE="client"

shift 2 2>/dev/null || shift $# 
while [ $# -gt 0 ]; do
    case "$1" in
        --role) ROLE="${2:-client}"; shift 2 ;;
        *) echo "unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$NAME" ]; then
    cat <<EOF
Usage: $0 <name> [Org1|Org2] [--role client|admin]

  $0 recipient-042
  $0 recipient-117 Org2
  $0 auditor-01 Org1 --role admin

Names should match the recipient_id values your records will carry, so the
chaincode's CN check lines up.
EOF
    exit 1
fi

case "$NAME" in
    *[!a-zA-Z0-9._-]*)
        echo "ERROR: name may only contain letters, digits, dot, underscore, hyphen"
        exit 1 ;;
esac

case "$ROLE" in
    client|admin) ;;
    *) echo "ERROR: --role must be client or admin"; exit 1 ;;
esac

case "$ORG" in
    Org1|org1) DOMAIN=org1.example.com ;;
    Org2|org2) DOMAIN=org2.example.com ;;
    *) echo "ERROR: organization must be Org1 or Org2"; exit 1 ;;
esac

ORG_ROOT="$ORG_DIR/peerOrganizations/$DOMAIN"
CA_DIR="$ORG_ROOT/ca"
USERS_DIR="$ORG_ROOT/users"
FULL_NAME="$NAME@$DOMAIN"
MSP_DIR="$USERS_DIR/$FULL_NAME/msp"

if [ ! -d "$ORG_ROOT" ]; then
    echo "ERROR: $ORG_ROOT does not exist."
    echo "The network is down -- crypto material only exists while it is up."
    echo "Run ./scripts/setup.sh first."
    exit 1
fi

if [ -d "$MSP_DIR" ]; then
    echo "ERROR: identity '$FULL_NAME' already exists at"
    echo "  $MSP_DIR"
    echo "Delete that directory first if you want to reissue it."
    exit 1
fi

CA_CERT="$(ls "$CA_DIR"/*-cert.pem 2>/dev/null | head -1)"
CA_KEY="$(ls "$CA_DIR"/priv_sk "$CA_DIR"/*_sk 2>/dev/null | head -1)"

if [ -z "$CA_CERT" ] || [ -z "$CA_KEY" ]; then
    echo "ERROR: could not find the CA cert and key in $CA_DIR"
    ls -la "$CA_DIR" 2>&1 | sed 's/^/  /'
    exit 1
fi

# Borrow config.yaml and the CA bundles from an existing user so NodeOU
# definitions and trust anchors match exactly what cryptogen produced.
TEMPLATE="$(ls -d "$USERS_DIR"/*/ 2>/dev/null | head -1)"
if [ -z "$TEMPLATE" ]; then
    echo "ERROR: no existing user under $USERS_DIR to copy MSP structure from."
    exit 1
fi
TEMPLATE_MSP="${TEMPLATE%/}/msp"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Issuing $FULL_NAME (role: $ROLE) from $ORG's CA"

# Fabric requires ECDSA on the P-256 curve.
openssl ecparam -name prime256v1 -genkey -noout -out "$TMP/priv_sk" 2>/dev/null

SUBJ="/C=US/ST=California/L=San Francisco/OU=$ROLE/CN=$FULL_NAME"
openssl req -new -key "$TMP/priv_sk" -out "$TMP/req.csr" -subj "$SUBJ" -sha256 2>/dev/null

cat > "$TMP/ext.cnf" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF

openssl x509 -req \
    -in "$TMP/req.csr" \
    -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$TMP/cert.pem" \
    -days 3650 -sha256 \
    -extfile "$TMP/ext.cnf" 2>/dev/null

# Verify before installing anything.
if ! openssl verify -CAfile "$CA_CERT" "$TMP/cert.pem" >/dev/null 2>&1; then
    echo "ERROR: issued certificate does not verify against $CA_CERT"
    exit 1
fi

CERT_PUB="$(openssl x509 -in "$TMP/cert.pem" -noout -pubkey 2>/dev/null | openssl dgst -sha256)"
KEY_PUB="$(openssl ec -in "$TMP/priv_sk" -pubout 2>/dev/null | openssl dgst -sha256)"
if [ "$CERT_PUB" != "$KEY_PUB" ]; then
    echo "ERROR: private key does not match the issued certificate"
    exit 1
fi

echo "==> Building MSP directory"
mkdir -p "$MSP_DIR"/{signcerts,keystore,cacerts,tlscacerts,admincerts}

cp "$TMP/cert.pem" "$MSP_DIR/signcerts/$FULL_NAME-cert.pem"
cp "$TMP/priv_sk"  "$MSP_DIR/keystore/priv_sk"
chmod 600 "$MSP_DIR/keystore/priv_sk"

cp -r "$TEMPLATE_MSP/cacerts/."    "$MSP_DIR/cacerts/"    2>/dev/null || true
cp -r "$TEMPLATE_MSP/tlscacerts/." "$MSP_DIR/tlscacerts/" 2>/dev/null || true
[ -f "$TEMPLATE_MSP/config.yaml" ] && cp "$TEMPLATE_MSP/config.yaml" "$MSP_DIR/config.yaml"

# Mirror the TLS material layout cryptogen produces, so tooling that expects
# a tls/ directory alongside msp/ keeps working.
TLS_SRC="${TEMPLATE%/}/tls"
if [ -d "$TLS_SRC" ]; then
    cp -r "$TLS_SRC" "$USERS_DIR/$FULL_NAME/tls"
fi

echo
echo "Created: $USERS_DIR/$FULL_NAME"
openssl x509 -in "$MSP_DIR/signcerts/$FULL_NAME-cert.pem" -noout \
    -subject -issuer -enddate -nameopt RFC2253 | sed 's/^/  /'

cat <<EOF

Use it:
  source ./scripts/env-recipient.sh $NAME $ORG
  ./scripts/invoke.sh testdata/record-valid.json

This identity is accepted immediately -- the channel MSP already trusts the
CA that signed it, so no channel configuration update is needed.

It lives only in the running network's crypto material, so teardown.sh
destroys it. Re-run this script after each setup.sh, or add it to a
provisioning script.
EOF