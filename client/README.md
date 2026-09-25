# Ledger client

Node client for the forensic audit chaincode. Talks gRPC directly to the
gateway service embedded in a Fabric peer.

This is a **client application**. It runs wherever you run it — your laptop, a
server, a container, a recipient's machine. Nothing here runs inside the peer.
All it needs is network reach to the peer's port and an identity to sign with.

The peer's gateway discovers which organizations the endorsement policy
requires, collects their endorsements and submits to the orderer, which is why
no peer addresses or endorsement logic appear anywhere in this code.

---

## Install

```bash
npm install
```

Two dependencies, both pure JavaScript — nothing to compile.

Requires Node 18+.

---

## Environment variables

| Variable | Default | What it does |
|---|---|---|
| `FABRIC_SAMPLES` | *(none — required)* | Root of the crypto material. Either your `fabric-samples` directory, or an identity bundle from `bundle-identity.sh` |
| `DEFAULT_IDENTITY` | `user-042` | Identity used when a command is given no explicit one |
| `CHANNEL_NAME` | `mychannel` | Fabric channel |
| `CC_NAME` | `forensic` | Chaincode name |
| `ORG1_PEER` | `localhost:7051` | Address of Org1's peer |
| `ORG2_PEER` | `localhost:9051` | Address of Org2's peer |

`FABRIC_SAMPLES` is the only required one. Everything else has a working
default for a local test network.

### Local network

```bash
export FABRIC_SAMPLES=~/Projects/fabric/fabric-samples
export DEFAULT_IDENTITY=user-042
```

### Remote peer, using a bundle

```bash
export FABRIC_SAMPLES=/path/to/bundles/user-042
export DEFAULT_IDENTITY=user-042
export ORG1_PEER=192.168.1.10:7051
```

A bundle produced by `bundle-identity.sh` mirrors the `fabric-samples`
directory layout, so it drops straight into `FABRIC_SAMPLES` with no code
changes. It contains one recipient's certificate and private key plus the
org's TLS root certificate, and nothing else.

**No `/etc/hosts` entry is needed for a remote peer.** The client dials
whatever address you give and validates the peer's TLS certificate against
`peer0.orgN.example.com` via `grpc.ssl_target_name_override`.

Which of `ORG1_PEER` / `ORG2_PEER` gets used is decided by the identity's own
organization — a `user-203` identity issued by Org2 routes to `ORG2_PEER`
automatically.

---

## CLI

```
node cli.js <command> [args]
```

Every command takes an optional trailing identity name, which overrides
`DEFAULT_IDENTITY` for that call.

| Command | Purpose |
|---|---|
| `identities` | List identities found under `FABRIC_SAMPLES` |
| `whoami [identity]` | What the chaincode sees as the submitting identity |
| `submit <file.json> [identity]` | Submit a record read from a file |
| `demo [identity]` | Generate a record, submit it, read it back |
| `query <watermarkId> [identity]` | Look up one record |
| `all [identity]` | Every record on the ledger |

### Examples

```bash
node cli.js identities
node cli.js whoami user-042
node cli.js demo user-042
node cli.js submit ../testdata/record-valid.json user-042
node cli.js query a1b2c3d4e5f60718293a
node cli.js all
```

`whoami` is the fastest way to confirm the whole chain works — it proves the
identity loaded, the TLS handshake succeeded, and the chaincode is reachable.

`demo` generates a fresh 20-hex-character watermark each run, so it is safe to
run repeatedly against a live ledger.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Error — the reason is printed as `[kind] message` |
| `2` | `query` only: no record for that watermark |

---

## Using it as a module

```javascript
const ledger = require('./ledger');

// Resolves only after the transaction commits as VALID, so a resolved
// promise means the record is genuinely on the ledger.
const committed = await ledger.submitRecord(record, 'user-042');

const record = await ledger.queryRecord(watermarkId);   // record | null
const all    = await ledger.getAllRecords();
const me     = await ledger.whoAmI('user-042');
const ids    = ledger.listIdentities();                  // synchronous

await ledger.close();   // Node will not exit without this
```

`close()` matters: open gRPC connections keep the event loop alive.

Two resolved constants are also exported, handy for logging what the client is
actually pointed at:

```javascript
console.log(ledger.CHANNEL, ledger.CHAINCODE);   // "mychannel" "forensic"
```

### Errors

Every failure throws a `LedgerError` with a `.kind` field, so callers can
branch without matching strings:

| `.kind` | Meaning |
|---|---|
| `validation` | The chaincode rejected the record's contents |
| `duplicate` | That `watermark_id` is already on the ledger |
| `identity` | `recipient_id` does not match the submitting certificate |
| `notfound` | No such watermark (`queryRecord` returns `null` instead of throwing) |
| `policy` | Endorsement policy not satisfied |
| `config` | Local setup problem — unset `FABRIC_SAMPLES`, missing identity |
| `network` | Could not reach the peer |
| `unknown` | Anything else |

```javascript
try {
    await ledger.submitRecord(record, 'user-042');
} catch (err) {
    if (err.kind === 'duplicate') {
        // this decryption was already recorded
    } else if (err.kind === 'identity') {
        // submitting as the wrong recipient
    } else {
        throw err;
    }
}
```

`submitRecord` also checks locally that `record.recipient_id` matches the
identity you pass, and throws `identity` before any network round trip — the
chaincode would reject it anyway, this just fails faster and more clearly.

---

## Troubleshooting

**`[config] FABRIC_SAMPLES is not set`** — export it.

**`[config] no identity "X". Available: ...`** — the name does not exist under
`FABRIC_SAMPLES`. Run `node cli.js identities` to see what is there. With a
bundle, only that one recipient will be listed, which is intended.

**`[network] 14 UNAVAILABLE ... ECONNREFUSED`** — the peer is not reachable at
`ORG1_PEER`. Check the network is up, the address is right, and the host
firewall allows the port.

**TLS handshake failures** — the `hostAlias` in `ledger.js` must keep matching
the name in the peer's certificate (`peer0.org1.example.com`) regardless of
the address you dial. Do not change it to match the IP.

**`[identity] identity mismatch`** — the record's `recipient_id` differs from
the identity submitting it. This is the chaincode's binding check working
correctly. Run `node cli.js whoami <identity>` and compare `username` against
the record.

**`[duplicate] a record for watermark ... already exists`** — watermark IDs are
write-once by design. Use a fresh one.

**Node does not exit after your script finishes** — you did not call
`ledger.close()`.