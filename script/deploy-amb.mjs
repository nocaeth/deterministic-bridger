import { readFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import {
  Contract, ContractFactory, JsonRpcProvider, Wallet, getAddress, getCreateAddress,
  isAddress, keccak256, toUtf8Bytes,
} from 'ethers';

const addresses = {
  foreignBridge: '0x4aa42145Aa6Ebf72e164C9bBC74fbD3788045016',
  homeBridge: '0x7301CFA0e1756B71869E93d4e4Dca5c7d0eb0AA6',
  foreignAMB: '0x4C36d2919e407f0Cc2Ee3c993ccF8ac26d9CE64e',
  homeAMB: '0x75Df5AF045d91108662D8080fD1FEFAd6aA0bb59',
  usds: '0xdC035D45d973E3EC169d2276DDab16f1e407384F',
  susds: '0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD',
};
const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const bridgeAbi = ['function erc20token() view returns (address)',
  'function feeManagerContract() view returns (address)', 'function decimalShift() view returns (int256)',
  'function implementation() view returns (address)'];
const ambAbi = ['function sourceChainId() view returns (uint256)', 'function destinationChainId() view returns (uint256)',
  'function maxGasPerTx() view returns (uint256)'];
const gnosisRouterGetters = ['function sourceRouter() view returns (address)', 'function foreignBridge() view returns (address)',
  'function homeBridge() view returns (address)', 'function homeAMB() view returns (address)',
  'function adapter() view returns (address)'];
const routerGetters = ['function gnosisRouter() view returns (address)', 'function homeBridge() view returns (address)',
  'function foreignBridge() view returns (address)', 'function foreignAMB() view returns (address)',
  'function pauseAuthority() view returns (address)',
  'function verifiedBridgeImplementation() view returns (address)',
  'function deprecated() view returns (bool)'];
const recoveryGetters = ['function recoveryAuthority() view returns (address)'];

function check(ok, message) { if (!ok) throw new Error(message); }
function same(a, b) { return getAddress(a) === getAddress(b); }
function required(name) { check(process.env[name], `Missing ${name}`); return process.env[name]; }
function costCap(name) {
  const value = required(name);
  check(/^[1-9][0-9]*$/.test(value), `Invalid ${name}`);
  return BigInt(value);
}
export function predictedPair(mainnetSigner, mainnetNonce, gnosisSigner, gnosisNonce) {
  const gnosisRouter = getCreateAddress({ from: gnosisSigner, nonce: gnosisNonce });
  return {
    router: getCreateAddress({ from: mainnetSigner, nonce: mainnetNonce }),
    gnosisRouter,
    recovery: gnosisRouter,
  };
}
export function deploymentPlanHash(plan) {
  const { gnosisRouterCost, routerCost, recoveryCost, ...reviewed } = plan;
  return keccak256(toUtf8Bytes(JSON.stringify(reviewed)));
}
export async function freshNonce(provider, signer) {
  const [latest, pending] = await Promise.all([
    provider.getTransactionCount(signer, 'latest'), provider.getTransactionCount(signer, 'pending'),
  ]);
  check(latest === pending, `Pending deployer transaction on chain ${(await provider.getNetwork()).chainId}`);
  return latest;
}
async function codeHash(provider, address) {
  const code = await provider.getCode(address);
  check(code !== '0x', `Missing contract code at ${address}`);
  return keccak256(code);
}
async function inspectMainnet(provider) {
  const bridge = new Contract(addresses.foreignBridge, bridgeAbi, provider);
  const amb = new Contract(addresses.foreignAMB, ambAbi, provider);
  const susds = new Contract(addresses.susds, ['function asset() view returns (address)'], provider);
  const [token, asset, source, destination, maxGas, implementation] = await Promise.all([
    bridge.erc20token(), susds.asset(), amb.sourceChainId(),
    amb.destinationChainId(), amb.maxGasPerTx(), bridge.implementation(),
  ]);
  check(same(token, addresses.usds) && same(asset, addresses.usds), 'Unsupported mainnet asset');
  check(source === 1n && destination === 100n && maxGas >= 700000n, 'Unsupported mainnet AMB');
  check(await provider.getCode(implementation) !== '0x', 'Missing mainnet bridge implementation code');
  return {
    bridgeImplementation: getAddress(implementation),
    ambMaxGasPerTx: maxGas.toString(),
    usdsCodeHash: await codeHash(provider, addresses.usds),
    susdsCodeHash: await codeHash(provider, addresses.susds),
  };
}
async function inspectGnosis(provider, adapter) {
  const bridge = new Contract(addresses.homeBridge, bridgeAbi, provider);
  const amb = new Contract(addresses.homeAMB, ambAbi, provider);
  const [manager, shift, source, destination, implementation] = await Promise.all([
    bridge.feeManagerContract(), bridge.decimalShift(),
    amb.sourceChainId(), amb.destinationChainId(), bridge.implementation(),
  ]);
  check(same(manager, '0x0000000000000000000000000000000000000000') && shift === 0n,
    'Unsupported Gnosis bridge fees or shift');
  check(source === 100n && destination === 1n, 'Unsupported Gnosis AMB');
  check(await provider.getCode(implementation) !== '0x', 'Missing Gnosis bridge implementation code');
  return {
    bridgeImplementation: getAddress(implementation),
    adapterCodeHash: await codeHash(provider, adapter),
  };
}
export async function deployCost(factory, args, wallet, cap) {
  const tx = await factory.getDeployTransaction(...args);
  const estimate = await wallet.provider.estimateGas({ ...tx, from: wallet.address });
  const gasLimit = estimate * 120n / 100n;
  const fees = await wallet.provider.getFeeData();
  const dynamic = fees.maxFeePerGas !== null && fees.maxPriorityFeePerGas !== null;
  const price = dynamic ? fees.maxFeePerGas : fees.gasPrice;
  check(price && price > 0n, 'RPC did not provide a usable gas price');
  check(gasLimit * price <= cap, 'Deployment gas quote exceeds reviewed cost ceiling');
  check(await wallet.provider.getBalance(wallet.address) >= gasLimit * price, 'Insufficient deployer gas balance');
  const feeFields = dynamic
    ? { type: 2, maxFeePerGas: fees.maxFeePerGas, maxPriorityFeePerGas: fees.maxPriorityFeePerGas }
    : { type: 0, gasPrice: fees.gasPrice };
  return { gasLimit, feeFields, maxCostWei: (gasLimit * price).toString() };
}
async function verifyGnosisRouter(provider, address, expectedRouter, adapter) {
  await codeHash(provider, address);
  const gnosisRouter = new Contract(address, gnosisRouterGetters, provider);
  const [router, foreign, home, amb, actualAdapter] = await Promise.all([
    gnosisRouter.sourceRouter(), gnosisRouter.foreignBridge(), gnosisRouter.homeBridge(), gnosisRouter.homeAMB(),
    gnosisRouter.adapter(),
  ]);
  check(same(router, expectedRouter) && same(foreign, addresses.foreignBridge)
    && same(home, addresses.homeBridge) && same(amb, addresses.homeAMB)
    && same(actualAdapter, adapter), 'Gnosis router verification failed');
}
async function verifyRouter(provider, address, expectedGnosisRouter, pauseAuthority, implementation) {
  await codeHash(provider, address);
  const router = new Contract(address, routerGetters, provider);
  const [gnosisRouter, home, foreign, amb, authority, verified, deprecated] = await Promise.all([
    router.gnosisRouter(), router.homeBridge(), router.foreignBridge(),
    router.foreignAMB(), router.pauseAuthority(), router.verifiedBridgeImplementation(),
    router.deprecated(),
  ]);
  check(same(gnosisRouter, expectedGnosisRouter) && same(home, addresses.homeBridge)
    && same(foreign, addresses.foreignBridge) && same(amb, addresses.foreignAMB)
    && same(authority, pauseAuthority) && same(verified, implementation) && deprecated,
  'Router verification failed');
}
async function verifyRecovery(provider, address, authority) {
  await codeHash(provider, address);
  const receiver = new Contract(address, recoveryGetters, provider);
  check(same(await receiver.recoveryAuthority(), authority), 'Recovery receiver verification failed');
}

export async function main() {
  check(process.argv.length === 2 || (process.argv.length === 3 && process.argv[2] === '--broadcast'),
    'Usage: node script/deploy-amb.mjs [--broadcast]');
  const broadcast = process.argv[2] === '--broadcast';
  const adapter = required('SAVINGS_XDAI_ADAPTER');
  check(isAddress(adapter) && !same(adapter, '0x0000000000000000000000000000000000000000'),
    'Invalid SAVINGS_XDAI_ADAPTER');
  const pauseAuthority = required('MAINNET_PAUSE_AUTHORITY');
  check(isAddress(pauseAuthority) && !same(pauseAuthority, '0x0000000000000000000000000000000000000000'),
    'Invalid MAINNET_PAUSE_AUTHORITY');
  const mainnet = new JsonRpcProvider(required('MAINNET_RPC_URL'));
  const gnosis = new JsonRpcProvider(required('GNOSIS_RPC_URL'));
  const mainnetCap = costCap('MAINNET_MAX_DEPLOYMENT_COST_WEI');
  const gnosisCap = costCap('GNOSIS_MAX_DEPLOYMENT_COST_WEI');
  try {
    const [mainnetNetwork, gnosisNetwork] = await Promise.all([mainnet.getNetwork(), gnosis.getNetwork()]);
    check(mainnetNetwork.chainId === 1n && gnosisNetwork.chainId === 100n, 'Wrong RPC chain ID');
    const mainnetWallet = new Wallet(required('MAINNET_DEPLOYER_PRIVATE_KEY'), mainnet);
    const gnosisWallet = new Wallet(required('GNOSIS_DEPLOYER_PRIVATE_KEY'), gnosis);
    const recoveryWallet = gnosisWallet.connect(mainnet);
    check(!same(mainnetWallet.address, recoveryWallet.address), 'Use distinct Ethereum router and Gnosis router deployers');
    const authority = new Contract(pauseAuthority, ['function getThreshold() view returns (uint256)'], mainnet);
    check(await mainnet.getCode(pauseAuthority) !== '0x', 'MAINNET_PAUSE_AUTHORITY must be a contract');
    const safeThreshold = await authority.getThreshold();
    check(safeThreshold >= 2n, 'MAINNET_PAUSE_AUTHORITY threshold must be >= 2');
    const [mainnetNonce, gnosisNonce, recoveryNonce, mainnetConfig, gnosisConfig] = await Promise.all([
      freshNonce(mainnet, mainnetWallet.address), freshNonce(gnosis, gnosisWallet.address),
      freshNonce(mainnet, recoveryWallet.address),
      inspectMainnet(mainnet), inspectGnosis(gnosis, adapter),
    ]);
    check(recoveryNonce === gnosisNonce, 'Gnosis router deployer nonces must match on Ethereum and Gnosis');
    const pair = predictedPair(mainnetWallet.address, mainnetNonce, gnosisWallet.address, gnosisNonce);
    check(await mainnet.getCode(pair.router) === '0x' && await mainnet.getCode(pair.recovery) === '0x'
      && await gnosis.getCode(pair.gnosisRouter) === '0x',
      'Predicted deployment address already has code');
    execFileSync('forge', ['build', '--quiet'], { cwd: projectRoot, stdio: 'ignore' });
    const gnosisRouterArtifact = JSON.parse(await readFile(join(projectRoot,
      'out/GnosisAmbSettlementRouter.sol/GnosisAmbSettlementRouter.json')));
    const routerArtifact = JSON.parse(await readFile(join(projectRoot,
      'out/MainnetAmbBridgeRouter.sol/MainnetAmbBridgeRouter.json')));
    const recoveryArtifact = JSON.parse(await readFile(join(projectRoot,
      'out/EthereumBridgeReturnReceiver.sol/EthereumBridgeReturnReceiver.json')));
    const gnosisRouterFactory = new ContractFactory(gnosisRouterArtifact.abi, gnosisRouterArtifact.bytecode.object, gnosisWallet);
    const routerFactory = new ContractFactory(routerArtifact.abi, routerArtifact.bytecode.object, mainnetWallet);
    const recoveryFactory = new ContractFactory(recoveryArtifact.abi, recoveryArtifact.bytecode.object,
      recoveryWallet);
    const gnosisRouterArgs = [addresses.homeBridge, addresses.homeAMB, adapter, pair.router, addresses.foreignBridge];
    const routerArgs = [addresses.foreignBridge, addresses.foreignAMB, addresses.homeBridge,
      pair.gnosisRouter, getAddress(pauseAuthority)];
    const [gnosisRouterCost, routerCost, recoveryCost] = await Promise.all([
      deployCost(gnosisRouterFactory, gnosisRouterArgs, gnosisWallet, gnosisCap),
      deployCost(routerFactory, routerArgs, mainnetWallet, mainnetCap),
      deployCost(recoveryFactory, [getAddress(pauseAuthority)], recoveryWallet, mainnetCap),
    ]);
    const plan = { addresses, adapter: getAddress(adapter), pauseAuthority: getAddress(pauseAuthority),
      safeThreshold: safeThreshold.toString(),
      mainnetSigner: mainnetWallet.address,
      gnosisSigner: gnosisWallet.address, mainnetNonce, gnosisNonce, recoveryNonce, ...pair,
      mainnetConfig, gnosisConfig, mainnetMaxCostWei: mainnetCap.toString(),
      gnosisMaxCostWei: gnosisCap.toString(),
      gnosisRouterCreationCodeHash: keccak256(gnosisRouterArtifact.bytecode.object),
      routerCreationCodeHash: keccak256(routerArtifact.bytecode.object),
      recoveryCreationCodeHash: keccak256(recoveryArtifact.bytecode.object),
      gnosisRouterCost, routerCost, recoveryCost };
    const planHash = deploymentPlanHash(plan);
    console.log(JSON.stringify({ mode: broadcast ? 'broadcast' : 'dry-run', ...plan, planHash },
      (_, value) => typeof value === 'bigint' ? value.toString() : value, 2));
    if (!broadcast) return;
    check(process.env.DEPLOY_PLAN_HASH === planHash, 'DEPLOY_PLAN_HASH must match the reviewed dry-run');
    check(await freshNonce(mainnet, recoveryWallet.address) === recoveryNonce, 'Recovery nonce changed');
    check(JSON.stringify(await inspectMainnet(mainnet)) === JSON.stringify(mainnetConfig),
      'Mainnet dependency changed');
    const recovery = await recoveryFactory.deploy(getAddress(pauseAuthority),
      { nonce: recoveryNonce, gasLimit: recoveryCost.gasLimit, ...recoveryCost.feeFields });
    console.log(`Ethereum recovery transaction: ${recovery.deploymentTransaction().hash}`);
    const recoveryReceipt = await recovery.deploymentTransaction().wait();
    check(recoveryReceipt?.status === 1 && same(recoveryReceipt.contractAddress, pair.recovery),
      'Ethereum recovery deployment failed');
    await verifyRecovery(mainnet, pair.recovery, pauseAuthority);
    console.log(`Verified Ethereum recovery: ${pair.recovery} at block ${recoveryReceipt.blockNumber}`);
    check(await freshNonce(gnosis, gnosisWallet.address) === gnosisNonce, 'Gnosis nonce changed');
    check(JSON.stringify(await inspectGnosis(gnosis, adapter)) === JSON.stringify(gnosisConfig),
      'Gnosis dependency changed');
    const gnosisRouter = await gnosisRouterFactory.deploy(...gnosisRouterArgs,
      { nonce: gnosisNonce, gasLimit: gnosisRouterCost.gasLimit, ...gnosisRouterCost.feeFields });
    console.log(`Gnosis router transaction: ${gnosisRouter.deploymentTransaction().hash}`);
    const gnosisRouterReceipt = await gnosisRouter.deploymentTransaction().wait();
    check(gnosisRouterReceipt?.status === 1 && same(gnosisRouterReceipt.contractAddress, pair.gnosisRouter),
      'Gnosis router deployment failed');
    await verifyGnosisRouter(gnosis, pair.gnosisRouter, pair.router, adapter);
    console.log(`Verified Gnosis router: ${pair.gnosisRouter} at block ${gnosisRouterReceipt.blockNumber}`);
    check(await freshNonce(mainnet, mainnetWallet.address) === mainnetNonce, 'Mainnet nonce changed');
    check(JSON.stringify(await inspectMainnet(mainnet)) === JSON.stringify(mainnetConfig),
      'Mainnet dependency changed');
    const router = await routerFactory.deploy(...routerArgs,
      { nonce: mainnetNonce, gasLimit: routerCost.gasLimit, ...routerCost.feeFields });
    console.log(`Ethereum router transaction: ${router.deploymentTransaction().hash}`);
    const routerReceipt = await router.deploymentTransaction().wait();
    check(routerReceipt?.status === 1 && same(routerReceipt.contractAddress, pair.router),
      'Ethereum router deployment failed');
    await verifyRouter(mainnet, pair.router, pair.gnosisRouter, pauseAuthority,
      mainnetConfig.bridgeImplementation);
    console.log(`Verified Ethereum router: ${pair.router} at block ${routerReceipt.blockNumber}`);
  } finally {
    mainnet.destroy(); gnosis.destroy();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(error => {
    console.error(error instanceof Error && !('code' in error) ? error.message
      : 'Deployment stopped: RPC, build, or transaction failed; inspect chain state before retrying');
    process.exitCode = 1;
  });
}
