# `BucketShop`

## Disclaimer

> **FOR EDUCATION AND DEMONSTRATION PURPOSES ONLY.** Deploying or executing this smart contract with real funds would certainly constitute operating an **unlicensed gambling or derivatives betting service**, which is **illegal in most jurisdictions** — including the US, UK, EU, and many others. Operating such a service without appropriate regulatory licences (e.g. CFTC, FCA) can result in criminal prosecution, civil penalties, and asset forfeiture. **Do not deploy this contract on mainnet or any public blockchain with real funds. The authors accept no liability for any losses, legal consequences, or damages arising from misuse of this code.**

---

## Overview

`BucketShop.sol` is a two-party binary options / bucket-shop style betting contract written in Solidity `^0.8.0`. It allows a *Bookie* and a *Gambler* to enter a directional price bet on an underlying asset (e.g. ETH/USD), settled on-chain using a [Chainlink](https://data.chain.link) price feed.

The name is a historical reference to **bucket shops** — 19th-century off-exchange establishments that allowed customers to speculate on stock and commodity prices without any actual asset changing hands. They were banned in the US by the early 20th century, and the term lives on in financial regulation as a byword for unlicensed derivatives dealing.

---

## How It Works

### Parties

| Role | Description |
|------|-------------|
| **Bookie** (`publicBookie`) | Sets up the contract and may cancel it before funding. Takes the other side of every bet. |
| **Gambler** (`publicGambler`) | Funds the bet with ETH and picks a direction (`long` or `short`) and a strike price. |

### Lifecycle

```
Deploy → fundBet() → [wait for expiry] → settle()
                  └→ cancel()  (bookie only, before funding)
```

1. **Deploy** — The Bookie deploys the contract, supplying both party addresses, the underlying ticker symbol, the expiry Unix timestamp, and the Chainlink feed address for the asset.
2. **`fundBet()`** — The Gambler calls this before expiry, providing the stake amount (in wei), a direction (`"long"` or `"short"`), and a strike price. The contract records the Chainlink entry price at the time of funding.
3. **`settle()`** — Anyone may call this after the expiry timestamp. The contract fetches the current Chainlink price and pays the full stake to the winner:
   - `long` → Gambler wins if `settlementPrice >= strikePrice`, else Bookie wins.
   - `short` → Gambler wins if `settlementPrice < strikePrice`, else Bookie wins.
4. **`cancel()`** — The Bookie may cancel and destroy the contract at any time before it is funded.

---

## Deployment

### Constructor Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `publicBookieAddress` | `address` | Wallet address of the Bookie |
| `publicGamblerAddress` | `address` | Wallet address of the Gambler |
| `underlyingTicker` | `string` | Human-readable ticker label (e.g. `"ETH/USD"`) |
| `_executionTimeUnixTimestamp` | `uint256` | Unix timestamp after which the bet may be settled |
| `priceFeedAddress` | `address` | Chainlink AggregatorV3 feed address for the asset |

### Example Chainlink Feed Addresses (Ethereum Mainnet)

| Asset | Address |
|-------|---------|
| ETH / USD | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` |
| BTC / USD | `0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88b` |
| LINK / USD | `0x2c1d072e956AFFC0D435Cb7AC38EF18d24d9127c` |

A full list is available at [data.chain.link](https://data.chain.link).

---

## Key Design Decisions & Limitations

- **No escrow** — The contract does not hold the Bookie's matching stake. Only the Gambler's ETH is held. A production version would require both sides to deposit equal stakes.
- **Single bet** — Each deployed contract represents exactly one bet. Deploy a new instance per wager.
- **Chainlink staleness guard** — Prices older than 1 hour are rejected to prevent manipulation via stale feeds.
- **String direction comparison** — Direction strings are compared via `keccak256` hash to avoid Solidity's lack of native string equality.
- **`selfdestruct` in `cancel()`** — Note that `selfdestruct` behaviour changed in EIP-6780 (Dencun upgrade, March 2024). On mainnet post-Dencun, `selfdestruct` no longer deletes contract code; it only sends ETH to the target address.

---

## Development & Testing

Recommended toolchain: [Hardhat](https://hardhat.org) or [Foundry](https://book.getfoundry.sh).

```bash
# Install Hardhat
npm install --save-dev hardhat

# Compile
npx hardhat compile

# Test (add your own test suite under /test)
npx hardhat test
```

For local testing, use a mock Chainlink aggregator or [Chainlink's MockV3Aggregator](https://github.com/smartcontractkit/chainlink/blob/develop/contracts/src/v0.8/tests/MockV3Aggregator.sol) to avoid dependency on live feeds.

---

## License

MIT — see source file header.
