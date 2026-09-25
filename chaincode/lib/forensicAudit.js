'use strict';

const stringify = require('json-stringify-deterministic');
const sortKeysRecursive = require('sort-keys-recursive');
const { Contract } = require('fabric-contract-api');

const WM_PATTERN = /^[0-9a-f]{20}$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;

const REQUIRED_FIELDS = [
    'record_id',
    'watermark_id',
    'recipient_id',
    'document_hash',
    'watermarked_doc_hash',
    'timestamp',
    'pqc_algorithm',
    'signature',
    'recipient_pubkey_fingerprint',
];

// When true, an identity with OU=admin may submit a record naming any
// recipient. Convenient for testing, but it weakens the guarantee: an
// administrator could then fabricate a record against someone else.
// Keep false for the demo, and say so in the report.
const ALLOW_ADMIN_SUBMIT = false;

class ForensicAudit extends Contract {

    // ---------------------------------------------------------------- write

    async RecordDecryption(ctx, recordJSON) {
        let record;
        try {
            record = JSON.parse(recordJSON);
        } catch (err) {
            throw new Error('recordJSON is not valid JSON');
        }

        for (const field of REQUIRED_FIELDS) {
            if (record[field] === undefined || record[field] === '') {
                throw new Error(`missing required field: ${field}`);
            }
        }

        const wmId = record.watermark_id;
        if (!WM_PATTERN.test(wmId)) {
            throw new Error('watermark_id must be exactly 20 lowercase hex characters');
        }
        if (!SHA256_PATTERN.test(record.document_hash)) {
            throw new Error('document_hash must be a 64-char lowercase hex SHA-256 digest');
        }
        if (!SHA256_PATTERN.test(record.watermarked_doc_hash)) {
            throw new Error('watermarked_doc_hash must be a 64-char lowercase hex SHA-256 digest');
        }

        this._assertSubmitterIsRecipient(ctx, record.recipient_id);

        if (await this.RecordExists(ctx, wmId)) {
            throw new Error(`a record for watermark ${wmId} already exists`);
        }

        const stored = stringify(sortKeysRecursive(record));
        await ctx.stub.putState(wmId, Buffer.from(stored));
        ctx.stub.setEvent('DecryptionRecorded', Buffer.from(stored));
        return stored;
    }

    // ---------------------------------------------------------------- reads

    async LookupByWatermark(ctx, watermark_id) {
        const recordJSON = await ctx.stub.getState(watermark_id);
        if (!recordJSON || recordJSON.length === 0) {
            throw new Error(`no record found for watermark ${watermark_id}`);
        }
        return recordJSON.toString();
    }

    async RecordExists(ctx, watermark_id) {
        const recordJSON = await ctx.stub.getState(watermark_id);
        return recordJSON !== null && recordJSON.length > 0;
    }

    async GetAllRecords(ctx) {
        const results = [];
        const iterator = await ctx.stub.getStateByRange('', '');
        let res = await iterator.next();
        while (!res.done) {
            const strValue = res.value.value.toString('utf8');
            try {
                results.push(JSON.parse(strValue));
            } catch (err) {
                results.push({ watermark_id: res.value.key, raw: strValue });
            }
            res = await iterator.next();
        }
        await iterator.close();
        return JSON.stringify(results);
    }

    /**
     * Who does the ledger think you are? Invaluable when the identity check
     * rejects you and you need to know what CN the peer actually saw.
     *
     *   peer chaincode query -C mychannel -n forensic \
     *     -c '{"function":"WhoAmI","Args":[]}'
     */
    async WhoAmI(ctx) {
        const raw = ctx.clientIdentity.getID();
        return JSON.stringify({
            msp_id: ctx.clientIdentity.getMSPID(),
            common_name: this._commonName(raw),
            username: this._stripDomain(this._commonName(raw)),
            is_admin: this._isAdmin(ctx),
            raw_id: raw,
        });
    }

    // ------------------------------------------------------------ internals

    _assertSubmitterIsRecipient(ctx, recipientId) {
        const cn = this._commonName(ctx.clientIdentity.getID());
        if (!cn) {
            throw new Error('could not determine the submitting identity');
        }

        const submitter = this._stripDomain(cn);
        const claimed = this._stripDomain(recipientId);

        if (submitter === claimed) {
            return;
        }

        if (ALLOW_ADMIN_SUBMIT && this._isAdmin(ctx)) {
            return;
        }

        throw new Error(
            `identity mismatch: record names recipient_id "${recipientId}" ` +
            `but was submitted by "${cn}"`
        );
    }

    /**
     * Split the subject half of a Fabric identity string into DN components.
     *
     * getID() returns:  x509::<subject DN>::<issuer DN>
     *
     * fabric-shim renders DNs OpenSSL-style ("/OU=client/CN=x") in some
     * versions and RFC2253-style ("OU=client,CN=x") in others, so detect the
     * separator rather than assuming one. Taking parts[1] first is what keeps
     * the issuer's CN from being read as the subject's.
     */
    _subjectComponents(identityId) {
        const parts = identityId.split('::');
        const subject = parts.length >= 2 ? parts[1] : identityId;
        const sep = subject.trimStart().startsWith('/') ? '/' : ',';
        return subject.split(sep).map((s) => s.trim()).filter(Boolean);
    }

    /** All values of a subject DN field, e.g. every OU. */
    _subjectFields(identityId, field) {
        if (typeof identityId !== 'string') {
            return [];
        }
        const prefix = `${field}=`;
        return this._subjectComponents(identityId)
            .filter((c) => c.startsWith(prefix))
            .map((c) => c.slice(prefix.length).trim());
    }

    _commonName(identityId) {
        return this._subjectFields(identityId, 'CN')[0] || null;
    }

    /** "recipient-042@org1.example.com" -> "recipient-042" */
    _stripDomain(cn) {
        if (!cn) {
            return null;
        }
        const at = cn.indexOf('@');
        return at === -1 ? cn : cn.slice(0, at);
    }

    _isAdmin(ctx) {
        return this._subjectFields(ctx.clientIdentity.getID(), 'OU').includes('admin');
    }
}

module.exports = ForensicAudit;