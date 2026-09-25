/*
 * SPDX-License-Identifier: Apache-2.0
*/

'use strict';
const sinon = require('sinon');
const chai = require('chai');
const sinonChai = require('sinon-chai');
const expect = chai.expect;

const { Context } = require('fabric-contract-api');
const { ChaincodeStub } = require('fabric-shim');

const ForensicAudit = require('../lib/forensicAudit.js');

chai.use(sinonChai);

describe('Forensic Audit Tests', () => {
    let transactionContext, chaincodeStub, contract, record;

    beforeEach(() => {
        transactionContext = new Context();

        chaincodeStub = sinon.createStubInstance(ChaincodeStub);
        transactionContext.setChaincodeStub(chaincodeStub);
        chaincodeStub.states = {};

        chaincodeStub.putState.callsFake(async (key, value) => {
            chaincodeStub.states[key] = value;
        });

        // Like a real peer, a missing key yields an empty buffer.
        chaincodeStub.getState.callsFake(async (key) => {
            return chaincodeStub.states[key] || Buffer.alloc(0);
        });

        chaincodeStub.getStateByRange.callsFake(async () => {
            const entries = Object.entries(chaincodeStub.states)
                .sort(([a], [b]) => a.localeCompare(b));
            let i = 0;
            return {
                next: async () => {
                    if (i < entries.length) {
                        const [key, value] = entries[i++];
                        return { value: { key, value }, done: false };
                    }
                    return { done: true };
                },
                close: sinon.stub().resolves(),
            };
        });

        contract = new ForensicAudit();

        record = {
            record_id: 'rec-001',
            watermark_id: 'a1b2c3d4e5f60718293a',
            recipient_id: 'analyst-42',
            document_hash: 'a'.repeat(64),
            watermarked_doc_hash: 'b'.repeat(64),
            timestamp: '2026-09-25T10:00:00Z',
            pqc_algorithm: 'ML-DSA-65',
            signature: 'c2lnbmF0dXJl',
            recipient_pubkey_fingerprint: 'fp-1234',
        };
    });

    describe('Test RecordDecryption', () => {
        it('should store the record under its watermark_id and emit an event', async () => {
            const ret = await contract.RecordDecryption(transactionContext, JSON.stringify(record));

            expect(JSON.parse(ret)).to.eql(record);
            const stored = await chaincodeStub.getState(record.watermark_id);
            expect(stored.toString()).to.equal(ret);
            expect(chaincodeStub.setEvent).to.have.been.calledOnceWith('DecryptionRecorded', sinon.match.instanceOf(Buffer));
            expect(chaincodeStub.setEvent.firstCall.args[1].toString()).to.equal(ret);
        });

        it('should store the record with deterministically sorted keys', async () => {
            const ret = await contract.RecordDecryption(transactionContext, JSON.stringify(record));

            expect(Object.keys(JSON.parse(ret))).to.eql(Object.keys(record).sort());
        });

        it('should return error when recordJSON is not valid JSON', async () => {
            try {
                await contract.RecordDecryption(transactionContext, '{not json');
                expect.fail('RecordDecryption should have failed');
            } catch (err) {
                expect(err.message).to.equal('recordJSON is not valid JSON');
            }
        });

        it('should return error when a required field is missing', async () => {
            delete record.signature;
            try {
                await contract.RecordDecryption(transactionContext, JSON.stringify(record));
                expect.fail('RecordDecryption should have failed');
            } catch (err) {
                expect(err.message).to.equal('missing required field: signature');
            }
        });

        it('should return error when a required field is empty', async () => {
            record.recipient_id = '';
            try {
                await contract.RecordDecryption(transactionContext, JSON.stringify(record));
                expect.fail('RecordDecryption should have failed');
            } catch (err) {
                expect(err.message).to.equal('missing required field: recipient_id');
            }
        });

        ['A1B2C3D4E5F60718293A', 'a1b2c3', 'a1b2c3d4e5f60718293a00', 'z1b2c3d4e5f60718293a'].forEach((wmId) => {
            it(`should return error for invalid watermark_id "${wmId}"`, async () => {
                record.watermark_id = wmId;
                try {
                    await contract.RecordDecryption(transactionContext, JSON.stringify(record));
                    expect.fail('RecordDecryption should have failed');
                } catch (err) {
                    expect(err.message).to.equal('watermark_id must be exactly 20 lowercase hex characters');
                }
            });
        });

        it('should return error for an invalid document_hash', async () => {
            record.document_hash = 'A'.repeat(64);
            try {
                await contract.RecordDecryption(transactionContext, JSON.stringify(record));
                expect.fail('RecordDecryption should have failed');
            } catch (err) {
                expect(err.message).to.equal('document_hash must be a 64-char lowercase hex SHA-256 digest');
            }
        });

        it('should return error for an invalid watermarked_doc_hash', async () => {
            record.watermarked_doc_hash = 'b'.repeat(63);
            try {
                await contract.RecordDecryption(transactionContext, JSON.stringify(record));
                expect.fail('RecordDecryption should have failed');
            } catch (err) {
                expect(err.message).to.equal('watermarked_doc_hash must be a 64-char lowercase hex SHA-256 digest');
            }
        });

        it('should return error when a record for the watermark already exists', async () => {
            await contract.RecordDecryption(transactionContext, JSON.stringify(record));
            try {
                await contract.RecordDecryption(transactionContext, JSON.stringify(record));
                expect.fail('RecordDecryption should have failed');
            } catch (err) {
                expect(err.message).to.equal(`a record for watermark ${record.watermark_id} already exists`);
            }
        });

        it('should propagate a putState failure', async () => {
            chaincodeStub.putState.rejects('failed inserting key');
            try {
                await contract.RecordDecryption(transactionContext, JSON.stringify(record));
                expect.fail('RecordDecryption should have failed');
            } catch (err) {
                expect(err.name).to.equal('failed inserting key');
            }
            expect(chaincodeStub.setEvent).to.not.have.been.called;
        });
    });

    describe('Test LookupByWatermark', () => {
        it('should return the stored record', async () => {
            await contract.RecordDecryption(transactionContext, JSON.stringify(record));

            const ret = await contract.LookupByWatermark(transactionContext, record.watermark_id);
            expect(JSON.parse(ret)).to.eql(record);
        });

        it('should return error when no record exists (empty buffer)', async () => {
            try {
                await contract.LookupByWatermark(transactionContext, 'ffffffffffffffffffff');
                expect.fail('LookupByWatermark should have failed');
            } catch (err) {
                expect(err.message).to.equal('no record found for watermark ffffffffffffffffffff');
            }
        });

        it('should return error when getState returns null', async () => {
            chaincodeStub.getState.resolves(null);
            try {
                await contract.LookupByWatermark(transactionContext, 'ffffffffffffffffffff');
                expect.fail('LookupByWatermark should have failed');
            } catch (err) {
                expect(err.message).to.equal('no record found for watermark ffffffffffffffffffff');
            }
        });
    });

    describe('Test RecordExists', () => {
        it('should return true when the record exists', async () => {
            await contract.RecordDecryption(transactionContext, JSON.stringify(record));

            expect(await contract.RecordExists(transactionContext, record.watermark_id)).to.equal(true);
        });

        it('should return false when the record does not exist', async () => {
            expect(await contract.RecordExists(transactionContext, 'ffffffffffffffffffff')).to.equal(false);
        });

        it('should return false when getState returns null', async () => {
            chaincodeStub.getState.resolves(null);

            expect(await contract.RecordExists(transactionContext, 'ffffffffffffffffffff')).to.equal(false);
        });
    });

    describe('Test GetAllRecords', () => {
        it('should return an empty array when the ledger is empty', async () => {
            const ret = await contract.GetAllRecords(transactionContext);
            expect(JSON.parse(ret)).to.eql([]);
        });

        it('should return all stored records', async () => {
            const second = Object.assign({}, record, {
                record_id: 'rec-002',
                watermark_id: 'ffffffffffffffffffff',
                recipient_id: 'analyst-7',
            });
            await contract.RecordDecryption(transactionContext, JSON.stringify(record));
            await contract.RecordDecryption(transactionContext, JSON.stringify(second));

            const ret = JSON.parse(await contract.GetAllRecords(transactionContext));
            expect(ret).to.eql([record, second]);
        });

        it('should wrap non-JSON values with their key', async () => {
            await contract.RecordDecryption(transactionContext, JSON.stringify(record));
            chaincodeStub.states['0000000000000000000a'] = Buffer.from('non-json-value');

            const ret = JSON.parse(await contract.GetAllRecords(transactionContext));
            expect(ret).to.eql([
                { watermark_id: '0000000000000000000a', raw: 'non-json-value' },
                record,
            ]);
        });
    });
});
