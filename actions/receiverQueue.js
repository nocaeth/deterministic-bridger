const ethersModule = require("ethers");

const ethers = ethersModule.ethers || ethersModule;
const JsonRpcProvider = ethers.JsonRpcProvider || ethers.providers.JsonRpcProvider;
const Interface = ethers.Interface || ethers.utils.Interface;
const isAddress = ethers.isAddress || ethers.utils.isAddress;
const getAddress = ethers.getAddress || ethers.utils.getAddress;

const STATE_KEY = "sdai-receiver-watchtower:state";
const ROUTER = "0x634D45eFa4F053DD168648B15aD2A34Ec58852b0";
const DEFAULT_BATCH_SIZE = 25;
const DEFAULT_MAX_AGE_SECONDS = 7 * 24 * 60 * 60;
const TX_HASH_RE = /^0x[0-9a-fA-F]{64}$/;

const FACTORY_ABI = [
  "function predict(address deterministicReceiver) view returns (address)",
  "function deployAndConvert(address deterministicReceiver) returns (address receiver,uint256 shares)",
];

const BRIDGE_ABI = [
  "event BridgeRequested(address indexed payer,address indexed deterministicReceiver,address indexed gnosisReceiver,uint256 amount)",
];
const BRIDGE_INTERFACE = new Interface(BRIDGE_ABI);
const BRIDGE_REQUESTED_TOPIC = eventTopic(BRIDGE_INTERFACE, "BridgeRequested");

exports.handle = async (context, event) => {
  const payload = event?.payload || {};
  const op = String(payload.op || "").toLowerCase();

  if (op === "register") {
    return register(context, payload);
  }
  if (op === "process") {
    return processPending(context);
  }
  if (op === "inspect") {
    return inspect(context);
  }

  throw new Error(`unsupported op: ${payload.op || "<missing>"}`);
};

async function register(context, payload) {
  const mainnetTxHash = normalizeTxHash(payload.mainnetTxHash);
  const requestedLogIndex = parseOptionalLogIndex(payload.logIndex);
  const mainnetRpcUrl = await requiredSecret(context, "MAINNET_RPC_URL");
  const router = normalizeAddress(ROUTER, "ROUTER");
  const maxAgeSeconds = positiveInteger(
    await optionalSecret(context, "WATCHTOWER_MAX_AGE_SECONDS"),
    DEFAULT_MAX_AGE_SECONDS,
  );
  const mainnetProvider = new JsonRpcProvider(mainnetRpcUrl);
  const receipt = await mainnetProvider.getTransactionReceipt(mainnetTxHash);

  if (!receipt) {
    throw new Error(`mainnet transaction not mined: ${mainnetTxHash}`);
  }
  if (isRevertedReceipt(receipt)) {
    throw new Error(`mainnet transaction reverted: ${mainnetTxHash}`);
  }
  await validateReceiptAge(mainnetProvider, receipt, maxAgeSeconds);

  const bridgeLogs = bridgeRequestedLogs(receipt, router, requestedLogIndex);
  if (bridgeLogs.length === 0) {
    const suffix = requestedLogIndex === null ? "" : ` at logIndex=${requestedLogIndex}`;
    throw new Error(`no router BridgeRequested log found in ${mainnetTxHash}${suffix}`);
  }

  const factory = await factoryContract(context, false);
  const state = await getState(context);
  const now = unixSeconds();

  for (const { log, parsed } of bridgeLogs) {
    const args = parsed.args || [];
    const payer = normalizeAddress(args.payer || args[0], "payer");
    const deterministicReceiver = normalizeAddress(
      args.deterministicReceiver || args[1],
      "deterministicReceiver",
    );
    const gnosisReceiver = normalizeAddress(args.gnosisReceiver || args[2], "gnosisReceiver");
    const predicted = normalizeAddress(await factory.predict(deterministicReceiver), "predicted receiver");
    const logIndex = logIndexOf(log);

    if (predicted.toLowerCase() !== gnosisReceiver.toLowerCase()) {
      throw new Error(
        `gnosisReceiver mismatch at logIndex=${logIndex}: expected ${predicted}, got ${gnosisReceiver}`,
      );
    }

    upsertJob(state.pending, {
      id: jobId(gnosisReceiver),
      deterministicReceiver,
      gnosisReceiver,
      mainnetTxHash,
      logIndex,
      amount: amountToString(args.amount || args[3]),
      payer,
      registeredAt: now,
      updatedAt: now,
      attempts: 0,
      lastCheckedAt: null,
      lastError: null,
    });
  }

  state.status = state.pending.length === 0 ? "idle" : "active";
  state.updatedAt = now;
  await putState(context, state);
}

