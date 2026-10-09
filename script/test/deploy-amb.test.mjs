import test from 'node:test';
import assert from 'node:assert/strict';
import { getCreateAddress } from 'ethers';
import { deploymentPlanHash, deployCost, freshNonce, predictedPair } from '../deploy-amb.mjs';

test('reciprocal CREATE addresses are bound to each deployer and nonce', () => {
  const mainnetSigner = '0x0000000000000000000000000000000000000001';
  const gnosisSigner = '0x0000000000000000000000000000000000000002';
  const pair = predictedPair(mainnetSigner, 7, gnosisSigner, 3);
  assert.equal(pair.router, getCreateAddress({ from: mainnetSigner, nonce: 7 }));
  assert.equal(pair.gnosisRouter, getCreateAddress({ from: gnosisSigner, nonce: 3 }));
  assert.equal(pair.recovery, pair.gnosisRouter);
  assert.notEqual(pair.router, predictedPair(mainnetSigner, 8, gnosisSigner, 3).router);
  assert.notEqual(pair.gnosisRouter, predictedPair(mainnetSigner, 7, gnosisSigner, 4).gnosisRouter);
});

test('review hash pins deployment identity and creation code, not changing fee quotes', () => {
  const plan = { router: '0x01', gnosisRouter: '0x02', recovery: '0x02', mainnetNonce: 7,
    recoveryNonce: 3, pauseAuthority: '0x03', safeThreshold: '2',
    mainnetConfig: { ambMaxGasPerTx: '700000', bridgeImplementation: '0xabcd' },
    recoveryCreationCodeHash: '0xabcd', gnosisRouterCost: { maxCostWei: '100' },
    routerCost: { maxCostWei: '200' }, recoveryCost: { maxCostWei: '300' } };
  const hash = deploymentPlanHash(plan);
  assert.equal(hash, deploymentPlanHash({ ...plan, gnosisRouterCost: { maxCostWei: '300' } }));
  assert.equal(hash, deploymentPlanHash({ ...plan, recoveryCost: { maxCostWei: '400' } }));
  assert.notEqual(hash, deploymentPlanHash({ ...plan, mainnetNonce: 8 }));
  assert.notEqual(hash, deploymentPlanHash({ ...plan, recoveryNonce: 4 }));
  assert.notEqual(hash, deploymentPlanHash({ ...plan, pauseAuthority: '0x04' }));
  assert.notEqual(hash, deploymentPlanHash({ ...plan, safeThreshold: '3' }));
  assert.notEqual(hash, deploymentPlanHash({ ...plan,
    mainnetConfig: { ...plan.mainnetConfig, bridgeImplementation: '0xdef' } }));
  assert.notEqual(hash, deploymentPlanHash({ ...plan, routerCreationCodeHash: '0x123' }));
  assert.notEqual(hash, deploymentPlanHash({ ...plan, recoveryCreationCodeHash: '0x123' }));
});

test('pending deployer nonce blocks a paired deployment', async () => {
  const provider = { getTransactionCount: async (_, tag) => tag === 'latest' ? 7 : 8,
    getNetwork: async () => ({ chainId: 1n }) };
  await assert.rejects(freshNonce(provider, '0x01'), /Pending deployer transaction/);
  provider.getTransactionCount = async () => 7;
  assert.equal(await freshNonce(provider, '0x01'), 7);
});

test('deployment cost gate fixes the fee quote and rejects excess cost or gas shortfall', async () => {
  const factory = { getDeployTransaction: async () => ({ data: '0x1234' }) };
  const wallet = { address: '0x0000000000000000000000000000000000000001', provider: {
    estimateGas: async () => 100n,
    getFeeData: async () => ({ maxFeePerGas: 2n, maxPriorityFeePerGas: 1n, gasPrice: 2n }),
    getBalance: async () => 1000n,
  } };
  const cost = await deployCost(factory, [], wallet, 240n);
  assert.equal(cost.gasLimit, 120n);
  assert.deepEqual(cost.feeFields, { type: 2, maxFeePerGas: 2n, maxPriorityFeePerGas: 1n });
  await assert.rejects(deployCost(factory, [], wallet, 239n), /exceeds reviewed cost ceiling/);
  wallet.provider.getBalance = async () => 239n;
  await assert.rejects(deployCost(factory, [], wallet, 240n), /Insufficient deployer gas/);
  wallet.provider.getBalance = async () => 1000n;
  wallet.provider.getFeeData = async () => ({ maxFeePerGas: null, maxPriorityFeePerGas: null, gasPrice: 1n });
  assert.deepEqual((await deployCost(factory, [], wallet, 240n)).feeFields,
    { type: 0, gasPrice: 1n });
});
