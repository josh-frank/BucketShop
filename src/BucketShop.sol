// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// ---------------------------------------------------------------------------
// Pyth Network interfaces
// ---------------------------------------------------------------------------

struct PythPrice {
    int64  price;       // Price in units of 10^expo
    uint64 conf;        // Confidence interval
    int32  expo;        // Exponent (typically negative, e.g. -8)
    uint   publishTime; // Unix timestamp of the price
}

struct PythPriceFeed {
    bytes32   id;
    PythPrice price;
    PythPrice emaPrice;
}

interface IPyth {
    /// @notice Returns the current price for a given price feed ID.
    ///         Reverts if the price is not available or too stale.
    function getPriceNoOlderThan(
        bytes32 id,
        uint    age          // max acceptable age in seconds
    ) external view returns (PythPrice memory price);

    /// @notice Returns the fee required to update price feeds on-chain.
    function getUpdateFee(
        bytes[] calldata updateData
    ) external view returns (uint feeAmount);

    /// @notice Submits fresh price-update VAAs to the Pyth contract.
    ///         Must be called with msg.value >= getUpdateFee(updateData).
    function updatePriceFeeds(
        bytes[] calldata updateData
    ) external payable;
}

// ---------------------------------------------------------------------------
// BucketShop
// ---------------------------------------------------------------------------

/**
 * @title  BucketShop
 * @notice A bilateral binary-options contract between a bookie and a gambler.
 *
 * Lifecycle
 * ---------
 * 1. Bookie deploys the contract, specifying both parties, the underlying
 *    asset's Pyth price-feed ID, and the expiry timestamp.
 *
 * 2. Bookie calls `escrowBookie()` with ETH equal to the intended stake.
 *    Funds are held in the contract (escrow).
 *
 * 3. Gambler calls `fundBet()` with the same ETH amount, their direction
 *    ("long" / "short"), and a strike price.  The entry price is snapped
 *    from Pyth at this moment.  The contract is now fully funded (2× stake).
 *
 * 4. After `executionTimeUnixTimestamp` passes, anyone calls `settle()`.
 *    Pyth is queried for the settlement price and the winner receives the
 *    full 2× pot.
 *
 * 5. Before the gambler funds, the bookie may call `cancel()` to reclaim
 *    their escrowed ETH.
 *
 * Pyth price feeds
 * ----------------
 * Pyth feed IDs are 32-byte identifiers — one per asset, usable across all
 * EVM chains.  Examples:
 *   BTC/USD  0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43
 *   ETH/USD  0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace
 *   SOL/USD  0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d
 *   Gold XAU 0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2
 *   WTI Oil  0x0f9fe0eba46d779c4b54f76888d70b2a78e2d1a9e39d2ef5ebe5e00a4ffb7f51
 * Full list: https://pyth.network/developers/price-feed-ids
 */
