import { open, readFile, rename } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { Contract, Interface, JsonRpcProvider, Wallet, isAddress, keccak256 } from 'ethers';

export const VAULT_ABI = [
  'event ClaimRegistered(bytes32 indexed claimId,address indexed payer,address indexed recipient,bytes32 bridgeNonce,uint256 amount,uint256 minShares)',
  'event ClaimPaid(bytes32 indexed claimId,address indexed recipient,uint256 amount,uint256 shares)',
  'function settlementStatus(bytes32) view returns (uint8)',
  'function settle(bytes32) returns (uint8,uint256)',
];
const abi = new Interface(VAULT_ABI);
const topics = ['ClaimRegistered', 'ClaimPaid'].map(name => abi.getEvent(name).topicHash);
const hex32 = /^0x[0-9a-f]{64}$/i;

export async function loadCheckpoint(path, scope) {
  let state;
  try { state = JSON.parse(await readFile(path, 'utf8')); }
  catch (error) {
    if (error.code !== 'ENOENT') throw new Error('Invalid checkpoint; preserve it and replay into a new file');
    state = { version: 1, ...scope, cursorBlock: scope.deploymentBlock - 1, cursorHash: null, pending: {} };
  }
  if (state.version !== 1 || state.chainId !== scope.chainId || state.vault?.toLowerCase() !== scope.vault.toLowerCase()
      || state.deploymentBlock !== scope.deploymentBlock) throw new Error('Checkpoint scope mismatch');
  if (!Number.isSafeInteger(state.cursorBlock) || state.cursorBlock < scope.deploymentBlock - 1
      || (state.cursorHash !== null && !hex32.test(state.cursorHash)) || !state.pending
      || Array.isArray(state.pending) || typeof state.pending !== 'object') throw new Error('Invalid checkpoint schema');
  for (const [id, entry] of Object.entries(state.pending)) {
    if (!hex32.test(id) || !Number.isSafeInteger(entry.attempts) || entry.attempts < 0
        || !Number.isSafeInteger(entry.nextAttemptAt) || entry.nextAttemptAt < 0) throw new Error('Invalid pending claim');
    if (entry.submitted && (!hex32.test(entry.submitted.hash) || !/^0x[0-9a-f]+$/i.test(entry.submitted.rawTx)
        || !Number.isSafeInteger(entry.submitted.nonce) || entry.submitted.nonce < 0)) throw new Error('Invalid submitted transaction');
  }
  return state;
}

export async function saveCheckpoint(path, state, io = { open, rename }) {
  // The operator supplies an existing persistent directory; do not create unsynced ancestors.
  const file = await io.open(path + '.tmp', 'w', 0o600);
  try { await file.chmod(0o600); await file.writeFile(JSON.stringify(state)); await file.sync(); }
  finally { await file.close(); }
  await io.rename(path + '.tmp', path);
  const directory = await io.open(dirname(path), 'r');
  try { await directory.sync(); } finally { await directory.close(); }
}

function report(ctx, category, id, entry) {
  ctx.report?.({ category, claimId: id, txHash: entry.submitted?.hash, nonce: entry.submitted?.nonce });
}

function defer(ctx, entry) {
  entry.attempts = Math.min(entry.attempts + 1, 20);
  entry.nextAttemptAt = ctx.now() + Math.min(ctx.backoff * 2 ** Math.min(entry.attempts, 10), 300_000);
}

export async function scanClaims(ctx) {
  const { provider, state } = ctx;
  const target = (await provider.getBlockNumber()) - ctx.confirmations;
  ctx.confirmedBlock = Math.max(target, 0);
  if (state.cursorBlock >= state.deploymentBlock) {
    const block = await provider.getBlock(state.cursorBlock);
    if (!block || block.hash !== state.cursorHash) {
      state.cursorBlock = state.deploymentBlock - 1; state.cursorHash = null;
    }
  }
  const fromBlock = state.cursorBlock + 1;
  if (fromBlock > target) return;
  const toBlock = Math.min(target, fromBlock + ctx.range - 1);
  const before = await provider.getBlock(toBlock);
  if (!before) throw new Error('Missing scan block');
  const logs = await provider.getLogs({ address: state.vault, topics: [topics], fromBlock, toBlock });
  const after = await provider.getBlock(toBlock);
  if (!after || after.hash !== before.hash) throw new Error('Scan reorg; retry without advancing');
  const pending = structuredClone(state.pending);
  for (const log of logs.sort((a, b) => a.blockNumber - b.blockNumber || a.index - b.index)) {
    const parsed = abi.parseLog(log);
    const id = parsed.args.claimId;
    if (parsed.name === 'ClaimRegistered') pending[id] ??= { attempts: 0, nextAttemptAt: 0 };
    else if (!pending[id]?.submitted) delete pending[id];
  }
  state.pending = pending; state.cursorBlock = toBlock; state.cursorHash = after.hash;
}

export async function reconcileClaims(ctx) {
  const { state, provider } = ctx;
  // A dedicated signer has at most one unresolved nonce, including after a crash.
  for (const [id, entry] of Object.entries(state.pending)) {
    if (!entry.submitted) continue;
    const tx = entry.submitted;
    try {
      const receipt = await provider.getTransactionReceipt(tx.hash);
      if ((receipt && receipt.blockNumber <= ctx.confirmedBlock)
          || await provider.getTransactionCount(ctx.signerAddress, ctx.confirmedBlock) > tx.nonce) {
        delete entry.submitted;
        if (receipt?.status === 0) { report(ctx, 'settlement_reverted', id, { submitted: tx }); defer(ctx, entry); }
        else entry.nextAttemptAt = 0;
      } else {
        try { await provider.broadcastTransaction(tx.rawTx); } catch { report(ctx, 'broadcast_failed', id, entry); }
        report(ctx, 'submission_unresolved', id, entry);
      }
    } catch { report(ctx, 'receipt_or_nonce_read_failed', id, entry); }
    if (entry.submitted) return;
  }
  let checked = 0;
  for (const [id, entry] of Object.entries(state.pending)) {
    if (entry.nextAttemptAt > ctx.now()) continue;
    if (checked++ >= ctx.batchSize) break;
    try {
      const status = Number(await ctx.vault.settlementStatus(id, { blockTag: state.cursorBlock }));
      if (status === 0 || status === 1) delete state.pending[id];
      else if (status !== 5) defer(ctx, entry);
    } catch { report(ctx, 'status_read_failed', id, entry); defer(ctx, entry); }
  }
}

