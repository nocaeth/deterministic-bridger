const { spawn, execFileSync } = require("node:child_process");
const { createServer } = require("node:http");
const { readFileSync } = require("node:fs");
const net = require("node:net");
const assert = require("node:assert/strict");
const test = require("node:test");
const ethersModule = require("ethers");

const { handle } = require("../receiverQueue");

const ethers = ethersModule.ethers || ethersModule;
const JsonRpcProvider = ethers.JsonRpcProvider || ethers.providers.JsonRpcProvider;
const Interface = ethers.Interface || ethers.utils.Interface;
const Wallet = ethers.Wallet;
const parseEther = ethers.parseEther || ethers.utils.parseEther;

const STATE_KEY = "sdai-receiver-watchtower:state";
const ZERO_BLOOM = `0x${"0".repeat(512)}`;
const BLOCK_HASH = `0x${"1".repeat(64)}`;
const TX_HASH = `0x${"2".repeat(64)}`;

const ROUTER_ABI = [
  "event BridgeRequested(address indexed payer,address indexed deterministicReceiver,address indexed gnosisReceiver,uint256 amount)",
  "function mainnetToken() view returns (address)",
  "function foreignBridge() view returns (address)",
  "function gnosisFactory() view returns (address)",
  "function gnosisSingleton() view returns (address)",
  "function receiverFor(address deterministicReceiver) view returns (address)",
];
const FACTORY_ABI = [
  "function singleton() view returns (address)",
  "function predict(address deterministicReceiver) view returns (address)",
];
const BRIDGE_INTERFACE = new Interface([ROUTER_ABI[0]]);
const env = parseDotEnv(".env");

test("live deployments are wired together", { timeout: 60_000 }, async () => {
  const mainnet = new JsonRpcProvider(env.MAINNET_RPC_URL);
  const gnosis = new JsonRpcProvider(env.GNOSIS_RPC_URL);
  const router = new ethers.Contract(env.ROUTER, ROUTER_ABI, mainnet);
  const factory = new ethers.Contract(env.SAVINGS_XDAI_RECEIVER_FACTORY, FACTORY_ABI, gnosis);
  const deterministicReceiver = Wallet.createRandom().address;

  assert.equal(await router.mainnetToken(), env.MAINNET_TOKEN);
  assert.equal(await router.foreignBridge(), "0x4aa42145Aa6Ebf72e164C9bBC74fbD3788045016");
  assert.equal(await router.gnosisFactory(), env.SAVINGS_XDAI_RECEIVER_FACTORY);
  assert.equal(await router.gnosisSingleton(), env.GNOSIS_SINGLETON);
  assert.equal(await factory.singleton(), env.GNOSIS_SINGLETON);
  assert.equal(
    (await router.receiverFor(deterministicReceiver)).toLowerCase(),
    (await factory.predict(deterministicReceiver)).toLowerCase(),
  );
});

test("register rejects invalid transaction hash", async () => {
  const context = memoryContext();

  await assert.rejects(
    () => withActionEnv(env, () => handle(context, { payload: { op: "register", mainnetTxHash: "bad" } })),
    /invalid mainnetTxHash/,
  );
});

test("register rejects mined receipts without router BridgeRequested logs", async () => {
  const rpc = await fakeRpc({ receipt: receiptWithLogs([]) });
  const context = memoryContext();

  try {
    await assert.rejects(
      () =>
        withActionEnv({ ...env, MAINNET_RPC_URL: rpc.url }, () =>
          handle(context, { payload: { op: "register", mainnetTxHash: TX_HASH } }),
        ),
      /no router BridgeRequested log/,
    );
  } finally {
    await rpc.close();
  }
});

