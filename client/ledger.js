'use strict';

/**
 * ledger.js -- Stream C's Node interface to the forensic audit chaincode.
 *
 *   const ledger = require('./ledger');
 *
 *   await ledger.submitRecord(record, 'user-042');   // -> committed record
 *   await ledger.queryRecord(watermarkId);           // -> record | null
 *   await ledger.getAllRecords();
 *   await ledger.whoAmI('user-042');
 *   await ledger.close();                            // before process exit
 *
 * Talks gRPC directly to the gateway service embedded in the peer. The peer
 * discovers which organizations the endorsement policy requires, collects
 * their endorsements, submits to the orderer and waits for commit -- which is
 * why no peer addresses or endorsement logic appear here.
 *
 * Configuration by environment variable:
 *
 *   FABRIC_SAMPLES   path to fabric-samples                    (required)
 *   CHANNEL_NAME     default "mychannel"
 *   CC_NAME          default "forensic"
 *   DEFAULT_IDENTITY default "user-042"
 *   ORG1_PEER        default "localhost:7051"
 *   ORG2_PEER        default "localhost:9051"
 *
 * Running on a different machine from the peers: set ORG1_PEER/ORG2_PEER to
 * the peer's reachable address, and copy the org's tlsca certificate and the
 * recipient's msp directory across. The hostAlias below must keep matching
 * the name in the peer's TLS certificate regardless of the address you dial.
 */

const grpc = require('@grpc/grpc-js');
const { connect, signers } = require('@hyperledger/fabric-gateway');
const crypto = require('node:crypto');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');

const CHANNEL = process.env.CHANNEL_NAME || 'mychannel';
const CHAINCODE = process.env.CC_NAME || 'forensic';
const DEFAULT_IDENTITY = process.env.DEFAULT_IDENTITY || 'user-042';

const FABRIC_SAMPLES = process.env.FABRIC_SAMPLES;
const ORG_DIR = FABRIC_SAMPLES
    ? path.join(FABRIC_SAMPLES, 'test-network', 'organizations')
    : null;

const ORGS = {
    Org1MSP: {
        domain: 'org1.example.com',
        endpoint: process.env.ORG1_PEER || 'localhost:7051',
        hostAlias: 'peer0.org1.example.com',
    },
    Org2MSP: {
        domain: 'org2.example.com',
        endpoint: process.env.ORG2_PEER || 'localhost:9051',
        hostAlias: 'peer0.org2.example.com',
    },
};

const utf8 = new TextDecoder();

/**
 * A ledger operation failed.
 *
 * .kind is one of:
 *   validation  chaincode rejected the record's contents
 *   duplicate   that watermark_id is already on the ledger
 *   identity    recipient_id does not match the submitting certificate
 *   notfound    no such watermark
 *   policy      endorsement policy not satisfied
 *   config      local setup problem (missing identity, FABRIC_SAMPLES unset)
 *   network     could not reach the peer
 *   unknown     anything else
 */
class LedgerError extends Error {
    constructor(message, kind = 'unknown', cause) {
        super(message);
        this.name = 'LedgerError';
        this.kind = kind;
        if (cause) this.cause = cause;
    }
}

// ----------------------------------------------------------- identities

function requireOrgDir() {
    if (!ORG_DIR) {
        throw new LedgerError(
            'FABRIC_SAMPLES is not set -- point it at your fabric-samples directory',
            'config');
    }
    return ORG_DIR;
}

/** All identities present in the generated crypto material. */
function listIdentities() {
    const found = {};
    for (const [mspId, org] of Object.entries(ORGS)) {
        const usersDir = path.join(requireOrgDir(), 'peerOrganizations', org.domain, 'users');
        let entries;
        try {
            entries = fs.readdirSync(usersDir);
        } catch {
            continue;
        }
        for (const entry of entries) {
            const mspDir = path.join(usersDir, entry, 'msp');
            if (!fs.existsSync(path.join(mspDir, 'signcerts'))) continue;
            if (!fs.existsSync(path.join(mspDir, 'keystore'))) continue;
            const name = entry.split('@')[0];
            if (!found[name]) found[name] = { name, mspId, mspDir };
        }
    }
    return found;
}

async function firstFileIn(dir) {
    const names = (await fsp.readdir(dir)).filter((n) => !n.startsWith('.'));
    if (names.length === 0) throw new LedgerError(`no files in ${dir}`, 'config');
    return path.join(dir, names[0]);
}

// -------------------------------------------------------- gateway pool

// One gRPC connection per peer endpoint. The SDK explicitly supports sharing
// a connection across Gateway instances, so identities need not each open one.
const grpcClients = new Map();
const gateways = new Map();

async function grpcClientFor(mspId) {
    if (grpcClients.has(mspId)) return grpcClients.get(mspId);

    const org = ORGS[mspId];
    const tlsPath = path.join(
        requireOrgDir(), 'peerOrganizations', org.domain,
        'tlsca', `tlsca.${org.domain}-cert.pem`);

    let tlsRootCert;
    try {
        tlsRootCert = await fsp.readFile(tlsPath);
    } catch (err) {
        throw new LedgerError(`cannot read TLS cert at ${tlsPath}`, 'config', err);
    }

    // ssl_target_name_override: we dial an address (often localhost) but the
    // peer's certificate is issued for peer0.orgN.example.com. Without this
    // the handshake fails with an error that looks nothing like a name
    // mismatch. It is the SDK equivalent of --ordererTLSHostnameOverride.
    const client = new grpc.Client(
        org.endpoint,
        grpc.credentials.createSsl(tlsRootCert),
        { 'grpc.ssl_target_name_override': org.hostAlias });

    grpcClients.set(mspId, client);
    return client;
}