async function processPending(context) {
  const rpcUrl = await requiredSecret(context, "TENDERLY_GNOSIS_RPC_URL", "GNOSIS_RPC_URL");
  const provider = new JsonRpcProvider(rpcUrl);
  const factory = await factoryContract(context, true, provider);
  const maxAgeSeconds = positiveInteger(
    await optionalSecret(context, "WATCHTOWER_MAX_AGE_SECONDS"),
    DEFAULT_MAX_AGE_SECONDS,
  );
  const batchSize = positiveInteger(
    await optionalSecret(context, "WATCHTOWER_BATCH_SIZE"),
    DEFAULT_BATCH_SIZE,
  );

  const now = unixSeconds();
  const state = await getState(context);
  const remaining = [];
  let checked = 0;

  if (state.pending.length === 0) {
    state.status = "idle";
    state.lastRunAt = now;
    state.updatedAt = now;
    await putState(context, state);
    console.log("receiver worker idle: no pending jobs");
    return;
  }

  console.log(`receiver worker active: pending=${state.pending.length}`);

  for (const job of state.pending) {
    if (now - (job.registeredAt || job.updatedAt || now) > maxAgeSeconds) {
      console.log(`receiver job stale id=${job.id}`);
      continue;
    }

    if (checked >= batchSize) {
      remaining.push(job);
      continue;
    }

    checked++;
    job.attempts = (job.attempts || 0) + 1;
    job.lastCheckedAt = now;
    job.updatedAt = now;

    try {
      const balance = await provider.getBalance(job.gnosisReceiver);
      if (isZero(balance)) {
        remaining.push(job);
        console.log(`receiver job waiting id=${job.id}`);
        continue;
      }

      const tx = await factory.deployAndConvert(job.deterministicReceiver);
      const receipt = await tx.wait();
      const executionTxHash = receipt.hash || receipt.transactionHash;
      console.log(`receiver job completed id=${job.id} tx=${executionTxHash}`);
    } catch (error) {
      job.lastError = error.message || String(error);
      remaining.push(job);
      console.log(`receiver job error id=${job.id} error=${job.lastError}`);
    }
  }

  state.pending = remaining;
  state.status = remaining.length === 0 ? "idle" : "active";
  state.lastRunAt = now;
  state.updatedAt = now;
  await putState(context, state);
}

async function inspect(context) {
  const state = await getState(context);
  const now = unixSeconds();
  state.lastRunAt = now;
  await putState(context, state);

  console.log(`receiver worker state status=${state.status} pending=${state.pending.length}`);
  console.log(`pending ids=${state.pending.map((job) => job.id).join(",")}`);
}

async function factoryContract(context, withSigner, providerOverride) {
  const factoryAddress = normalizeAddress(
    await requiredSecret(context, "SAVINGS_XDAI_RECEIVER_FACTORY"),
    "SAVINGS_XDAI_RECEIVER_FACTORY",
  );
  const rpcUrl = await requiredSecret(context, "TENDERLY_GNOSIS_RPC_URL", "GNOSIS_RPC_URL");
  const provider = providerOverride || new JsonRpcProvider(rpcUrl);

  if (!withSigner) {
    return new ethers.Contract(factoryAddress, FACTORY_ABI, provider);
  }

  const privateKey = await requiredSecret(context, "WATCHTOWER_PRIVATE_KEY");
  const signer = new ethers.Wallet(privateKey, provider);
  return new ethers.Contract(factoryAddress, FACTORY_ABI, signer);
}

async function getState(context) {
  try {
    const state = await context.storage.getJson(STATE_KEY);
    return normalizeState(state);
  } catch {
    return normalizeState(null);
  }
}

async function putState(context, state) {
  await context.storage.putJson(STATE_KEY, normalizeState(state));
}