test("register rejects stale historical router receipts", { timeout: 60_000 }, async () => {
  const deterministicReceiver = Wallet.createRandom().address;
  const payer = Wallet.createRandom().address;
  const factory = new ethers.Contract(
    env.SAVINGS_XDAI_RECEIVER_FACTORY,
    FACTORY_ABI,
    new JsonRpcProvider(env.GNOSIS_RPC_URL),
  );
  const gnosisReceiver = await factory.predict(deterministicReceiver);
  const rpc = await fakeRpc({
    blockTimestamp: Math.floor(Date.now() / 1000) - 10,
    receipt: receiptWithLogs([
      makeBridgeRequestedLog({
        router: env.ROUTER,
        payer,
        deterministicReceiver,
        gnosisReceiver,
        amount: 1n,
        logIndex: 7,
      }),
    ]),
  });

  try {
    await assert.rejects(
      () =>
        withActionEnv({ ...env, MAINNET_RPC_URL: rpc.url, WATCHTOWER_MAX_AGE_SECONDS: "1" }, () =>
          handle(memoryContext(), {
            payload: { op: "register", mainnetTxHash: TX_HASH, logIndex: 7 },
          }),
        ),
      /mainnet transaction too old/,
    );
  } finally {
    await rpc.close();
  }
});

test("register validates deployed factory prediction and dedupes by Gnosis receiver", { timeout: 60_000 }, async () => {
  const deterministicReceiver = Wallet.createRandom().address;
  const payer = Wallet.createRandom().address;
  const amount = 123456789n;
  const factory = new ethers.Contract(
    env.SAVINGS_XDAI_RECEIVER_FACTORY,
    FACTORY_ABI,
    new JsonRpcProvider(env.GNOSIS_RPC_URL),
  );
  const gnosisReceiver = await factory.predict(deterministicReceiver);
  const bridgeLog = makeBridgeRequestedLog({
    router: env.ROUTER,
    payer,
    deterministicReceiver,
    gnosisReceiver,
    amount,
    logIndex: 7,
  });
  const rpc = await fakeRpc({ receipt: receiptWithLogs([bridgeLog]) });
  const context = memoryContext();

  try {
    await withActionEnv({ ...env, MAINNET_RPC_URL: rpc.url }, () =>
      handle(context, { payload: { op: "register", mainnetTxHash: TX_HASH, logIndex: 7 } }),
    );
    await withActionEnv({ ...env, MAINNET_RPC_URL: rpc.url }, () =>
      handle(context, { payload: { op: "register", mainnetTxHash: TX_HASH, logIndex: 7 } }),
    );

    const state = await context.storage.getJson(STATE_KEY);
    assert.equal(state.status, "active");
    assert.equal(state.pending.length, 1);
    assert.equal(state.pending[0].id, gnosisReceiver.toLowerCase());
    assert.equal(state.pending[0].deterministicReceiver, deterministicReceiver);
    assert.equal(state.pending[0].gnosisReceiver, gnosisReceiver);
    assert.equal(state.pending[0].mainnetTxHash, TX_HASH);
    assert.equal(state.pending[0].logIndex, 7);
    assert.equal(state.pending[0].amount, amount.toString());
    assert.equal(state.pending[0].payer, payer);
  } finally {
    await rpc.close();
  }
});