export async function settleReadyClaims(ctx) {
  if (Object.values(ctx.state.pending).some(entry => entry.submitted)) return;
  let checked = 0;
  for (const [id, entry] of Object.entries(ctx.state.pending)) {
    if (entry.nextAttemptAt > ctx.now()) continue;
    if (checked++ >= ctx.batchSize) break;
    let submitted;
    try {
      if (Number(await ctx.vault.settlementStatus(id)) !== 5) { defer(ctx, entry); continue; }
      submitted = await ctx.prepare(id);
    } catch { report(ctx, 'prepare_failed', id, entry); defer(ctx, entry); continue; }
    // Persist the signed hash and nonce BEFORE broadcast, eliminating the lost-response window.
    const checkpoint = structuredClone(ctx.state);
    checkpoint.pending[id].submitted = submitted;
    await saveCheckpoint(ctx.path, checkpoint);
    entry.submitted = submitted;
    try { await ctx.provider.broadcastTransaction(entry.submitted.rawTx); }
    catch { report(ctx, 'broadcast_failed', id, entry); }
    return;
  }
}

export async function runOnce(ctx) {
  await scanClaims(ctx);
  await reconcileClaims(ctx);
  await saveCheckpoint(ctx.path, ctx.state);
  await settleReadyClaims(ctx);
  await saveCheckpoint(ctx.path, ctx.state);
}

function bounded(name, fallback, maximum) {
  const value = Number(process.env[name] ?? fallback);
  if (!Number.isSafeInteger(value) || value < 1 || value > maximum) throw new Error(`Invalid ${name}`);
  return value;
}

async function main() {
  const vaultAddress = process.env.AMB_VAULT;
  if (!isAddress(vaultAddress) || /^0x0{40}$/i.test(vaultAddress)) throw new Error('Invalid AMB_VAULT');
  const deploymentBlock = bounded('AMB_VAULT_DEPLOYMENT_BLOCK', undefined, Number.MAX_SAFE_INTEGER);
  const provider = new JsonRpcProvider(process.env.GNOSIS_RPC_URL);
  if (!process.env.GNOSIS_RPC_URL || !process.env.VAULT_SETTLER_PRIVATE_KEY) throw new Error('Missing executor RPC/key');
  if ((await provider.getNetwork()).chainId !== 100n || await provider.getCode(vaultAddress) === '0x')
    throw new Error('Wrong chain or missing vault code');
  const signer = new Wallet(process.env.VAULT_SETTLER_PRIVATE_KEY, provider);
  const vault = new Contract(vaultAddress, VAULT_ABI, signer);
  const path = resolve(process.env.VAULT_SETTLER_STATE_PATH || `.tmp/vault-settler-100-${vaultAddress.toLowerCase()}.json`);
  const directory = await open(dirname(path), 'r');
  try { await directory.sync(); } finally { await directory.close(); }
  const state = await loadCheckpoint(path, { chainId: 100, vault: vaultAddress, deploymentBlock });
  const ctx = {
    state, path, provider, vault, signerAddress: signer.address, now: Date.now,
    report: diagnostic => console.warn(`vault-settler ${JSON.stringify(diagnostic)}`),
    range: bounded('VAULT_SETTLER_RANGE', 2000, 10000),
    confirmations: bounded('VAULT_SETTLER_CONFIRMATIONS', 2, 100),
    batchSize: bounded('VAULT_SETTLER_BATCH_SIZE', 25, 100),
    backoff: bounded('VAULT_SETTLER_BACKOFF_MS', 1000, 300000),
    prepare: async id => {
      const transaction = await vault.settle.populateTransaction(id);
      const fees = await provider.getFeeData();
      const nonce = await provider.getTransactionCount(signer.address, 'pending');
      const feeFields = fees.maxFeePerGas !== null && fees.maxPriorityFeePerGas !== null
        ? { type: 2, maxFeePerGas: fees.maxFeePerGas, maxPriorityFeePerGas: fees.maxPriorityFeePerGas }
        : { gasPrice: fees.gasPrice };
      const rawTx = await signer.signTransaction({ ...transaction, ...feeFields, chainId: 100, nonce, gasLimit: 700000 });
      return { hash: keccak256(rawTx), rawTx, nonce };
    },
  };
  const poll = bounded('VAULT_SETTLER_POLL_MS', 2000, 60000);
  let running = true;
  process.on('SIGINT', () => { running = false; }); process.on('SIGTERM', () => { running = false; });
  while (running) {
    try {
      await runOnce(ctx);
      console.log(`vault-settler cursor=${state.cursorBlock} pending=${Object.keys(state.pending).length}`);
    } catch { console.error('vault-settler iteration failed; inspect RPC/disk/configuration; checkpoint retained'); }
    if (running) await new Promise(resolve => setTimeout(resolve, poll));
  }
  provider.destroy();
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(() => { console.error('vault-settler stopped: configuration or checkpoint unavailable'); process.exitCode = 1; });
}
