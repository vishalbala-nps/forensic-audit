#!/usr/bin/env bash
#
# End-to-end test of the ledger layer. Run after setup.sh.
#
#   ./scripts/new-recipient.sh user-042          # once, after each setup.sh
#   source ./scripts/env-recipient.sh user-042
#   ./scripts/smoke-test.sh
#
# Records name the identity that submits them, so this must run as a recipient
# rather than as an org admin -- the chaincode rejects a record whose
# recipient_id does not match the submitting certificate.
#
# A fresh watermark is generated each run, so it is safe to run repeatedly
# against an existing ledger.
#
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_tools jq openssl peer
require_env

PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

# Two-step expansion: under `set -u`, pattern removal on an unset variable is
# a fatal error, so a one-liner would abort before the guard below could run.
RECIPIENT="${LEDGER_IDENTITY_CN:-}"
RECIPIENT="${RECIPIENT%%@*}"

if [ -z "$RECIPIENT" ]; then
    echo "ERROR: no recipient identity in scope."
    echo
    echo "The chaincode requires records to be submitted by the recipient they"
    echo "name, so an admin identity will not work here."
    echo
    echo "  ./scripts/new-recipient.sh user-042"
    echo "  source ./scripts/env-recipient.sh user-042"
    exit 1
fi

if [ "$RECIPIENT" = "Admin" ]; then
    echo "ERROR: running as an org admin."
    echo "Admin cannot submit records under the identity check --"
    echo "source env-recipient.sh with a recipient identity instead."
    exit 1
fi

WM="$(openssl rand -hex 10)"
DIGEST="$(echo -n demo | openssl dgst -sha256 | awk '{print $2}')"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

make_record() {
    jq -n --arg wm "$1" --arg d "$DIGEST" --arg ts "$NOW" --arg rcpt "$RECIPIENT" '{
        record_id: ("rec-" + $wm),
        watermark_id: $wm,
        recipient_id: $rcpt,
        document_hash: $d,
        watermarked_doc_hash: $d,
        timestamp: $ts,
        pqc_algorithm: "ML-DSA-65",
        signature: "c3R1Yg==",
        recipient_pubkey_fingerprint: $d
    }'
}

invoke_raw() {
    local file="$1"; shift
    local peers=(--peerAddresses localhost:7051 --tlsRootCertFiles "$ORG1_CA")
    if [ "${1:-both}" = "both" ]; then
        peers+=(--peerAddresses localhost:9051 --tlsRootCertFiles "$ORG2_CA")
    fi
    peer chaincode invoke \
        -o "$ORDERER_ADDR" --ordererTLSHostnameOverride "$ORDERER_HOSTNAME" \
        --tls --cafile "$ORDERER_CA" \
        -C "$CHANNEL_NAME" -n "$CC_NAME" \
        "${peers[@]}" --waitForEvent \
        -c "{\"function\":\"RecordDecryption\",\"Args\":[$(jq -Rs 'rtrimstr("\n")' "$file")]}" 2>&1
}

query_raw() {
    peer chaincode query -C "$CHANNEL_NAME" -n "$CC_NAME" \
        -c "{\"function\":\"LookupByWatermark\",\"Args\":[\"$1\"]}" 2>&1
}

echo "Testing chaincode '$CC_NAME' on channel '$CHANNEL_NAME'"
echo "Submitting as:          $RECIPIENT ($CORE_PEER_LOCALMSPID)"
echo "Watermark for this run: $WM"
echo

# ---------------------------------------------------------------- happy path
echo "[1] Submit a valid record"
make_record "$WM" > "$TMP/valid.json"
OUT=$(invoke_raw "$TMP/valid.json" both)
if echo "$OUT" | grep -q "status (VALID)"; then
    ok "committed as VALID"
else
    bad "did not commit"
    echo "$OUT" | sed 's/^/        /'
fi

echo "[2] Read it back from Org1"
OUT=$(query_raw "$WM")
if echo "$OUT" | jq -e --arg wm "$WM" '.watermark_id == $wm' >/dev/null 2>&1; then
    ok "record returned with matching watermark_id"
else
    bad "lookup did not return the record"
    echo "$OUT" | sed 's/^/        /'
fi

echo "[3] Read it back from Org2's peer"
OUT=$(CORE_PEER_LOCALMSPID=Org2MSP \
      CORE_PEER_TLS_ROOTCERT_FILE="$ORG2_CA" \
      CORE_PEER_MSPCONFIGPATH="$ORG_DIR/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp" \
      CORE_PEER_ADDRESS=localhost:9051 \
      peer chaincode query -C "$CHANNEL_NAME" -n "$CC_NAME" \
      -c "{\"function\":\"LookupByWatermark\",\"Args\":[\"$WM\"]}" 2>&1)