test("register requires logIndex for receipts with multiple deterministic receivers", { timeout: 60_000 }, async () => {
  const deterministicReceiverA = Wallet.createRandom().address;
  const deterministicReceiverB = Wallet.createRandom().address;
  const payer = Wallet.createRandom().address;
  const factory = new ethers.Contract(
    env.SAVINGS_XDAI_RECEIVER_FACTORY,
    FACTORY_ABI,
    new JsonRpcProvider(env.GNOSIS_RPC_URL),
  );
  const gnosisReceiverA = await factory.predict(deterministicReceiverA);
  const gnosisReceiverB = await factory.predict(deterministicReceiverB);
  const rpc = await fakeRpc({
    receipt: receiptWithLogs([
      makeBridgeRequestedLog({
        router: env.ROUTER,
        payer,
        deterministicReceiver: deterministicReceiverA,
        gnosisReceiver: gnosisReceiverA,
        amount: 1n,
        logIndex: 7,
      }),
      makeBridgeRequestedLog({
        router: env.ROUTER,
        payer,
        deterministicReceiver: deterministicReceiverB,
        gnosisReceiver: gnosisReceiverB,
        amount: 2n,
        logIndex: 8,
      }),
    ]),
  });

  try {
    await assert.rejects(
      () =>
        withActionEnv({ ...env, MAINNET_RPC_URL: rpc.url }, () =>
          handle(memoryContext(), { payload: { op: "register", mainnetTxHash: TX_HASH } }),
        ),
      /multiple deterministicReceivers found; provide logIndex/,
    );

    const context = memoryContext();
    await withActionEnv({ ...env, MAINNET_RPC_URL: rpc.url }, () =>
      handle(context, { payload: { op: "register", mainnetTxHash: TX_HASH, logIndex: 8 } }),
    );

    const state = await context.storage.getJson(STATE_KEY);
    assert.equal(state.pending.length, 1);
    assert.equal(state.pending[0].deterministicReceiver, deterministicReceiverB);
    assert.equal(state.pending[0].gnosisReceiver, gnosisReceiverB);
    assert.equal(state.pending[0].logIndex, 8);
  } finally {
    await rpc.close();
  }
});

test("register rejects an explicit wrong logIndex", { timeout: 60_000 }, async () => {
  const deterministicReceiver = Wallet.createRandom().address;
  const payer = Wallet.createRandom().address;
  const factory = new ethers.Contract(
    env.SAVINGS_XDAI_RECEIVER_FACTORY,
    FACTORY_ABI,
    new JsonRpcProvider(env.GNOSIS_RPC_URL),
  );
  const gnosisReceiver = await factory.predict(deterministicReceiver);
  const rpc = await fakeRpc({
    receipt: receiptWithLogs([
      makeBridgeRequestedLog({
        router: env.ROUTER,
        payer,
        deterministicReceiver,
        gnosisReceiver,
        amount: 1n,
        logIndex: 7,
      }),
    ]),
  });

  try {
    await assert.rejects(
      () =>
        withActionEnv({ ...env, MAINNET_RPC_URL: rpc.url }, () =>
          handle(memoryContext(), { payload: { op: "register", mainnetTxHash: TX_HASH, logIndex: 8 } }),
        ),
      /no router BridgeRequested log/,
    );
  } finally {
    await rpc.close();
  }
});

test("process keeps deployed zero-balance receivers pending", { timeout: 60_000 }, async () => {
  const job = await pendingJob();
  const context = memoryContext({ [STATE_KEY]: { status: "active", pending: [job] } });

  await withActionEnv({ ...env, WATCHTOWER_BATCH_SIZE: "1" }, () =>
    handle(context, { payload: { op: "process" } }),
  );

  const state = await context.storage.getJson(STATE_KEY);
  assert.equal(state.status, "active");
  assert.equal(state.pending.length, 1);
  assert.equal(state.pending[0].attempts, 1);
  assert.equal(state.pending[0].lastError, null);
  assert.ok(state.pending[0].lastCheckedAt > 0);
});

test("process removes stale jobs without retaining history", { timeout: 60_000 }, async () => {
  const oldJob = await pendingJob({ registeredAt: 1, updatedAt: 1 });
  const context = memoryContext({ [STATE_KEY]: { status: "active", pending: [oldJob] } });

  await withActionEnv({ ...env, WATCHTOWER_MAX_AGE_SECONDS: "1" }, () =>
    handle(context, { payload: { op: "process" } }),
  );

  const state = await context.storage.getJson(STATE_KEY);
  assert.equal(state.status, "idle");
  assert.deepEqual(state.pending, []);
});

test("inspect logs pending state and updates lastRunAt", async () => {
  const context = memoryContext({
    [STATE_KEY]: {
      status: "active",
      pending: [{ id: "0xabc", deterministicReceiver: Wallet.createRandom().address }],
    },
  });

  await withActionEnv(env, () => handle(context, { payload: { op: "inspect" } }));

  const state = await context.storage.getJson(STATE_KEY);
  assert.equal(state.status, "active");
  assert.equal(state.pending.length, 1);
  assert.ok(state.lastRunAt > 0);
});

