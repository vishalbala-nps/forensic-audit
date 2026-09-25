#!/usr/bin/env node
'use strict';

/**
 * cli.js -- exercise the ledger module without writing a program.
 *
 *   node cli.js identities
 *   node cli.js whoami              [identity]
 *   node cli.js submit <file.json>  [identity]
 *   node cli.js demo                [identity]     generate and submit a record
 *   node cli.js query <watermarkId> [identity]
 *   node cli.js all                 [identity]
 *
 * Identity defaults to DEFAULT_IDENTITY (user-042).
 */

const fs = require('node:fs/promises');
const crypto = require('node:crypto');
const ledger = require('./ledger');

function sha256(text) {
    return crypto.createHash('sha256').update(text).digest('hex');
}

function demoRecord(recipient) {
    const watermarkId = crypto.randomUUID().replace(/-/g, '').slice(0, 20);
    const digest = sha256(`demo-document-${watermarkId}`);
    return {
        record_id: crypto.randomUUID(),
        watermark_id: watermarkId,
        recipient_id: recipient,
        document_hash: digest,
        watermarked_doc_hash: sha256(`demo-document-${watermarkId}-wm`),
        timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
        pqc_algorithm: 'ML-DSA-65',
        signature: Buffer.from('stub-signature-for-testing').toString('base64'),
        recipient_pubkey_fingerprint: sha256(`pubkey-${recipient}`),
    };
}

function out(value) {
    console.log(JSON.stringify(value, null, 2));
}

async function main() {
    const [command, ...rest] = process.argv.slice(2);

    switch (command) {
        case 'identities': {
            const found = ledger.listIdentities();
            out(Object.values(found)
                .map(({ name, mspId }) => ({ name, msp_id: mspId }))
                .sort((a, b) => a.name.localeCompare(b.name)));
            break;
        }

        case 'whoami':
            out(await ledger.whoAmI(rest[0]));
            break;

        case 'submit': {
            const [file, identity] = rest;
            if (!file) throw new Error('usage: cli.js submit <file.json> [identity]');
            const record = JSON.parse(await fs.readFile(file, 'utf8'));
            const committed = await ledger.submitRecord(record, identity);
            console.log('committed:');
            out(committed);
            break;
        }

        case 'demo': {
            const identity = rest[0] || process.env.DEFAULT_IDENTITY || 'user-042';
            const record = demoRecord(identity);
            console.log(`submitting watermark ${record.watermark_id} as ${identity}`);
            await ledger.submitRecord(record, identity);
            const readBack = await ledger.queryRecord(record.watermark_id, identity);
            console.log('read back:');
            out(readBack);
            break;
        }

        case 'query': {
            const [watermarkId, identity] = rest;
            if (!watermarkId) throw new Error('usage: cli.js query <watermarkId> [identity]');
            const record = await ledger.queryRecord(watermarkId, identity);
            if (record === null) {
                console.log(`no record for watermark ${watermarkId}`);
                process.exitCode = 2;
            } else {
                out(record);
            }
            break;
        }

        case 'all':
            out(await ledger.getAllRecords(rest[0]));
            break;

        default:
            console.error(`Usage: node cli.js <command> [args]

  identities                     list usable identities
  whoami              [identity] what the chaincode sees
  submit <file.json>  [identity] submit a record from a file
  demo                [identity] generate, submit and read back a record
  query <watermarkId> [identity] look up one record
  all                 [identity] every record on the ledger
`);
            process.exitCode = 1;
    }
}

main()
    .catch((err) => {
        if (err instanceof ledger.LedgerError) {
            console.error(`[${err.kind}] ${err.message}`);
        } else {
            console.error(err.message);
        }
        process.exitCode = 1;
    })
    .finally(() => ledger.close());
