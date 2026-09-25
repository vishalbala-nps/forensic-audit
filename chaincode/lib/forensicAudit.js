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

class ForensicAudit extends Contract {

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

        if (await this.RecordExists(ctx, wmId)) {
            throw new Error(`a record for watermark ${wmId} already exists`);
        }

        const stored = stringify(sortKeysRecursive(record));
        await ctx.stub.putState(wmId, Buffer.from(stored));
        ctx.stub.setEvent('DecryptionRecorded', Buffer.from(stored));
        return stored;
    }

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
}

module.exports = ForensicAudit;