test("process converts a funded receiver against a fork of the deployed Gnosis factory", { timeout: 120_000 }, async (t) => {
  if (!hasCommand("anvil")) {
    t.skip("anvil is not installed");
    return;
  }

  const anvil = await startAnvil(env.GNOSIS_RPC_URL);
  try {
    const provider = new JsonRpcProvider(anvil.url);
    const job = await pendingJob({ provider });
    const fundedAmount = parseEther("0.01");
    await provider.send("anvil_setBalance", [job.gnosisReceiver, toQuantity(fundedAmount)]);

    const context = memoryContext({ [STATE_KEY]: { status: "active", pending: [job] } });
    await withActionEnv({ ...env, GNOSIS_RPC_URL: anvil.url, TENDERLY_GNOSIS_RPC_URL: anvil.url }, () =>
      handle(context, { payload: { op: "process" } }),
    );

    const state = await context.storage.getJson(STATE_KEY);
    const code = await provider.getCode(job.gnosisReceiver);
    const balance = await provider.getBalance(job.gnosisReceiver);

    assert.equal(state.status, "idle");
    assert.deepEqual(state.pending, []);
    assert.notEqual(code, "0x");
    assert.equal(balance, 0n);
  } finally {
    await anvil.close();
  }
});

async function pendingJob(overrides = {}) {
  const deterministicReceiver = overrides.deterministicReceiver || Wallet.createRandom().address;
  const provider = overrides.provider || new JsonRpcProvider(env.GNOSIS_RPC_URL);
  const factory = new ethers.Contract(env.SAVINGS_XDAI_RECEIVER_FACTORY, FACTORY_ABI, provider);
  const gnosisReceiver = await factory.predict(deterministicReceiver);

  return {
    id: gnosisReceiver.toLowerCase(),
    deterministicReceiver,
    gnosisReceiver,
    mainnetTxHash: TX_HASH,
    logIndex: 0,
    amount: "1",
    payer: Wallet.createRandom().address,
    registeredAt: overrides.registeredAt || Math.floor(Date.now() / 1000),
    updatedAt: overrides.updatedAt || Math.floor(Date.now() / 1000),
    attempts: 0,
    lastCheckedAt: null,
    lastError: null,
  };
}

function makeBridgeRequestedLog({
  router,
  payer,
  deterministicReceiver,
  gnosisReceiver,
  amount,
  logIndex,
}) {
  const encoded = BRIDGE_INTERFACE.encodeEventLog(
    BRIDGE_INTERFACE.getEvent("BridgeRequested"),
    [payer, deterministicReceiver, gnosisReceiver, amount],
  );

  return {
    address: router,
    topics: encoded.topics,
    data: encoded.data,
    blockNumber: "0x1",
    transactionHash: TX_HASH,
    transactionIndex: "0x0",
    blockHash: BLOCK_HASH,
    logIndex: toQuantity(logIndex),
    removed: false,
  };
}

function receiptWithLogs(logs) {
  return {
    transactionHash: TX_HASH,
    blockHash: BLOCK_HASH,
    blockNumber: "0x1",
    transactionIndex: "0x0",
    from: Wallet.createRandom().address,
    to: env.ROUTER,
    cumulativeGasUsed: "0x0",
    gasUsed: "0x0",
    contractAddress: null,
    logs,
    logsBloom: ZERO_BLOOM,
    status: "0x1",
    type: "0x2",
    effectiveGasPrice: "0x0",
  };
}

async function fakeRpc({ receipt, blockTimestamp = Math.floor(Date.now() / 1000) }) {
  const server = createServer((request, response) => {
    let body = "";
    request.on("data", (chunk) => {
      body += chunk;
    });
    request.on("end", () => {
      const message = JSON.parse(body);
      const messages = Array.isArray(message) ? message : [message];
      const responseBody = messages.map((item) => ({
        jsonrpc: "2.0",
        id: item.id,
        result: rpcResult(item.method, receipt, blockTimestamp),
      }));
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(Array.isArray(message) ? responseBody : responseBody[0]));
    });
  });

  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  return {
    url: `http://127.0.0.1:${port}`,
    close: async () => {
      if (typeof server.closeAllConnections === "function") server.closeAllConnections();
      server.close();
    },
  };
}