contract BucketShop {

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    address private publicBookie;
    address private publicGambler;
    string  private _underlyingTicker;
    uint256 private executionTimeUnixTimestamp;

    uint256 private stakeWei      = 0;
    string  private direction     = "";
    uint256 private strikePrice   = 0;   // 18-decimal normalised
    uint256 private entryPrice    = 0;   // 18-decimal normalised
    uint256 private settlementPrice = 0; // 18-decimal normalised

    bool public isBookieEscrowed = false; // bookie has deposited
    bool public isFunded         = false; // gambler has deposited
    bool public isSettled        = false;

    // Pyth oracle
    IPyth   private pyth;
    bytes32 private pythPriceFeedId;

    // Maximum acceptable price age when reading Pyth (60 s is generous for
    // settlement; tighten if needed).
    uint private constant MAX_PRICE_AGE = 60;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event BookieEscrowed(address indexed bookie, uint256 amountWei);

    event BetFunded(
        address indexed gambler,
        uint256 stakeWei,
        string  direction,
        uint256 strikePrice,
        uint256 entryPrice
    );

    event BetSettled(
        uint256 settlementPrice,
        address winner,
        uint256 payoutWei
    );

    event BetCancelled(address indexed bookie, uint256 refundWei);

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /**
     * @param publicBookieAddress   Bookie wallet.
     * @param publicGamblerAddress  Gambler wallet.
     * @param underlyingTicker      Human-readable ticker, e.g. "BTC/USD".
     * @param _executionTimeUnixTimestamp  Unix timestamp at which the bet expires.
     * @param pythAddress           Address of the Pyth contract on this chain.
     *                              https://docs.pyth.network/price-feeds/contract-addresses
     * @param _pythPriceFeedId      32-byte Pyth price-feed ID for the underlying.
     */
    constructor(
        address publicBookieAddress,
        address publicGamblerAddress,
        string  memory underlyingTicker,
        uint256 _executionTimeUnixTimestamp,
        address pythAddress,
        bytes32 _pythPriceFeedId
    ) {
        publicBookie               = publicBookieAddress;
        publicGambler              = publicGamblerAddress;
        _underlyingTicker          = underlyingTicker;
        executionTimeUnixTimestamp = _executionTimeUnixTimestamp;
        pyth                       = IPyth(pythAddress);
        pythPriceFeedId            = _pythPriceFeedId;
    }

    // -----------------------------------------------------------------------
    // Escrow — bookie deposits first
    // -----------------------------------------------------------------------

    /**
     * @notice Bookie locks their matching stake into the contract.
     *         Must be called before `fundBet`.
     *
     * @dev    If Pyth requires a price-feed update before the bookie escrows
     *         (unlikely at this stage), call `refreshPythPrice` first.
     */
    function escrowBookie() external payable {
        require(msg.sender == publicBookie,  "Only the bookie may escrow");
        require(!isBookieEscrowed,           "Bookie already escrowed");
        require(!isFunded,                   "Bet already funded");
        require(msg.value > 0,               "Must send ETH");
        require(
            block.timestamp < executionTimeUnixTimestamp,
            "Bet window has passed"
        );

        stakeWei          = msg.value;
        isBookieEscrowed  = true;

        emit BookieEscrowed(publicBookie, stakeWei);
    }

    // -----------------------------------------------------------------------
    // Fund — gambler matches the bookie's stake
    // -----------------------------------------------------------------------

    /**
     * @notice Gambler funds the bet with `msg.value` == bookie's stake.
     *
     * @param directionStr   "long" or "short".
     * @param strikePriceUint  Strike price in 18-decimal normalised form
     *                         (same units returned by `_getPythPrice()`).
     */
    function fundBet(
        string memory directionStr,
        uint256       strikePriceUint
    ) external payable {
        require(msg.sender == publicGambler, "Only the designated gambler may fund");
        require(isBookieEscrowed,            "Bookie has not escrowed yet");
        require(!isFunded,                   "Already funded");
        require(msg.value == stakeWei,       "Must match bookie's stake exactly");
        require(
            keccak256(bytes(directionStr)) == keccak256(bytes("long")) ||
            keccak256(bytes(directionStr)) == keccak256(bytes("short")),
            "Direction must be 'long' or 'short'"
        );
        require(
            block.timestamp < executionTimeUnixTimestamp,
            "Bet window has passed"
        );

        direction   = directionStr;
        strikePrice = strikePriceUint;
        isFunded    = true;

        entryPrice = _getPythPrice();

        emit BetFunded(
            publicGambler,
            stakeWei,
            direction,
            strikePrice,
            entryPrice
        );
    }

    // -----------------------------------------------------------------------
    // Settle
    // -----------------------------------------------------------------------

    /**
     * @notice Settles the bet after expiry.  Callable by anyone.
     *
     * @dev    If the on-chain Pyth price is stale at settlement time, call
     *         `refreshPythPrice` (with the update bytes + fee) first, then
     *         call `settle`.
     */
    function settle() external {
        require(isFunded,                                        "Contract not funded");
        require(!isSettled,                                      "Already settled");
        require(block.timestamp >= executionTimeUnixTimestamp,   "Too early to settle");

        settlementPrice = _getPythPrice();

        address winnerAddress;
        if (keccak256(bytes(direction)) == keccak256(bytes("long"))) {
            winnerAddress = settlementPrice >= strikePrice ? publicGambler : publicBookie;
        } else {
            winnerAddress = settlementPrice <  strikePrice ? publicGambler : publicBookie;
        }

        isSettled = true;

        uint256 pot = stakeWei * 2;
        payable(winnerAddress).transfer(pot);

        emit BetSettled(settlementPrice, winnerAddress, pot);
    }

    // -----------------------------------------------------------------------
    // Cancel — bookie reclaims escrow before gambler funds
    // -----------------------------------------------------------------------

    /**
     * @notice Bookie cancels and withdraws their escrowed ETH.
     *         Only valid before the gambler has funded.
     */
    function cancel() external {
        require(msg.sender == publicBookie, "Only bookie may cancel");
        require(!isFunded,                  "Cannot cancel a funded bet");

        uint256 refund = stakeWei;

        // Reset escrow state before transfer (re-entrancy guard)
        isBookieEscrowed = false;
        stakeWei         = 0;

        if (refund > 0) {
            payable(publicBookie).transfer(refund);
        }

        emit BetCancelled(publicBookie, refund);
    }

    // -----------------------------------------------------------------------
    // Pyth helpers
    // -----------------------------------------------------------------------

    /**
     * @notice Push a fresh Pyth price-update VAA on-chain.
     *         Must be called with msg.value >= pyth.getUpdateFee(updateData).
     *         Typically needed only when the on-chain price is older than
     *         MAX_PRICE_AGE seconds.
     *
     * @param updateData  Array of VAA bytes obtained from the Pyth Hermes API:
     *                    https://hermes.pyth.network/api/latest_vaas?ids[]=<feedId>
     */
    function refreshPythPrice(bytes[] calldata updateData) external payable {
        uint fee = pyth.getUpdateFee(updateData);
        require(msg.value >= fee, "Insufficient fee for Pyth update");
        pyth.updatePriceFeeds{value: fee}(updateData);

        // Refund any excess ETH
        uint256 excess = msg.value - fee;
        if (excess > 0) {
            payable(msg.sender).transfer(excess);
        }
    }

    /**
     * @dev  Reads the Pyth price and normalises it to 18 decimals.
     *       Pyth returns `price * 10^expo` where expo is typically negative.
     */
    function _getPythPrice() private view returns (uint256) {
        PythPrice memory p = pyth.getPriceNoOlderThan(pythPriceFeedId, MAX_PRICE_AGE);

        require(p.price > 0, "Invalid Pyth price");

        // Normalise to 18 decimals.
        // p.price is in units of 10^p.expo, so:
        //   normalised = p.price * 10^(18 + p.expo)   if expo <= 0
        uint256 rawPrice = uint256(uint64(p.price));

        if (p.expo >= 0) {
            // Positive exponent — multiply up, then scale to 18 dp
            uint256 factor = 10 ** uint32(p.expo);
            return rawPrice * factor * (10 ** 18) / (10 ** 18);
        } else {
            // Typical case: expo is negative (e.g. -8)
            uint256 pythDecimals = uint256(uint32(-p.expo)); // e.g. 8
            if (pythDecimals <= 18) {
                return rawPrice * (10 ** (18 - pythDecimals));
            } else {
                return rawPrice / (10 ** (pythDecimals - 18));
            }
        }
    }

    // -----------------------------------------------------------------------
    // View helpers
    // -----------------------------------------------------------------------

    function getStakeWei()            external view returns (uint256) { return stakeWei; }
    function getDirection()           external view returns (string memory) { return direction; }
    function getStrikePrice()         external view returns (uint256) { return strikePrice; }
    function getEntryPrice()          external view returns (uint256) { return entryPrice; }
    function getSettlementPrice()     external view returns (uint256) { return settlementPrice; }
    function getExecutionTimestamp()  external view returns (uint256) { return executionTimeUnixTimestamp; }
    function getBookie()              external view returns (address)  { return publicBookie; }
    function getGambler()             external view returns (address)  { return publicGambler; }
    function getUnderlyingTicker()    external view returns (string memory) { return _underlyingTicker; }
    function getPythFeedId()          external view returns (bytes32)  { return pythPriceFeedId; }

    // Convenience: pot size once fully funded
    function getTotalPot()            external view returns (uint256) {
        return isFunded ? stakeWei * 2 : 0;
    }
}