if echo "$OUT" | jq -e --arg wm "$WM" '.watermark_id == $wm' >/dev/null 2>&1; then
    ok "both organizations return the same record"
else
    bad "Org2 did not return the record"
    echo "$OUT" | sed 's/^/        /'
fi

# --------------------------------------------------------- expected failures
echo "[4] Reject a duplicate watermark"
OUT=$(invoke_raw "$TMP/valid.json" both)
if echo "$OUT" | grep -qi "already exists"; then
    ok "duplicate rejected at endorsement"
else
    bad "duplicate was not rejected"
    echo "$OUT" | sed 's/^/        /'
fi

echo "[5] Reject a malformed watermark_id"
make_record "NOT-HEX" > "$TMP/bad-wm.json"
OUT=$(invoke_raw "$TMP/bad-wm.json" both)
if echo "$OUT" | grep -qi "20 lowercase hex"; then
    ok "format validation fired"
else
    bad "malformed watermark_id was not rejected"
    echo "$OUT" | sed 's/^/        /'
fi

echo "[6] Reject a record missing a required field"
make_record "$(openssl rand -hex 10)" | jq 'del(.signature)' > "$TMP/no-sig.json"
OUT=$(invoke_raw "$TMP/no-sig.json" both)
if echo "$OUT" | grep -qi "missing required field: signature"; then
    ok "missing-field validation fired"
else
    bad "record missing signature was accepted"
    echo "$OUT" | sed 's/^/        /'
fi

echo "[7] Unknown watermark returns not-found"
OUT=$(query_raw "ffffffffffffffffffff")
if echo "$OUT" | grep -qi "no record found"; then
    ok "not-found error returned"
else
    bad "unexpected response for unknown watermark"
    echo "$OUT" | sed 's/^/        /'
fi

# --------------------------------------------------------- identity binding
echo "[8] Reject a record naming a different recipient"
WM_IMP="$(openssl rand -hex 10)"
OTHER="not-$RECIPIENT"
make_record "$WM_IMP" | jq --arg r "$OTHER" '.recipient_id = $r' > "$TMP/impersonate.json"
OUT=$(invoke_raw "$TMP/impersonate.json" both)
if echo "$OUT" | grep -qi "identity mismatch"; then
    ok "cannot submit a record naming someone else"
else
    bad "impersonation accepted -- is ALLOW_ADMIN_SUBMIT true, or the check missing?"
    echo "$OUT" | sed 's/^/        /'
fi

echo "[9] WhoAmI reports the submitting identity"
OUT=$(peer chaincode query -C "$CHANNEL_NAME" -n "$CC_NAME" \
      -c '{"function":"WhoAmI","Args":[]}' 2>&1)
if echo "$OUT" | jq -e --arg r "$RECIPIENT" '.username == $r' >/dev/null 2>&1; then
    ok "chaincode sees username '$RECIPIENT'"
else
    bad "WhoAmI did not report the expected username"
    echo "$OUT" | sed 's/^/        /'
fi

# -------------------------------------------------------- endorsement policy
echo "[10] Single-org endorsement is rejected at commit"
WM_SINGLE="$(openssl rand -hex 10)"
make_record "$WM_SINGLE" > "$TMP/single.json"
invoke_raw "$TMP/single.json" single >/dev/null 2>&1
sleep 3
OUT=$(query_raw "$WM_SINGLE")
if echo "$OUT" | grep -qi "no record found"; then
    ok "policy enforced -- record was not written"
else
    bad "a single-org endorsement was accepted (check the endorsement policy)"
    echo "$OUT" | sed 's/^/        /'
fi

echo "[11] Audit trail includes the record"
OUT=$(peer chaincode query -C "$CHANNEL_NAME" -n "$CC_NAME" \
      -c '{"function":"GetAllRecords","Args":[]}' 2>&1)
if echo "$OUT" | jq -e --arg wm "$WM" 'map(.watermark_id) | index($wm)' >/dev/null 2>&1; then
    ok "GetAllRecords contains this run's record"
else
    bad "record missing from GetAllRecords"
    echo "$OUT" | sed 's/^/        /'
fi

echo
echo "-------------------------------"
echo "  passed: $PASS    failed: $FAIL"
echo "-------------------------------"

if [ "$FAIL" -gt 0 ]; then
    echo
    echo "Chaincode logs:  $SCRIPT_DIR/logs.sh cc"
    echo "Peer errors:     $SCRIPT_DIR/logs.sh errors"
    echo "Your identity:   peer chaincode query -C $CHANNEL_NAME -n $CC_NAME -c '{\"function\":\"WhoAmI\",\"Args\":[]}'"
    exit 1
fi