async function requiredSecret(context, ...names) {
  for (const name of names) {
    const value = await optionalSecret(context, name);
    if (value) return value;
  }
  throw new Error(`missing secret: ${names.join(" or ")}`);
}

async function optionalSecret(context, name) {
  if (process.env[name]) return process.env[name];
  try {
    return await context.secrets.get(name);
  } catch {
    return "";
  }
}

function bridgeRequestedLogs(receipt, router, requestedLogIndex) {
  return (receipt.logs || []).flatMap((log) => {
    if (requestedLogIndex !== null && logIndexOf(log) !== requestedLogIndex) return [];
    if (String(log.address).toLowerCase() !== router.toLowerCase()) return [];
    if (String(log.topics?.[0]).toLowerCase() !== BRIDGE_REQUESTED_TOPIC.toLowerCase()) return [];

    try {
      const parsed = BRIDGE_INTERFACE.parseLog({ topics: log.topics, data: log.data });
      return [{ log, parsed }];
    } catch (error) {
      throw new Error(`failed to parse BridgeRequested log: ${error.message || error}`);
    }
  });
}

async function validateReceiptAge(provider, receipt, maxAgeSeconds) {
  const block = await provider.getBlock(receipt.blockNumber);
  if (!block || !block.timestamp) {
    throw new Error(`missing mainnet block timestamp for ${receipt.transactionHash}`);
  }

  const age = unixSeconds() - Number(block.timestamp);
  if (age > maxAgeSeconds) {
    throw new Error(`mainnet transaction too old: age=${age}s max=${maxAgeSeconds}s`);
  }
}

function upsertJob(jobs, nextJob) {
  const index = jobs.findIndex((job) => job.id === nextJob.id);
  if (index === -1) {
    jobs.push(nextJob);
    console.log(`receiver job registered id=${nextJob.id} logIndex=${nextJob.logIndex}`);
    return;
  }

  jobs[index] = {
    ...jobs[index],
    ...nextJob,
    attempts: jobs[index].attempts || 0,
    lastCheckedAt: jobs[index].lastCheckedAt || null,
    lastError: null,
  };
  console.log(`receiver job refreshed id=${nextJob.id} logIndex=${nextJob.logIndex}`);
}

function normalizeAddress(value, name) {
  if (!isAddress(value)) {
    throw new Error(`invalid ${name}: ${value}`);
  }
  return getAddress(value);
}

function normalizeTxHash(value) {
  if (!TX_HASH_RE.test(String(value || ""))) {
    throw new Error(`invalid mainnetTxHash: ${value}`);
  }
  return String(value);
}

function parseOptionalLogIndex(value) {
  if (value === undefined || value === null || value === "") return null;
  const logIndex = Number(value);
  if (!Number.isInteger(logIndex) || logIndex < 0) {
    throw new Error(`invalid logIndex: ${value}`);
  }
  return logIndex;
}

function logIndexOf(log) {
  return Number(log.logIndex ?? log.index);
}

function jobId(gnosisReceiver) {
  return gnosisReceiver.toLowerCase();
}

function amountToString(value) {
  if (value === undefined || value === null) return "0";
  return value.toString();
}

function unixSeconds() {
  return Math.floor(Date.now() / 1000);
}

function isZero(value) {
  if (typeof value === "bigint") return value === 0n;
  if (value && typeof value.eq === "function") return value.eq(0);
  return Number(value) === 0;
}

function isRevertedReceipt(receipt) {
  return receipt.status === 0 || receipt.status === "0x0";
}

function positiveInteger(value, fallback) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function eventTopic(iface, name) {
  if (typeof iface.getEventTopic === "function") return iface.getEventTopic(name);
  return iface.getEvent(name).topicHash;
}

function normalizeState(state) {
  const pending = (Array.isArray(state?.pending) ? state.pending : [])
    .filter((job) => !job.status || job.status === "pending")
    .map(({ status, completedAt, executionTxHash, ...job }) => {
      const legacyReceiver = job["mainnet" + "Receiver"];
      delete job["mainnet" + "Receiver"];
      return {
        ...job,
        deterministicReceiver: job.deterministicReceiver || legacyReceiver,
      };
    });

  return {
    status: pending.length === 0 ? "idle" : "active",
    pending,
    updatedAt: state?.updatedAt || 0,
    lastRunAt: state?.lastRunAt || 0,
  };
}
