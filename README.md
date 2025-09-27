# HashSplits Orchestrator

Smart contracts, scripts, and tests for the HashSplits AI revenue-sharing proof‑of‑concept on Hedera. The
primary contract (`src/Orchestrator.sol`) manages immutable revenue splits on Hedera,
handles both custodial balances and HBAR allowances, and issues scheduled transfers via
the Hedera Schedule Service system contract.

## Repository Layout

- `src/Orchestrator.sol` – production contract
- `script/DeployOrchestrator.sol` – Foundry script for deploying the orchestrator
- `test/Orchestrator.t.sol` – unit tests with Hedera system-contract mocks
- `broadcast/` – on-chain deployment artefacts (`forge script --broadcast`)

## Tooling

This project uses [Foundry](https://book.getfoundry.sh/) for compilation, scripting, and
Solidity unit testing.

```bash
forge build             # compile contracts
forge test              # run unit tests (uses local mocks for HTS/HSS/HAS)
forge fmt               # format solidity sources and tests
```

## Hedera Testnet Deployment

Latest deployment (verified via Hashscan/Sourcify):

- **Network:** Hedera Testnet (`chainId 296`)
- **Contract:** `Orchestrator`
- **Address:** `0xbC0124204A9e8301fD96C637f3225F52c51fFAC0`
- **Hashscan:** <https://hashscan.io/testnet/contract/0xbC0124204A9e8301fD96C637f3225F52c51fFAC0>
- **Verification:** Sourcify (automatic during `forge script --verify`)

Deployment command used:

```bash
forge script script/DeployOrchestrator.sol \
  --rpc-url https://testnet.hashio.io/api \
  --broadcast \
  --verify \
  --verifier sourcify \
  --verifier-url https://server-verify.hashscan.io/
```

Set `HEDERA_PRIVATE_KEY` in your environment (or `.env`) to the hex-encoded private key
for the account paying deployment fees.

## Notes

- Unit tests rely on Foundry cheatcodes (`vm.etch`) to stand-in for Hedera system
  contracts; they run locally and do not require Hedera connectivity.
- Scheduled transfer status must still be confirmed off-chain until Hedera exposes a
  read-only Schedule Service query via the system contract.
