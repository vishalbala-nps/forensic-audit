# Stream C — DLT / Ledger Layer

Immutable, tamper-evident audit ledger for the forensic watermarking system.
Records every decryption event on a Hyperledger Fabric ledger, keyed by the
watermark embedded in the recipient's copy, so a leaked document can be traced
back to the exact recipient and decryption session.

This repository contains **only Stream C**. Streams A (PQC crypto), B
(watermarking) and D (integration) live elsewhere and consume this one through
the two functions in [Interface contract](#interface-contract).

---

## Requirements

| | Version | Notes |
|---|---|---|
| Docker | 20.10+ | Docker Desktop users: allow at least 4 GB memory |
| Docker Compose | v2 | bundled with modern Docker |
| Node.js | 18 or 20 | chaincode runtime |
| Python | 3.10+ | `ledger_client.py` uses `dict \| None` annotations |
| Go | 1.22+ | required by Fabric's tooling, not by our code |
| `jq` | any | the scripts use it for JSON escaping |
| Hyperledger Fabric | **2.5.16** | pin this exactly — see below |

> **Pin Fabric to 2.5.16.** The install script defaults to the latest release,
> which is now v3.x. A v3 network against v2.5 documentation produces errors
> that are very hard to diagnose. If 2.5.16 is unavailable, check the
> [releases page](https://github.com/hyperledger/fabric/releases) for the
> newest 2.5.x patch and use that consistently across the whole team.

On Apple Silicon some Fabric images run under emulation and are noticeably
slow. A Linux machine is smoother if you have one.

---

## Install

### 1. Install Fabric

Do this **outside** this repository — `fabric-samples` is several hundred MB
and is deliberately not vendored here.

```bash
cd ~
curl -sSLO https://raw.githubusercontent.com/hyperledger/fabric/main/scripts/install-fabric.sh
chmod +x install-fabric.sh
./install-fabric.sh --fabric-version 2.5.16 docker samples binary
```

This pulls the Docker images, the `peer` binaries, and a matching checkout of
`fabric-samples`.

### 2. Point the scripts at it

```bash
export FABRIC_SAMPLES=~/fabric-samples
```

Add that line to your `~/.bashrc` or `~/.zshrc` — every script here needs it
and will refuse to run without it.

### 3. Clone and prepare

```bash
git clone <repo-url> stream-c
cd stream-c
chmod +x scripts/*.sh
```

### 4. Verify

```bash
docker --version && node --version && python3 --version && jq --version
ls $FABRIC_SAMPLES/test-network/network.sh
```

All five should succeed before you continue.

---

## Quick start

```bash
./scripts/setup.sh            # network up, channel created, chaincode deployed
source ./scripts/env-org1.sh  # act as Org1 for peer CLI commands
./scripts/smoke-test.sh       # 9 checks, should print "failed: 0"
```

First run takes a few minutes while Docker starts containers and npm installs
the chaincode dependencies. Subsequent runs are faster.

Try it manually:

```bash
./scripts/invoke.sh testdata/record-valid.json
./scripts/query.sh a1b2c3d4e5f60718293a
./scripts/query.sh --all
```

And from Python:

```bash
cd client && python3 ledger_client.py
```

When you are done:

```bash
./scripts/teardown.sh
```

---

## Repository layout

```
stream-c/
├── chaincode/                  Fabric smart contract (Node.js)
│   ├── index.js                exports the contract to the runtime
│   ├── package.json            MUST contain scripts.start
│   ├── npm-shrinkwrap.json     pins the exact dependency tree
│   └── lib/forensicAudit.js    RecordDecryption, LookupByWatermark, GetAllRecords
├── client/
│   ├── ledger_client.py        the interface other streams import
│   └── requirements.txt        stdlib only for now
├── scripts/                    setup, deploy, invoke, query, logs, tests
└── testdata/                   fixtures — see testdata/README.md
```

Not tracked: `fabric-samples/`, `node_modules/`, `.cc-sequence`.

---

## Interface contract

**Stream D imports these two functions and nothing else.** The implementation
behind them may change (CLI wrapper today, Node gateway service later, or the
hash-chain fallback) without affecting callers.

```python
from ledger_client import submit_record, query_record, LedgerError

tx_id  = submit_record(record_dict)   # raises LedgerError on any failure
record = query_record(watermark_id)   # returns None if not found
```

`submit_record` blocks until the transaction is committed, so a normal return
means the record is genuinely on the ledger — not merely endorsed. A
transaction rejected by the endorsement policy raises rather than returning.

`query_record` treats not-found as a normal outcome and returns `None`; only
real failures raise.

Configuration is by environment variable: `FABRIC_SAMPLES` (required),
`CHANNEL_NAME` (default `mychannel`), `CC_NAME` (default `forensic`),
`LEDGER_ORG` (`Org1` or `Org2`).

### Record schema

Every field is required. The chaincode rejects anything missing or malformed.

```json
{
  "record_id": "uuid-v4",
  "watermark_id": "exactly 20 lowercase hex characters — the ledger key",
  "recipient_id": "org-issued user ID",
  "document_hash": "SHA-256 hex of the ORIGINAL decrypted document",
  "watermarked_doc_hash": "SHA-256 hex of the watermarked copy",
  "timestamp": "ISO-8601 UTC, e.g. 2026-09-25T10:15:30Z",
  "pqc_algorithm": "ML-DSA-65",
  "signature": "base64 ML-DSA signature over canonical JSON of all other fields",
  "recipient_pubkey_fingerprint": "SHA-256 hex of the recipient's ML-DSA public key"
}
```

**Canonical serialization** — both sides must agree byte for byte or signature
verification fails:

```python
json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
```

`ensure_ascii=False` is not optional. Python escapes non-ASCII by default and
`json-stringify-deterministic` on the chaincode side does not; the first
non-ASCII character in any field would otherwise break verification in a way
that looks like a crypto bug.

---

## Scripts

| Script | Purpose |
|---|---|
| `setup.sh` | Clean start: network up, channel created, chaincode deployed |
| `teardown.sh` | Stop the network and delete all ledger data |
| `env-org1.sh` / `env-org2.sh` | **Source** these to act as that org |
| `invoke.sh <file.json>` | Submit a record (`--single-org` for the policy demo) |
| `query.sh <wm_id>` / `--all` | Read one record, or the whole audit trail |
| `redeploy.sh` | Redeploy after code changes, auto-incrementing the sequence |
| `smoke-test.sh` | 9 end-to-end checks |
| `logs.sh cc\|peer1\|peer2\|orderer\|errors` | Tail the right container |

`env-org1.sh` and `env-org2.sh` must be **sourced**, not executed — a
subprocess cannot change your shell's environment. They will tell you so if
you get it wrong.

### After editing the chaincode

```bash
./scripts/redeploy.sh
```

Not `setup.sh` — that wipes the ledger. Fabric requires the chaincode sequence
to increment by exactly one per upgrade; `redeploy.sh` tracks this in
`.cc-sequence` so you never hit the sequence-mismatch error by hand.

---

## Architecture notes

### What the ledger is for

The ML-DSA signature already proves non-repudiation: only the holder of the
recipient's private key could have produced it. What a signature cannot give
you is **existence**. An administrator with a normal database can delete the
row, and the proof vanishes without anything being forged.

The ledger makes deletion and retroactive modification detectable, without
trusting any single node operator. That is its entire job here.

### Endorsement policy

The test network's default is `MAJORITY Endorsement`, which with two
organizations means both must endorse. Every `invoke.sh` call therefore lists
both peers. Submitting with only one produces a transaction that appears to
succeed and is then marked `ENDORSEMENT_POLICY_FAILURE` at commit — check 8 in
`smoke-test.sh` verifies the record is genuinely absent afterwards.

Verify what is actually committed:

```bash
peer lifecycle chaincode querycommitted --channelID mychannel --name forensic --output json
```

The `validation_parameter` field holds the policy. Screenshot this for the
report — it is evidence rather than a claim.

### Known limitations

Stated deliberately; do not let a judge find these first.

- **Single-node Raft ordering.** Crash fault tolerant, not Byzantine. A
  malicious orderer could censor transactions. Production would use BFT
  ordering with independently operated nodes.
- **Both orgs on one machine.** The architecture enforces multi-org agreement;
  a single-laptop deployment means one person does in fact control both. The
  property is demonstrated, not physically enforced.
- **Client-supplied timestamps.** `timestamp` is set by the client, not the
  orderer. The ledger proves *ordering* (record A committed before record B),
  not wall-clock time.
- **No on-chain signature verification.** The chaincode stores `signature`
  opaquely. ML-DSA verification happens in the forensic tool at trace time,
  because liboqs inside a chaincode container is impractical to package
  offline.
- **Submission is voluntary.** Nothing currently prevents a recipient from
  decrypting and never submitting a record. The real fix is gating key release
  on a ledger acknowledgement.

---

## Troubleshooting

**Triage by symptom:**

| Symptom | Cause |
|---|---|
| Chaincode container not running at all | Packaging: missing `scripts.start`, wrong `main`, filename case |
| Container runs but every invoke fails | Contract logic — `./scripts/logs.sh cc` |
| Invoke returns 200 but no record appears | Endorsement policy — `./scripts/logs.sh errors` |

**`FABRIC_SAMPLES is not set`** — export it, see step 2.

**`Cannot find module './lib/forensicAudit'`** — filename case. `forensicaudit.js`
resolves on macOS and Windows but fails inside the Linux container.

**Sequence number errors on deploy** — use `redeploy.sh` rather than calling
`deployCC` by hand.

**Invalid character / JSON parse errors on invoke** — shell quoting. The
scripts use `jq -Rs 'rtrimstr("\n")'` to escape the payload; hand-escaping
nested quotes does not work.

**Anything else weird** — a full reset is usually faster than debugging:

```bash
./scripts/teardown.sh && ./scripts/setup.sh
```

---

## Offline / air-gapped deployment

The final system must run with no internet access. Prepare these **while
online**, then transfer by USB:

1. `docker save` every Fabric image at version 2.5.16 to `.tar` files, and
   `docker load` them on the target machine.
2. Ship `chaincode/node_modules/` — the peer's build step runs `npm install`
   and will otherwise try to reach the registry.
3. Commit `npm-shrinkwrap.json` so the dependency tree is reproducible.
4. Pre-generate crypto material with `cryptogen` and commit the output. Do not
   regenerate on demo day.
5. `pip download -r requirements.txt -d ./wheels` for any Python dependencies.

Test the result properly: disconnect the network, tear everything down, and
bring it up cold. Half-air-gapped testing on a machine that still has internet
proves nothing.

### Fallback

If Fabric setup stalls, an append-only hash-chained ledger (each record storing
the hash of its predecessor) satisfies tamper-evidence behind the same
`submit_record` / `query_record` interface. It gives tamper-*evidence* but not
distributed trust, since one actor can recompute the chain from the point of
edit onward. Document it as a deliberate scope trade-off if you fall back to it.
