#!/usr/bin/env bash
#
# Act as a specific recipient identity rather than an org admin.
# MUST be sourced, not executed:
#
#   source ./scripts/env-recipient.sh recipient-042
#   source ./scripts/env-recipient.sh User1 Org2
#   source ./scripts/env-recipient.sh --list
#
# Defaults to Org1 when no organization is given.
#
# Why this matters: env-org1.sh acts as Admin@org1.example.com, so every record
# on the ledger looks like it was submitted by an administrator. Submitting as
# the recipient themselves is what binds the transaction to that person at the
# Fabric layer, alongside the ML-DSA signature inside the record.
#
# Note: Fabric's default lifecycle policies require an admin identity to
# install or approve chaincode. Keep using env-org1.sh for setup.sh and
# redeploy.sh; use this one for invoke.sh and query.sh.

# --- resolve our own path under both bash and zsh -------------------------
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    _SELF="${BASH_SOURCE[0]}"
    [ "${BASH_SOURCE[0]}" != "${0}" ] && _SOURCED=yes || _SOURCED=no
else
    _SELF="${(%):-%x}"
    _SOURCED=yes
fi

if [ "$_SOURCED" = "no" ]; then
    echo "ERROR: source this script, do not run it:"
    echo "  source $_SELF <recipient-name> [Org1|Org2]"
    exit 1
fi

_SCRIPTS="$(cd "$(dirname "$_SELF")" && pwd)"
source "$_SCRIPTS/common.sh" || return 1

# --- arguments ------------------------------------------------------------
_RECIPIENT="${1:-}"
_ORG="${2:-Org1}"

case "$_ORG" in
    Org1|org1) _ORG=Org1; _DOMAIN=org1.example.com; _MSPID=Org1MSP; _PORT=7051; _CA="$ORG1_CA" ;;
    Org2|org2) _ORG=Org2; _DOMAIN=org2.example.com; _MSPID=Org2MSP; _PORT=9051; _CA="$ORG2_CA" ;;
    *)
        echo "ERROR: organization must be Org1 or Org2, got '$_ORG'"
        unset _RECIPIENT _ORG _SELF _SOURCED _SCRIPTS
        return 1
        ;;
esac

_USERS_DIR="$ORG_DIR/peerOrganizations/$_DOMAIN/users"

_cert_field() {
    # $1 = cert path, $2 = field name (OU, CN). Uses RFC2253 so output is
    # "CN=x,OU=y,..." with no spaces, consistent across OpenSSL versions.
    openssl x509 -in "$1" -noout -subject -nameopt RFC2253 2>/dev/null \
        | sed -n "s/.*[,=]\{0,1\}$2=\\([^,]*\\).*/\\1/p" | head -1
}

_list_users() {
    if [ ! -d "$_USERS_DIR" ]; then
        echo "No identities found for $_ORG."
        echo "The network is probably down — run ./scripts/setup.sh first."
        return 1
    fi
    echo "Identities available in $_ORG:"
    for d in "$_USERS_DIR"/*/; do
        [ -d "$d" ] || continue
        local full name ou
        full="$(basename "$d")"
        name="${full%%@*}"
        ou="$(_cert_field "$(ls "$d/msp/signcerts/"*.pem 2>/dev/null | head -1)" OU)"
        printf "  %-28s %s\n" "$name" "${ou:+(OU=$ou)}"
    done
}

if [ -z "$_RECIPIENT" ] || [ "$_RECIPIENT" = "--list" ] || [ "$_RECIPIENT" = "-l" ]; then
    _list_users
    echo
    echo "Usage: source $_SELF <recipient-name> [Org1|Org2]"
    unset _RECIPIENT _ORG _DOMAIN _MSPID _PORT _CA _USERS_DIR _SELF _SOURCED _SCRIPTS
    unset -f _list_users _cert_field 2>/dev/null
    return 0
fi

# Accept either "recipient-042" or the full "recipient-042@org1.example.com".
case "$_RECIPIENT" in
    *@*) _FULL="$_RECIPIENT" ;;
    *)   _FULL="$_RECIPIENT@$_DOMAIN" ;;
esac

_MSP_DIR="$_USERS_DIR/$_FULL/msp"

if [ ! -d "$_MSP_DIR" ]; then
    echo "ERROR: no identity '$_FULL' in $_ORG"
    echo
    _list_users
    echo
    echo "To create named recipients, add a Specs block to crypto-config.yaml"
    echo "and regenerate (this destroys ledger state):"
    echo "    Specs:"
    echo "      - Hostname: recipient-042"
    unset _RECIPIENT _ORG _DOMAIN _MSPID _PORT _CA _USERS_DIR _FULL _MSP_DIR _SELF _SOURCED _SCRIPTS
    unset -f _list_users _cert_field 2>/dev/null
    return 1
fi

for _needed in signcerts keystore; do
    if [ -z "$(ls -A "$_MSP_DIR/$_needed" 2>/dev/null)" ]; then
        echo "ERROR: $_MSP_DIR/$_needed is empty — identity is incomplete."
        unset _RECIPIENT _ORG _DOMAIN _MSPID _PORT _CA _USERS_DIR _FULL _MSP_DIR _needed _SELF _SOURCED _SCRIPTS
        unset -f _list_users _cert_field 2>/dev/null
        return 1
    fi
done

# --- apply ----------------------------------------------------------------
export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID="$_MSPID"
export CORE_PEER_TLS_ROOTCERT_FILE="$_CA"
export CORE_PEER_MSPCONFIGPATH="$_MSP_DIR"
export CORE_PEER_ADDRESS="localhost:$_PORT"

# Exported so invoke.sh can warn when recipient_id does not match the signer.
export LEDGER_IDENTITY_CN="$_FULL"

_CERT="$(ls "$_MSP_DIR/signcerts/"*.pem 2>/dev/null | head -1)"
_OU="$(_cert_field "$_CERT" OU)"
_EXPIRY="$(openssl x509 -in "$_CERT" -noout -enddate 2>/dev/null | cut -d= -f2)"

echo "Acting as $_FULL"
echo "  MSP:     $_MSPID"
echo "  role:    ${_OU:-unknown}"
echo "  peer:    localhost:$_PORT"
echo "  expires: ${_EXPIRY:-unknown}"

if [ "${_OU:-}" != "admin" ]; then
    echo
    echo "  Note: not an admin identity. Chaincode install/approve will be"
    echo "        refused — use env-org1.sh for setup.sh and redeploy.sh."
fi

unset _RECIPIENT _ORG _DOMAIN _MSPID _PORT _CA _USERS_DIR _FULL _MSP_DIR
unset _CERT _OU _EXPIRY _needed _SELF _SOURCED _SCRIPTS
unset -f _list_users _cert_field 2>/dev/null