async function contractFor(identityName) {
    const name = identityName || DEFAULT_IDENTITY;
    if (gateways.has(name)) return gateways.get(name).contract;

    const identities = listIdentities();
    const info = identities[name];
    if (!info) {
        const available = Object.keys(identities).sort().join(', ') || '(none)';
        throw new LedgerError(
            `no identity "${name}". Available: ${available}. ` +
            `Create one with ./scripts/new-recipient.sh ${name}`,
            'config');
    }

    const credentials = await fsp.readFile(await firstFileIn(path.join(info.mspDir, 'signcerts')));
    const privateKeyPem = await fsp.readFile(await firstFileIn(path.join(info.mspDir, 'keystore')));

    const gateway = connect({
        client: await grpcClientFor(info.mspId),
        identity: { mspId: info.mspId, credentials },
        signer: signers.newPrivateKeySigner(crypto.createPrivateKey(privateKeyPem)),
        evaluateOptions: () => ({ deadline: Date.now() + 10_000 }),
        endorseOptions: () => ({ deadline: Date.now() + 30_000 }),
        submitOptions: () => ({ deadline: Date.now() + 10_000 }),
        commitStatusOptions: () => ({ deadline: Date.now() + 90_000 }),
    });

    const contract = gateway.getNetwork(CHANNEL).getContract(CHAINCODE);
    gateways.set(name, { gateway, contract, mspId: info.mspId });
    return contract;
}

// ------------------------------------------------------ error mapping

/**
 * Pull the chaincode's own message out of an SDK error.
 *
 * EndorseError carries .details, an array of per-peer results whose messages
 * contain the text thrown by the contract. Without this you get a generic
 * gRPC failure and none of the reason.
 */
function describe(err) {
    const parts = [];
    if (Array.isArray(err.details)) {
        for (const d of err.details) {
            if (d && d.message) parts.push(d.message);
        }
    }
    if (parts.length === 0 && err.message) parts.push(err.message);
    return parts.join('; ');
}

function classify(text) {
    if (/already exists/i.test(text)) return 'duplicate';
    if (/identity mismatch|determine the submitting identity/i.test(text)) return 'identity';
    if (/no record found/i.test(text)) return 'notfound';
    if (/ENDORSEMENT_POLICY_FAILURE/i.test(text)) return 'policy';
    if (/must be|missing required field|not valid JSON/i.test(text)) return 'validation';
    if (/UNAVAILABLE|DEADLINE_EXCEEDED|ECONNREFUSED|failed to connect/i.test(text)) return 'network';
    return 'unknown';
}

function wrap(err) {
    if (err instanceof LedgerError) return err;
    const text = describe(err);
    return new LedgerError(text, classify(text), err);
}

// -------------------------------------------------------------- public

/**
 * Write a decryption record. Resolves only after the transaction is committed
 * as VALID -- submitTransaction waits for the commit event, so a resolved
 * promise means the record is genuinely on the ledger, not merely endorsed.
 *
 * The identity must match the record's recipient_id or the chaincode rejects
 * it; identityName defaults to DEFAULT_IDENTITY.
 */
async function submitRecord(record, identityName) {
    if (!record || typeof record !== 'object' || Array.isArray(record)) {
        throw new LedgerError('record must be an object', 'validation');
    }
    if (!record.watermark_id) {
        throw new LedgerError('record is missing watermark_id', 'validation');
    }

    const name = identityName || DEFAULT_IDENTITY;
    if (record.recipient_id && record.recipient_id !== name) {
        throw new LedgerError(
            `record names recipient_id "${record.recipient_id}" but is being ` +
            `submitted as "${name}" -- the chaincode will reject this`,
            'identity');
    }

    try {
        const contract = await contractFor(name);
        // ensureAscii equivalent: JSON.stringify does not escape non-ASCII,
        // which is what the chaincode's canonical form expects.
        const result = await contract.submitTransaction(
            'RecordDecryption', JSON.stringify(record));
        return JSON.parse(utf8.decode(result));
    } catch (err) {
        throw wrap(err);
    }
}

/** Read a record by watermark ID. Returns null when there is none. */
async function queryRecord(watermarkId, identityName) {
    if (!watermarkId) {
        throw new LedgerError('watermarkId must not be empty', 'validation');
    }
    try {
        const contract = await contractFor(identityName);
        const result = await contract.evaluateTransaction('LookupByWatermark', watermarkId);
        return JSON.parse(utf8.decode(result));
    } catch (err) {
        const wrapped = wrap(err);
        if (wrapped.kind === 'notfound') return null;
        throw wrapped;
    }
}

/** Every record on the ledger, for the audit trail view. */
async function getAllRecords(identityName) {
    try {
        const contract = await contractFor(identityName);
        const result = await contract.evaluateTransaction('GetAllRecords');
        return JSON.parse(utf8.decode(result));
    } catch (err) {
        throw wrap(err);
    }
}

/** What the chaincode sees as the submitting identity. */
async function whoAmI(identityName) {
    try {
        const contract = await contractFor(identityName);
        const result = await contract.evaluateTransaction('WhoAmI');
        return JSON.parse(utf8.decode(result));
    } catch (err) {
        throw wrap(err);
    }
}

/** Close every open gateway and gRPC connection. Node will not exit without this. */
async function close() {
    for (const { gateway } of gateways.values()) gateway.close();
    for (const client of grpcClients.values()) client.close();
    gateways.clear();
    grpcClients.clear();
}

module.exports = {
    submitRecord,
    queryRecord,
    getAllRecords,
    whoAmI,
    listIdentities,
    close,
    LedgerError,
    CHANNEL,
    CHAINCODE,
};
