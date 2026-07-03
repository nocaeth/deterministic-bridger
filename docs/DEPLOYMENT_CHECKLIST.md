# Deployment Checklist

- Run `forge fmt --check`, `forge build`, `forge test`, `node --check script/watchtower.mjs`, `node --check actions/receiverQueue.js`, and `npm run test:actions`.
- Verify the configured router token and foreign bridge pair are compatible.
- Verify the live bridge implementation exposes `relayTokens(address,uint256)`.
- Verify the configured Savings xDAI adapter has code on Gnosis.
- Verify `router.receiverFor(deterministicReceiver)` matches `factory.predict(deterministicReceiver)`.
- Verify counterfactual receiver funding is converted by `factory.deploy(deterministicReceiver)` on a fork or dry run.
- Deploy Gnosis singleton and factory before deploying the mainnet router.
- Deploy the single Tenderly Action `Deterministic-Bridger` from `tenderly.yaml`.
- Configure `MAINNET_RPC_URL`, `ROUTER`, `SAVINGS_XDAI_RECEIVER_FACTORY`, `TENDERLY_GNOSIS_RPC_URL` or `GNOSIS_RPC_URL`, `WATCHTOWER_PRIVATE_KEY`, `WATCHTOWER_BATCH_SIZE`, and `WATCHTOWER_MAX_AGE_SECONDS` as Action secrets.
- Configure the frontend with the public `Deterministic-Bridger` webhook URL. Do not ship Tenderly API keys or Action secrets in frontend code.
- Verify public-webhook controls: fresh receipt validation, `WATCHTOWER_BATCH_SIZE`, `WATCHTOWER_MAX_AGE_SECONDS`, and a funded executor key with limited operational balance.
- Disable or delete older prefixed Tenderly Actions after the new Action is deployed.
