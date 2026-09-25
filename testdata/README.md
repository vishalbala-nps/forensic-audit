# testdata

Fixtures for manual testing of the forensic audit chaincode.
`smoke-test.sh` generates its own records and does not use these.

Naming convention: files beginning `record-` should be **accepted** by
`RecordDecryption`; files beginning `bad-` should be **rejected**.

## Should be accepted

| File | Recipient | Watermark |
|---|---|---|
| `record-valid.json` | user-042 | `a1b2c3d4e5f60718293a` |
| `record-second-recipient.json` | user-117 | `b2c3d4e5f60718293a4b` |
| `record-third-recipient.json` | user-203 | `c3d4e5f60718293a4b5c` |

Three distinct recipients with three distinct watermarks — load all of them to
populate the audit-trail screen, then trace one back.

Submitting any of these **twice** exercises the duplicate check, so you get
that test case for free.

## Should be rejected

| File | What it tests |
|---|---|
| `bad-watermark-nonhex.json` | `watermark_id` containing non-hex characters |
| `bad-watermark-uppercase.json` | uppercase hex — the check requires lowercase |
| `bad-watermark-short.json` | 18 characters instead of 20 |
| `bad-watermark-long.json` | 22 characters instead of 20 |
| `bad-missing-signature.json` | `signature` field absent |
| `bad-missing-recipient.json` | `recipient_id` field absent |
| `bad-empty-recipient.json` | `recipient_id` present but empty string |
| `bad-document-hash.json` | `document_hash` not a 64-char SHA-256 digest |
| `bad-watermarked-hash.json` | `watermarked_doc_hash` contains non-hex characters |
| `bad-malformed.json` | not valid JSON at all — exercises the parse guard |

Each has a unique `watermark_id`, so a fixture failing for the wrong reason
(duplicate rather than the intended check) is not possible.

`bad-watermark-uppercase.json` is worth keeping even if it feels pedantic:
`uuid4().hex` produces lowercase, so an uppercase watermark means something
upstream re-cased it, and you want that caught at the ledger boundary rather
than discovered when a lookup silently misses.

## Usage

    source ./scripts/env-org1.sh

    ./scripts/invoke.sh testdata/record-valid.json
    ./scripts/query.sh a1b2c3d4e5f60718293a

    ./scripts/invoke.sh testdata/record-valid.json          # duplicate -> rejected
    ./scripts/invoke.sh testdata/bad-watermark-short.json   # format   -> rejected

    ./scripts/invoke.sh testdata/record-valid.json --single-org
    ./scripts/query.sh a1b2c3d4e5f60718293a                 # policy   -> not written

    ./scripts/query.sh --all

## Notes

`signature` values are the base64 string `stubsignatureforteestingonly`, not
real ML-DSA signatures. The chaincode stores the field opaquely and does not
verify it — verification happens in the forensic tool at trace time. Replace
these with real signatures once Stream A lands.

`document_hash` and `watermarked_doc_hash` are genuine SHA-256 digests of
placeholder strings, so they pass format validation but correspond to no real
document.

`record_id` values are UUIDv5 derived from the watermark and recipient, so they
are stable across regeneration rather than changing every time.
