import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, stat, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Interface } from 'ethers';
import { VAULT_ABI, loadCheckpoint, saveCheckpoint, runOnce, settleReadyClaims } from '../vault-settler.mjs';

const vaultAddress = '0x0000000000000000000000000000000000000001';
const id = '0x' + 'ab'.repeat(32);
const hash = '0x' + 'cd'.repeat(32);
const scope = { chainId: 100, vault: vaultAddress, deploymentBlock: 10 };
const abi = new Interface(VAULT_ABI);
function event(name, blockNumber = 10) {
  const args = name === 'ClaimRegistered'
    ? [id, vaultAddress, vaultAddress, '0x' + '00'.repeat(32), 5n, 0n]
    : [id, vaultAddress, 5n, 5n];
  return { ...abi.encodeEventLog(abi.getEvent(name), args), blockNumber, index: 0, blockHash: hash };
}
async function fixture(t) {
  const dir = await mkdtemp(join(tmpdir(), 'vault-settler-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const path = join(dir, 'state.json');
  const state = await loadCheckpoint(path, scope);
  const ctx = {
    state, path, now: () => 1000, range: 20, confirmations: 2, batchSize: 25, backoff: 100,
    provider: {
      getBlockNumber: async () => 12, getBlock: async () => ({ hash }), getLogs: async () => [event('ClaimRegistered')],
      getTransactionReceipt: async () => null, getTransactionCount: async () => 0,
      broadcastTransaction: async () => { ctx.broadcasts++; return { hash }; },
    },
    vault: { settlementStatus: async () => 2n },
    prepare: async () => ({ hash, rawTx: '0x1234', nonce: 0 }),
    signerAddress: vaultAddress, broadcasts: 0,
  };
  return ctx;
}
test('empty start reconstructs historical registration and ignores duplicate events', async t => {
  const c = await fixture(t); c.provider.getLogs = async () => [event('ClaimRegistered'), event('ClaimRegistered')];
  await runOnce(c); assert.equal(Object.keys(c.state.pending).length, 1); assert.equal(c.state.cursorBlock, 10);
  assert.equal(c.broadcasts, 0); assert.equal((await stat(c.path)).mode & 0o777, 0o600);
});
test('paid getter reconciles a registration even without its paid event', async t => {
  const c = await fixture(t); c.vault.settlementStatus = async () => 1n;
  await runOnce(c); assert.equal(Object.keys(c.state.pending).length, 0);
});
test('paid event removes a historical claim', async t => {
  const c = await fixture(t); c.provider.getLogs = async () => [event('ClaimRegistered'), { ...event('ClaimPaid'), index: 1 }];
  await runOnce(c); assert.equal(Object.keys(c.state.pending).length, 0);
});
test('corrupt or mismatched checkpoints fail closed and preserve bytes', async t => {
  const c = await fixture(t); await writeFile(c.path, '{broken');
  await assert.rejects(loadCheckpoint(c.path, scope)); assert.equal(await readFile(c.path, 'utf8'), '{broken');
  await saveCheckpoint(c.path, { ...c.state, vault: '0x0000000000000000000000000000000000000002' });
  await assert.rejects(loadCheckpoint(c.path, scope), /scope/);
});
test('interrupted temporary write does not replace valid checkpoint', async t => {
  const c = await fixture(t); await saveCheckpoint(c.path, c.state); await writeFile(c.path + '.tmp', '{broken');
  const restored = await loadCheckpoint(c.path, scope); assert.equal(restored.cursorBlock, 9);
});
test('reorg resets scan cursor and reconciles stale claims', async t => {
  const c = await fixture(t); await runOnce(c);
  c.provider.getBlock = async () => ({ hash: '0x' + 'ee'.repeat(32) }); c.provider.getLogs = async () => [];
  c.now = () => 100000; c.vault.settlementStatus = async () => 0n;
  await runOnce(c); assert.equal(Object.keys(c.state.pending).length, 0);
});
test('RPC failure during log scan cannot advance checkpoint', async t => {
  const c = await fixture(t); c.provider.getLogs = async () => { throw new Error('credential-url'); };
  await assert.rejects(runOnce(c)); assert.equal(c.state.cursorBlock, 9);
});
test('sign and persist before broadcast; restart rebroadcasts identical transaction after timeout', async t => {
  const c = await fixture(t); c.vault.settlementStatus = async () => 5n;
  c.provider.broadcastTransaction = async () => { throw new Error('secret URL'); };
  await runOnce(c);
  const persisted = await loadCheckpoint(c.path, scope);
  assert.equal(persisted.pending[id].submitted.hash, hash);
  assert.ok(!(await readFile(c.path, 'utf8')).includes('secret'));
  c.state = persisted; c.provider.broadcastTransaction = async tx => { assert.equal(tx, '0x1234'); c.broadcasts++; };
  await runOnce(c); assert.equal(c.broadcasts, 1);
  assert.ok(c.state.pending[id].submitted);
});
test('reverted adapter receipt keeps claim pending with backoff', async t => {
  const c = await fixture(t); c.vault.settlementStatus = async () => 5n; await runOnce(c);
  c.provider.getTransactionReceipt = async () => ({ status: 0, blockNumber: 10 });
  await runOnce(c); assert.ok(c.state.pending[id]); assert.ok(!c.state.pending[id].submitted);
  assert.ok(c.state.pending[id].nextAttemptAt > c.now());
});
test('lost receipt retains work until latest nonce proves consumption', async t => {
  const c = await fixture(t); c.vault.settlementStatus = async () => 5n; await runOnce(c);
  c.provider.getTransactionCount = async () => 1; c.vault.settlementStatus = async () => 1n;
  await runOnce(c); assert.equal(Object.keys(c.state.pending).length, 0);
});
test('pending transaction blocks new nonce allocation even if another executor pays', async t => {
  const c = await fixture(t); c.vault.settlementStatus = async () => 5n; await runOnce(c);
  c.vault.settlementStatus = async () => 1n; await runOnce(c);
  assert.ok(c.state.pending[id].submitted);
});
test('failed status read retains claim and stores no RPC error', async t => {
  const c = await fixture(t); c.vault.settlementStatus = async () => { throw new Error('secret-url'); };
  await runOnce(c); assert.ok(c.state.pending[id]);
  assert.ok(!(await readFile(c.path, 'utf8')).includes('secret-url'));
});
test('paid reconciliation uses the scanned block so cursor reorg recovery covers deletion', async t => {
  const c = await fixture(t);
  c.vault.settlementStatus = async (id, options) => { assert.equal(options.blockTag, 10); return 1n; };
  await runOnce(c); assert.equal(Object.keys(c.state.pending).length, 0);
});
test('unconfirmed receipt cannot release the nonce', async t => {
  const c = await fixture(t); c.vault.settlementStatus = async () => 5n; await runOnce(c);
  c.provider.getTransactionReceipt = async () => ({ status: 1, blockNumber: 12 });
  await runOnce(c); assert.ok(c.state.pending[id].submitted);
});
test('disk failure cannot leave an unpersisted transaction eligible for broadcast', async t => {
  const c = await fixture(t); c.vault.settlementStatus = async () => 5n;
  c.state.pending[id] = { attempts: 0, nextAttemptAt: 0 };
  await writeFile(c.path, 'blocked'); c.path = join(c.path, 'state.json');
  await assert.rejects(settleReadyClaims(c));
  assert.equal(c.broadcasts, 0); assert.ok(!c.state.pending[id].submitted);
});
