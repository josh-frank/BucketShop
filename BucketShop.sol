// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Chainlink AggregatorV3Interface
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

contract BucketShop {
    address private publicBookie;
    address private publicGambler;
    string private _underlyingTicker;
    uint256 private executionTimeUnixTimestamp;
    uint256 private stakeWei = 0;
    string private direction = "";
    uint256 private strikePrice = 0;
    uint256 private entryPrice = 0;
    uint256 private settlementPrice = 0;
    bool public isFunded = false;
    bool public isSettled = false;

    // Chainlink price feed address for the underlying asset
    AggregatorV3Interface private priceFeed;

    // Event emitted when bet is funded
    event BetFunded(
        address indexed gambler,
        uint256 stakeWei,
        string direction,
        uint256 strikePrice,
        uint256 entryPrice
    );

    // Event emitted when bet is settled
    event BetSettled(
        uint256 settlementPrice,
        address winner,
        uint256 payoutWei
    );

    // Event emitted when bet is cancelled
    event BetCancelled(address indexed bookie);

    // FIX 1: Removed invalid `public` visibility modifier from constructor (not allowed in Solidity >=0.7)
    // FIX 2: Added `priceFeedAddress` parameter to wire up Chainlink feed
    // FIX 3: Renamed constructor parameter to `_executionTimeUnixTimestamp` to avoid
    //         self-assignment shadowing bug (was: executionTimeUnixTimestamp = executionTimeUnixTimestamp)
    constructor(
        address publicBookieAddress,
        address publicGamblerAddress,
        string memory underlyingTicker,
        uint256 _executionTimeUnixTimestamp,
        address priceFeedAddress
    ) {
        publicBookie = publicBookieAddress;
        publicGambler = publicGamblerAddress;
        _underlyingTicker = underlyingTicker;
        executionTimeUnixTimestamp = _executionTimeUnixTimestamp; // FIX 3
        priceFeed = AggregatorV3Interface(priceFeedAddress);      // FIX 2
    }

    // Function to fund the bet
    function fundBet(
        address msgSender,
        uint256 msgValueWei,
        string memory directionStr,
        uint256 strikePriceUint
    ) public {
        require(msgSender == publicGambler, "Only the designated gambler may fund");
        require(!isFunded, "Already funded");
        require(msgValueWei > 0, "Must send ETH");
        require(
            keccak256(bytes(directionStr)) == keccak256(bytes("long")) ||
            keccak256(bytes(directionStr)) == keccak256(bytes("short")),
            "Direction must be long or short"
        );
        // FIX 4: Was `executionTime` (undeclared); corrected to `executionTimeUnixTimestamp`
        require(block.timestamp < executionTimeUnixTimestamp, "Bet window has passed");

        stakeWei = msgValueWei;
        direction = directionStr;
        strikePrice = strikePriceUint;
        isFunded = true;

        entryPrice = _getChainlinkPrice();

        emit BetFunded(
            publicGambler,
            stakeWei,
            direction,
            strikePrice,
            entryPrice
        );
    }

    // Function to settle the contract after expiry
    function settle() public {
        require(isFunded, "Contract not funded");
        require(!isSettled, "Already settled");
        // FIX 5: Was `block.timestamp >= block.timestamp + executionTimeUnixTimestamp`
        //         which is always false (tautological overflow). Corrected to compare
        //         current time against the stored expiry timestamp.
        require(block.timestamp >= executionTimeUnixTimestamp, "Too early to settle");

        settlementPrice = _getChainlinkPrice();

        // FIX 6: Settlement logic now correctly compares settlementPrice vs strikePrice.
        //         Previously, the winner was determined only by direction string, ignoring
        //         whether the price actually moved in the predicted direction.
        address winnerAddress;
        if (keccak256(bytes(direction)) == keccak256(bytes("long"))) {
            // Gambler wins if price rose above strike
            winnerAddress = settlementPrice >= strikePrice ? publicGambler : publicBookie;
        } else {
            // Gambler wins if price fell below strike
            winnerAddress = settlementPrice < strikePrice ? publicGambler : publicBookie;
        }

        isSettled = true;

        payable(winnerAddress).transfer(stakeWei);

        emit BetSettled(settlementPrice, winnerAddress, stakeWei);
    }

    // FIX 7: Replaced fake `chainlink_call()` with real AggregatorV3Interface call.
    //         Return type corrected: Chainlink returns int256 for answer, uint80 for roundId.
    function _getChainlinkPrice() private view returns (uint256) {
        (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        // Suppress unused variable warnings
        roundId;
        updatedAt;
        answeredInRound;

        require(answer > 0, "Invalid Chainlink price");
        require(block.timestamp - startedAt < 3600, "Chainlink price is stale");

        return uint256(answer);
    }

    // Function to cancel the bet
    function cancel(address msgSender) public {
        require(msgSender == publicBookie, "Only bookie may cancel");
        require(!isFunded, "Cannot cancel a funded bet");

        // FIX 8: BetCancelled event was emitted but never declared — now declared above.
        emit BetCancelled(publicBookie);

        // FIX 9: selfdestruct requires address payable; cast added.
        selfdestruct(payable(publicBookie));
    }
}
