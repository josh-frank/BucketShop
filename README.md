# `BucketShop`

## Disclaimer

> **FOR EDUCATION AND DEMONSTRATION PURPOSES ONLY!** Deploying or executing this smart contract with real funds would certainly constitute operating an unlicensed gambling or derivatives betting service, which is illegal in the US, UK, EU, and basically everywhere. Operating such a service without appropriate regulatory licences (e.g. CFTC, FCA) can result in criminal prosecution, civil penalties, and asset forfeiture. **Don't deploy this contract on mainnet or any public blockchain with real funds! The author accepts no liability for any losses, legal consequences, or damages due to misuse of this code.**

---

## Overview

`BucketShop.sol` is a two-party binary options / bucket-shop style betting contract written in Solidity `^0.8.0`. It allows a *Bookie* and a *Gambler* to enter a directional price bet on an underlying asset (e.g. BTC/USD), settled on-chain using a [Pyth Network](https://pyth.network) price feed.

The name is a historical reference to **bucket shops** — 19th-century off-exchange establishments that allowed customers to speculate on stock and commodity prices without any actual asset changing hands. They were banned in the US by the early 20th century, and the term lives on in financial regulation as a byword for unlicensed derivatives dealing.

---

## How It Works

### Parties

| Role | Description |
|------|-------------|
| **Bookie** (`publicBookie`) | Deploys the contract, escrows their matching stake, and may cancel before the gambler funds. Takes the other side of every bet. |
| **Gambler** (`publicGambler`) | Matches the bookie's stake and picks a direction (`long` or `short`) and a strike price. |

### Lifecycle

```
Deploy → escrowBookie() → fundBet() → [wait for expiry] → settle()
                       └→ cancel()  (bookie only, before gambler funds)
```

1. **Deploy** — The Bookie deploys the contract, supplying both party addresses, the underlying ticker symbol, the expiry Unix timestamp, the Pyth contract address, and the Pyth price feed ID for the asset.
2. **`escrowBookie()`** — The Bookie calls this first, locking their ETH stake into the contract. This sets the stake amount that the Gambler must match.
3. **`fundBet()`** — The Gambler calls this before expiry, sending exactly the bookie's stake in ETH, and choosing a direction (`"long"` or `"short"`) and a strike price. The Pyth entry price is snapped at this moment. The contract is now fully funded (2× stake).
4. **`settle()`** — Anyone may call this after the expiry timestamp. The contract fetches the current Pyth price and pays the full pot (2× stake) to the winner:
   - `long` → Gambler wins if `settlementPrice >= strikePrice`, else Bookie wins.
   - `short` → Gambler wins if `settlementPrice < strikePrice`, else Bookie wins.
5. **`cancel()`** — The Bookie may cancel and reclaim their escrowed ETH at any time before the Gambler funds.

---

## Deployment

### Constructor Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `publicBookieAddress` | `address` | Wallet address of the Bookie |
| `publicGamblerAddress` | `address` | Wallet address of the Gambler |
| `underlyingTicker` | `string` | Human-readable ticker label (e.g. `"BTC/USD"`) |
| `_executionTimeUnixTimestamp` | `uint256` | Unix timestamp after which the bet may be settled |
| `pythAddress` | `address` | Address of the Pyth contract on this chain |
| `_pythPriceFeedId` | `bytes32` | Pyth price feed ID for the underlying asset |

### Example Pyth Feed IDs

| Asset | Feed ID |
|-------|---------|
| BTC / USD | `0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43` |
| ETH / USD | `0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace` |
| SOL / USD | `0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d` |
| Gold XAU / USD | `0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2` |
| WTI Crude Oil | `0x0f9fe0eba46d779c4b54f76888d70b2a78e2d1a9e39d2ef5ebe5e00a4ffb7f51` |

Feed IDs are chain-agnostic. The full list is at [pyth.network/developers/price-feed-ids](https://pyth.network/developers/price-feed-ids).

### Pyth Contract Addresses

| Network | Address |
|---------|---------|
| Ethereum Mainnet | `0x4305FB66699C3B2702D4d05CF36551390A4c69C6` |
| Base | `0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a` |
| Arbitrum One | `0xff1a0f4744e8582DF1aE09D5611b887B6a12925C` |

Full list at [docs.pyth.network/price-feeds/contract-addresses](https://docs.pyth.network/price-feeds/contract-addresses).

---

## Key Design Decisions

- **Escrow both sides** — Both the Bookie and Gambler deposit equal stakes into the contract. The winner receives the full 2× pot. Neither party can back out after the Gambler funds.
- **Pyth Network oracle** — Replaces Chainlink to support a much wider set of asset classes (crypto, equities, FX, commodities, rates). Pyth uses a push model: if the on-chain price is stale, call `refreshPythPrice()` with a VAA update before settling.
- **Staleness guard** — Prices older than 60 seconds are rejected at settlement. Call `refreshPythPrice(updateData)` with bytes from the [Hermes API](https://hermes.pyth.network) if needed.
- **Single bet per contract** — Each deployed instance represents exactly one wager. Deploy a new contract per bet.
- **String direction comparison** — Direction strings are compared via `keccak256` to avoid Solidity's lack of native string equality.
- **No `selfdestruct`** — `cancel()` now simply transfers escrowed ETH back to the Bookie rather than using `selfdestruct`, which has changed behaviour post-EIP-6780 (Dencun, March 2024).

---

## Development & Testing

Toolchain: [Foundry](https://book.getfoundry.sh).

```bash
# 1. Install Foundry (one-time)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# 2. Install forge-std
forge install foundry-rs/forge-std --no-git

# 3. Run full test suite
forge test -vv

# 4. Run with more fuzz iterations
forge test -vv --fuzz-runs 1000

# 5. Run a single test group (e.g. settle tests)
forge test -vv --match-test "test_D|test_E|test_F"

# 6. Gas snapshot
forge snapshot
```

### Project Layout

```
BucketShop/
├── foundry.toml
├── README.md
├── src/
│   └── BucketShop.sol          # Main contract
├── test/
│   ├── MockPyth.sol            # Controllable Pyth oracle stub
│   └── BucketShop.t.sol        # Full test suite (34 tests)
└── script/
```

### Test Groups

| Group | What's tested |
|-------|--------------|
| A | Constructor stores all params correctly |
| B | `escrowBookie()` — happy path, access control, double-escrow, zero ETH, after expiry |
| C | `fundBet()` — happy path, access control, stake mismatch, double-fund, bad direction, after expiry |
| D | `settle()` long — wins above strike, wins at strike (≥), loses below strike |
| E | `settle()` short — wins below strike, loses above/at strike |
| F | `settle()` edge cases — too early, not funded, double-settle, third-party settles, stale Pyth price |
| G | `cancel()` — refund to bookie, no-escrow no-op, access control, can't cancel after funded |
| H | `refreshPythPrice()` — fee forwarded, excess refunded, reverts if underpaid |
| I | Pyth price normalisation — expo −8, expo −5, expo 0 |
| J | Fuzz — long winner invariant, short loser invariant, pot conservation |

For local oracle testing, `MockPyth.sol` lets you set arbitrary prices and publish times directly — no live feed dependency needed.

---

## License

MIT — see source file header.