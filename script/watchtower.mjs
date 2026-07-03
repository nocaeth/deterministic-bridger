#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";

const EVENT_TOPIC = "0xac925f189284bde6ee352ac628972cd02ac694477699de9c07e30ca83a685597";

loadDotEnv();

const required = [
  "MAINNET_RPC_URL",
  "GNOSIS_RPC_URL",
  "ROUTER",
  "SAVINGS_XDAI_RECEIVER_FACTORY",
  "PRIVATE_KEY",
];

for (const name of required) {
  if (!process.env[name]) {
    throw new Error(`missing ${name}`);
  }
}

const mainnetRpc = process.env.MAINNET_RPC_URL;
const gnosisRpc = process.env.GNOSIS_RPC_URL;
const router = process.env.ROUTER;
const factory = process.env.SAVINGS_XDAI_RECEIVER_FACTORY;
const privateKey = process.env.PRIVATE_KEY;
const pollMs = Number(process.env.POLL_MS ?? "15000");
const runDelayMs = Number(process.env.RUN_DELAY_MS ?? "0");

let nextBlock = process.env.START_BLOCK
  ? BigInt(process.env.START_BLOCK)
  : await blockNumber(mainnetRpc);

const seen = new Set();

console.log(`watching ${router} from mainnet block ${nextBlock}`);

for (;;) {
  const latest = await blockNumber(mainnetRpc);
  if (latest >= nextBlock) {
    const logs = await rpc(mainnetRpc, "eth_getLogs", [
      {
        address: router,
        fromBlock: toQuantity(nextBlock),
        toBlock: toQuantity(latest),
        topics: [EVENT_TOPIC],
      },
    ]);

    for (const log of logs) {
      const key = `${log.transactionHash}:${log.logIndex}`;
      if (seen.has(key)) continue;
      seen.add(key);

      const deterministicReceiver = topicAddress(log.topics[2]);
      console.log(`bridge event ${key}: receiver ${deterministicReceiver}`);
      setTimeout(() => deployAndConvert(deterministicReceiver), runDelayMs);
    }

    nextBlock = latest + 1n;
  }

  await sleep(pollMs);
}

async function blockNumber(url) {
  return BigInt(await rpc(url, "eth_blockNumber", []));
}

async function rpc(url, method, params) {
  const response = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const body = await response.json();
  if (body.error) {
    throw new Error(`${method}: ${body.error.message}`);
  }
  return body.result;
}

function deployAndConvert(deterministicReceiver) {
  const result = spawnSync(
    "cast",
    [
      "send",
      factory,
      "deployAndConvert(address)",
      deterministicReceiver,
      "--rpc-url",
      gnosisRpc,
      "--private-key",
      privateKey,
    ],
    { stdio: "inherit" },
  );

  if (result.status !== 0) {
    console.error(`deployAndConvert failed for ${deterministicReceiver}`);
  }
}

function topicAddress(topic) {
  return `0x${topic.slice(-40)}`;
}

function toQuantity(value) {
  return `0x${value.toString(16)}`;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function loadDotEnv() {
  if (!existsSync(".env")) return;

  for (const line of readFileSync(".env", "utf8").split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;

    const separator = trimmed.indexOf("=");
    if (separator === -1) continue;

    const key = trimmed.slice(0, separator).trim();
    const value = trimmed.slice(separator + 1).trim().replace(/^['"]|['"]$/g, "");
    if (!process.env[key]) {
      process.env[key] = value;
    }
  }
}
