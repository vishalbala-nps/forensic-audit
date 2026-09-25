"""
ledger_client.py -- Stream C's public interface.

This is the ONLY thing other streams should import. The implementation behind
it (Fabric via CLI, Fabric via gateway service, or the hash-chain fallback) is
Stream C's business and may change without notice.

    from ledger_client import submit_record, query_record, LedgerError

    tx_id  = submit_record(record_dict)      # raises LedgerError on failure
    record = query_record(watermark_id)      # returns None if not found

Configuration is by environment variable:

    FABRIC_SAMPLES   path to fabric-samples          (required)
    CHANNEL_NAME     channel name                    (default: mychannel)
    CC_NAME          chaincode name                  (default: forensic)
    LEDGER_ORG       Org1 or Org2                     (default: Org1)

Implementation note: this shells out to the `peer` CLI because there is no
maintained Python SDK for Fabric. It is slow (~2-4s per submit) but has no
extra moving parts. The upgrade path is the Node gateway service -- when that
lands, only the internals of this module change, not these two signatures.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any

__all__ = ["submit_record", "query_record", "get_all_records", "LedgerError"]


# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

CHANNEL = os.environ.get("CHANNEL_NAME", "mychannel")
CHAINCODE = os.environ.get("CC_NAME", "forensic")
ORDERER_ADDR = "localhost:7050"
ORDERER_HOSTNAME = "orderer.example.com"

_ORG_PROFILES = {
    "Org1": {"msp": "Org1MSP", "domain": "org1.example.com", "port": 7051},
    "Org2": {"msp": "Org2MSP", "domain": "org2.example.com", "port": 9051},
}

# Peer prints: "txid [abc123...] committed with status (VALID) at localhost:7051"
_TXID_RE = re.compile(r"txid \[([0-9a-f]+)\] committed with status \((\w+)\)")

# Timeouts. Submit is generous because it waits for block commit (~2s) plus
# process startup, and a slow laptop under Docker can take much longer.
_SUBMIT_TIMEOUT = 90
_QUERY_TIMEOUT = 30


class LedgerError(RuntimeError):
    """A ledger operation failed.

    .stderr holds the raw peer output, which is where the real error message
    lives. Print it when debugging.
    """

    def __init__(self, message: str, stderr: str = "") -> None:
        super().__init__(message)
        self.stderr = stderr


# --------------------------------------------------------------------------
# Internals
# --------------------------------------------------------------------------

def _fabric_samples() -> Path:
    raw = os.environ.get("FABRIC_SAMPLES")
    if not raw:
        raise LedgerError(
            "FABRIC_SAMPLES is not set. Point it at your fabric-samples directory: "
            "export FABRIC_SAMPLES=~/fabric-samples"
        )
    path = Path(raw).expanduser().resolve()
    if not (path / "test-network").is_dir():
        raise LedgerError(f"{path}/test-network does not exist -- check FABRIC_SAMPLES")
    return path


def _paths() -> dict[str, Any]:
    fs = _fabric_samples()
    network = fs / "test-network"
    orgs = network / "organizations"

    org_key = os.environ.get("LEDGER_ORG", "Org1")
    if org_key not in _ORG_PROFILES:
        raise LedgerError(f"LEDGER_ORG must be Org1 or Org2, got {org_key!r}")
    profile = _ORG_PROFILES[org_key]
    domain = profile["domain"]

    return {
        "network": network,
        "bin": fs / "bin",
        "config": fs / "config",
        "msp_id": profile["msp"],
        "port": profile["port"],
        "orderer_ca": orgs / "ordererOrganizations/example.com/tlsca/tlsca.example.com-cert.pem",
        "org1_ca": orgs / "peerOrganizations/org1.example.com/tlsca/tlsca.org1.example.com-cert.pem",
        "org2_ca": orgs / "peerOrganizations/org2.example.com/tlsca/tlsca.org2.example.com-cert.pem",
        "msp_dir": orgs / f"peerOrganizations/{domain}/users/Admin@{domain}/msp",
    }


def _peer_env(p: dict[str, Any]) -> dict[str, str]:
    env = os.environ.copy()
    env.update({
        "PATH": f"{p['bin']}{os.pathsep}{env.get('PATH', '')}",
        "FABRIC_CFG_PATH": str(p["config"]),
        "CORE_PEER_TLS_ENABLED": "true",
        "CORE_PEER_LOCALMSPID": p["msp_id"],
        "CORE_PEER_TLS_ROOTCERT_FILE": str(
            p["org1_ca"] if p["msp_id"] == "Org1MSP" else p["org2_ca"]
        ),
        "CORE_PEER_MSPCONFIGPATH": str(p["msp_dir"]),
        "CORE_PEER_ADDRESS": f"localhost:{p['port']}",
    })
    return env


def _run(args: list[str], p: dict[str, Any], timeout: int) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            args,
            cwd=str(p["network"]),
            env=_peer_env(p),
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError as exc:
        raise LedgerError(
            "`peer` binary not found. Is FABRIC_SAMPLES/bin on the PATH? "
            "Run install-fabric.sh if you have not."
        ) from exc
    except subprocess.TimeoutExpired as exc:
        raise LedgerError(
            f"peer command timed out after {timeout}s -- is the network running?"
        ) from exc


def _first_error_line(output: str) -> str:
    for line in output.splitlines():
        if "Error" in line or "error" in line:
            return line.strip()
    lines = [ln for ln in output.strip().splitlines() if ln.strip()]
    return lines[-1] if lines else "no output from peer"


def _canonical(record: dict) -> str:
    """Serialize exactly as the chaincode expects.

    ensure_ascii=False matters: json-stringify-deterministic on the chaincode
    side does not escape non-ASCII, and Python does by default. If any field
    ever holds a non-ASCII character, mismatched bytes break signature
    verification in a way that looks like a crypto bug.
    """
    return json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


# --------------------------------------------------------------------------
# Public interface
# --------------------------------------------------------------------------

def submit_record(record_dict: dict) -> str:
    """Write a decryption record to the ledger. Returns the transaction ID.

    Blocks until the transaction is committed, so a normal return means the
    record is genuinely on the ledger -- not merely endorsed. A transaction
    that fails the endorsement policy raises LedgerError rather than returning.

    Raises LedgerError on validation failure, duplicate watermark, policy
    failure, or network problems.
    """
    if not isinstance(record_dict, dict):
        raise LedgerError(f"record must be a dict, got {type(record_dict).__name__}")
    if not record_dict.get("watermark_id"):
        raise LedgerError("record is missing watermark_id")

    p = _paths()
    payload = _canonical(record_dict)

    args = [
        "peer", "chaincode", "invoke",
        "-o", ORDERER_ADDR,
        "--ordererTLSHostnameOverride", ORDERER_HOSTNAME,
        "--tls", "--cafile", str(p["orderer_ca"]),
        "-C", CHANNEL, "-n", CHAINCODE,
        "--peerAddresses", "localhost:7051", "--tlsRootCertFiles", str(p["org1_ca"]),
        "--peerAddresses", "localhost:9051", "--tlsRootCertFiles", str(p["org2_ca"]),
        "--waitForEvent",
        "-c", json.dumps({"function": "RecordDecryption", "Args": [payload]}),
    ]

    proc = _run(args, p, _SUBMIT_TIMEOUT)
    output = proc.stdout + proc.stderr

    if proc.returncode != 0:
        raise LedgerError(f"invoke failed: {_first_error_line(output)}", output)

    match = _TXID_RE.search(output)
    if not match:
        raise LedgerError(
            "could not find a commit status in the peer output -- "
            "was --waitForEvent honoured?",
            output,
        )

    tx_id, status = match.groups()
    if status != "VALID":
        raise LedgerError(
            f"transaction {tx_id} committed as {status} "
            f"(endorsement policy failure usually means too few endorsing orgs)",
            output,
        )

    return tx_id


def query_record(watermark_id: str) -> dict | None:
    """Read a record by watermark ID. Returns None if no such record exists.

    Not-found is a normal outcome and returns None; only real failures raise.
    """
    if not watermark_id:
        raise LedgerError("watermark_id must not be empty")

    p = _paths()
    args = [
        "peer", "chaincode", "query",
        "-C", CHANNEL, "-n", CHAINCODE,
        "-c", json.dumps({"function": "LookupByWatermark", "Args": [watermark_id]}),
    ]

    proc = _run(args, p, _QUERY_TIMEOUT)
    combined = proc.stdout + proc.stderr

    if proc.returncode != 0:
        if "no record found" in combined or "does not exist" in combined:
            return None
        raise LedgerError(f"query failed: {_first_error_line(combined)}", combined)

    try:
        return json.loads(proc.stdout.strip())
    except json.JSONDecodeError as exc:
        raise LedgerError(f"peer returned non-JSON: {proc.stdout[:200]}", combined) from exc


def get_all_records() -> list[dict]:
    """Return every record on the ledger. For the audit-trail screen."""
    p = _paths()
    args = [
        "peer", "chaincode", "query",
        "-C", CHANNEL, "-n", CHAINCODE,
        "-c", json.dumps({"function": "GetAllRecords", "Args": []}),
    ]

    proc = _run(args, p, _QUERY_TIMEOUT)
    combined = proc.stdout + proc.stderr

    if proc.returncode != 0:
        raise LedgerError(f"query failed: {_first_error_line(combined)}", combined)

    try:
        return json.loads(proc.stdout.strip())
    except json.JSONDecodeError as exc:
        raise LedgerError(f"peer returned non-JSON: {proc.stdout[:200]}", combined) from exc


# --------------------------------------------------------------------------
# Manual check: python -m ledger_client
# --------------------------------------------------------------------------

if __name__ == "__main__":
    import datetime
    import hashlib
    import uuid

    wm = uuid.uuid4().hex[:20]
    digest = hashlib.sha256(b"ledger_client self-test").hexdigest()

    record = {
        "record_id": str(uuid.uuid4()),
        "watermark_id": wm,
        "recipient_id": "user-042",
        "document_hash": digest,
        "watermarked_doc_hash": digest,
        "timestamp": datetime.datetime.now(datetime.timezone.utc)
                     .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "pqc_algorithm": "ML-DSA-65",
        "signature": "c3R1YnNpZ25hdHVyZQ==",
        "recipient_pubkey_fingerprint": digest,
    }

    print(f"watermark:  {wm}")
    try:
        print(f"tx_id:      {submit_record(record)}")

        got = query_record(wm)
        print(f"round-trip: {'OK' if got and got['watermark_id'] == wm else 'MISMATCH'}")

        print(f"not-found:  {'OK' if query_record('f' * 20) is None else 'UNEXPECTED'}")

        try:
            submit_record(record)
            print("duplicate:  UNEXPECTED -- second write was accepted")
        except LedgerError:
            print("duplicate:  OK -- rejected")

        print(f"total records on ledger: {len(get_all_records())}")

    except LedgerError as err:
        print(f"\nFAILED: {err}")
        if err.stderr:
            print("\n--- peer output ---")
            print(err.stderr)
        raise SystemExit(1)
