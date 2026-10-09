import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, stat, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { Interface, Wallet, keccak256 } from 'ethers';
import { VAULT_ABI, loadCheckpoint, saveCheckpoint, runOnce, reconcileClaims, settleReadyClaims } from '../vault-settler.mjs';

const vaultAddress = '0x0000000000000000000000000000000000000001';
const id = '0x' + 'ab'.repeat(32);
const hash = '0x' + 'cd'.repeat(32);
const signer = new Wallet('0x' + '01'.repeat(32));
const scope = { chainId: 100, vault: vaultAddress, deploymentBlock: 10, signerAddress: signer.address };
const abi = new Interface(VAULT_ABI);
async function signedSettlement(overrides = {}, wallet = signer) {
  const rawTx = await wallet.signTransaction({ chainId: 100, nonce: 0, to: vaultAddress,
    data: abi.encodeFunctionData('settle', [id]), value: 0, gasLimit: 700000, gasPrice: 1, ...overrides });
  return { hash: keccak256(rawTx), rawTx, nonce: overrides.nonce ?? 0 };
}
const submitted = await signedSettlement();
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
    prepare: async () => ({ ...submitted }),
    signerAddress: signer.address, broadcasts: 0,
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
  assert.equal(persisted.pending[id].submitted.hash, submitted.hash);
  assert.ok(!(await readFile(c.path, 'utf8')).includes('secret'));
  c.state = persisted; c.provider.broadcastTransaction = async tx => { assert.equal(tx, submitted.rawTx); c.broadcasts++; };
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
test('checkpoint success requires file and directory durability before broadcast', async t => {
  const c = await fixture(t); const trace = [];
  const io = {
    open: async path => ({
      chmod: async () => {}, writeFile: async () => trace.push('write'),
      sync: async () => trace.push(path.endsWith('.tmp') ? 'file_sync' : 'directory_sync'),
      close: async () => {},
    }),
    rename: async () => trace.push('rename'),
  };
  await saveCheckpoint(c.path, c.state, io); trace.push('broadcast');
  assert.deepEqual(trace, ['write', 'file_sync', 'rename', 'directory_sync', 'broadcast']);
});
test('persistent broadcast failure reports only safe diagnostic fields and recovers', async t => {
  const c = await fixture(t); const reports = []; c.report = report => reports.push(report);
  c.vault.settlementStatus = async () => 5n;
  c.provider.broadcastTransaction = async () => { throw new Error('secret-rpc-password'); };
  await runOnce(c); await runOnce(c);
  assert.ok(reports.some(r => r.category === 'broadcast_failed' && r.claimId === id && r.txHash === submitted.hash && r.nonce === 0));
  assert.ok(reports.some(r => r.category === 'submission_unresolved'));
  assert.ok(!JSON.stringify(reports).includes('secret-rpc-password'));
  c.provider.getTransactionReceipt = async () => ({ status: 1, blockNumber: 10 });
  c.vault.settlementStatus = async () => 1n; await runOnce(c);
  assert.equal(Object.keys(c.state.pending).length, 0);
});
test('checkpoint submissions must be the configured signer settlement for the exact claim', async t => {
  const cases = [
    ['chain', () => signedSettlement({ chainId: 1 })],
    ['signer', () => signedSettlement({}, new Wallet('0x' + '02'.repeat(32)))],
    ['vault', () => signedSettlement({ to: signer.address })],
    ['claim', () => signedSettlement({ data: abi.encodeFunctionData('settle', [hash]) })],
    ['function', () => signedSettlement({ data: abi.encodeFunctionData('settlementStatus', [id]) })],
    ['trailing calldata', () => signedSettlement({ data: abi.encodeFunctionData('settle', [id]) + '00' })],
    ['value', () => signedSettlement({ value: 1 })],
    ['gas limit', () => signedSettlement({ gasLimit: 700001 })],
    ['authorization transaction', () => signedSettlement({ type: 4, gasPrice: null,
      maxFeePerGas: 1, maxPriorityFeePerGas: 1, authorizationList: [] })],
    ['hash', async () => ({ ...submitted, hash })],
    ['nonce', async () => ({ ...submitted, nonce: 1 })],
    ['malformed transaction', async () => ({ ...submitted, rawTx: '0x1234' })],
  ];
  for (const [name, build] of cases) await t.test(name, async t => {
    const c = await fixture(t); c.state.pending[id] = { attempts: 0, nextAttemptAt: 0, submitted: await build() };
    await saveCheckpoint(c.path, c.state); const before = await readFile(c.path, 'utf8');
    await assert.rejects(loadCheckpoint(c.path, scope), /Invalid submitted transaction/);
    await assert.rejects(reconcileClaims(c), /Invalid submitted transaction/);
    const cursor = c.state.cursorBlock;
    await assert.rejects(runOnce(c), /Invalid submitted transaction/); assert.equal(c.state.cursorBlock, cursor);
    assert.equal(c.broadcasts, 0); assert.equal(await readFile(c.path, 'utf8'), before);
  });
});
test('multiple unresolved transactions fail closed before rebroadcast', async t => {
  const c = await fixture(t); const secondId = hash;
  c.state.pending[id] = { attempts: 0, nextAttemptAt: 0, submitted: { ...submitted } };
  c.state.pending[secondId] = { attempts: 0, nextAttemptAt: 0,
    submitted: await signedSettlement({ nonce: 1, data: abi.encodeFunctionData('settle', [secondId]) }) };
  await saveCheckpoint(c.path, c.state);
  await assert.rejects(loadCheckpoint(c.path, scope), /Multiple unresolved transactions/);
  await assert.rejects(reconcileClaims(c), /Multiple unresolved transactions/); assert.equal(c.broadcasts, 0);
});
test('invalid prepared transactions cannot become durable or broadcast', async t => {
  const c = await fixture(t); c.state.pending[id] = { attempts: 0, nextAttemptAt: 0 };
  c.vault.settlementStatus = async () => 5n; c.prepare = () => signedSettlement({ value: 1 });
  const reports = []; c.report = report => reports.push(report);
  await settleReadyClaims(c);
  assert.equal(c.broadcasts, 0); assert.ok(!c.state.pending[id].submitted);
  assert.ok(reports.some(report => report.category === 'prepare_failed'));
  await assert.rejects(readFile(c.path), { code: 'ENOENT' });
});
test('standard transaction types load version-one checkpoints without a stored signer field', async t => {
  const c = await fixture(t); delete c.state.signerAddress;
  const submissions = [
    await signedSettlement({ type: 0 }),
    await signedSettlement({ type: 1, accessList: [] }),
    await signedSettlement({ type: 2, gasPrice: null, maxFeePerGas: 2, maxPriorityFeePerGas: 1 }),
  ];
  for (const submission of submissions) {
    c.state.pending[id] = { attempts: 0, nextAttemptAt: 0, submitted: submission };
    await saveCheckpoint(c.path, c.state);
    assert.equal((await loadCheckpoint(c.path, scope)).pending[id].submitted.hash, submission.hash);
  }
});
test('CLI exits with sanitized output when startup RPC is unavailable', async () => {
  const script = fileURLToPath(new URL('../vault-settler.mjs', import.meta.url));
  const result = await new Promise(resolve => execFile(process.execPath, [script], {
    timeout: 3000, env: { ...process.env, GNOSIS_RPC_URL: 'http://127.0.0.1:1', AMB_VAULT: vaultAddress,
      AMB_VAULT_DEPLOYMENT_BLOCK: '10', VAULT_SETTLER_PRIVATE_KEY: '0x' + '01'.repeat(32) },
  }, (error, stdout, stderr) => resolve({ error, stdout, stderr })));
  assert.equal(result.error?.code, 1); assert.ok(!result.error?.killed);
  assert.ok(!result.stdout.includes('127.0.0.1')); assert.ok(!result.stderr.includes('127.0.0.1'));
});