function rpcResult(method, receipt, blockTimestamp) {
  if (method === "eth_chainId") return "0x1";
  if (method === "eth_getTransactionReceipt") return receipt;
  if (method === "eth_getBlockByNumber") return block(blockTimestamp);
  if (method === "eth_blockNumber") return "0x1";
  throw new Error(`unsupported fake RPC method: ${method}`);
}

function block(timestamp) {
  return {
    hash: BLOCK_HASH,
    parentHash: `0x${"0".repeat(64)}`,
    number: "0x1",
    timestamp: toQuantity(timestamp),
    nonce: "0x0000000000000000",
    difficulty: "0x0",
    gasLimit: "0x1c9c380",
    gasUsed: "0x0",
    miner: Wallet.createRandom().address,
    extraData: "0x",
    transactions: [],
    baseFeePerGas: "0x1",
  };
}

function memoryContext(initial = {}) {
  const data = new Map(Object.entries(initial).map(([key, value]) => [key, clone(value)]));
  return {
    storage: {
      getJson: async (key) => {
        if (!data.has(key)) throw new Error(`missing storage key: ${key}`);
        return clone(data.get(key));
      },
      putJson: async (key, value) => {
        data.set(key, clone(value));
      },
    },
    secrets: {
      get: async (key) => {
        if (!env[key]) throw new Error(`missing secret: ${key}`);
        return env[key];
      },
    },
  };
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

async function withActionEnv(values, fn) {
  const keys = [
    "MAINNET_RPC_URL",
    "GNOSIS_RPC_URL",
    "TENDERLY_GNOSIS_RPC_URL",
    "ROUTER",
    "SAVINGS_XDAI_RECEIVER_FACTORY",
    "WATCHTOWER_PRIVATE_KEY",
    "PRIVATE_KEY",
    "WATCHTOWER_BATCH_SIZE",
    "WATCHTOWER_MAX_AGE_SECONDS",
  ];
  const previous = new Map(keys.map((key) => [key, process.env[key]]));

  for (const key of keys) {
    if (values[key] === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = values[key];
    }
  }

  try {
    return await fn();
  } finally {
    for (const [key, value] of previous) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

async function startAnvil(forkUrl) {
  const port = await freePort();
  const child = spawn("anvil", ["--fork-url", forkUrl, "--host", "127.0.0.1", "--port", String(port)], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  const url = `http://127.0.0.1:${port}`;
  let output = "";

  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error(`anvil start timed out: ${output}`)), 30_000);
    const onData = (chunk) => {
      output += chunk.toString();
      if (output.includes("Listening on")) {
        clearTimeout(timeout);
        resolve();
      }
    };
    child.stdout.on("data", onData);
    child.stderr.on("data", onData);
    child.on("exit", (code) => {
      clearTimeout(timeout);
      reject(new Error(`anvil exited with ${code}: ${output}`));
    });
  });

  return {
    url,
    close: async () => {
      child.kill("SIGTERM");
      await new Promise((resolve) => child.once("exit", resolve));
    },
  };
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
    server.on("error", reject);
  });
}

function hasCommand(command) {
  try {
    execFileSync("which", [command], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

function toQuantity(value) {
  const bigint = typeof value === "bigint" ? value : BigInt(value);
  return `0x${bigint.toString(16)}`;
}

function parseDotEnv(path) {
  const parsed = {};
  for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const separator = trimmed.indexOf("=");
    if (separator === -1) continue;
    const key = trimmed.slice(0, separator).trim();
    const value = trimmed.slice(separator + 1).trim().replace(/^['"]|['"]$/g, "");
    parsed[key] = value;
  }
  return parsed;
}
