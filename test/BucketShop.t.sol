// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/BucketShop.sol";
import "./MockPyth.sol";

/**
 * @title  BucketShopTest
 * @notice Foundry test suite for BucketShop.
 *
 * Test groups
 * -----------
 *  A. Deployment / constructor
 *  B. escrowBookie()
 *  C. fundBet()
 *  D. settle() — long wins
 *  E. settle() — short wins
 *  F. settle() — edge cases (price == strike, settle twice, too early)
 *  G. cancel()
 *  H. refreshPythPrice()
 *  I. Pyth price normalisation (expo variations)
 *  J. Fuzz — stake amounts & strike prices
 */
contract BucketShopTest is Test {

    // -----------------------------------------------------------------------
    // Constants & shared state
    // -----------------------------------------------------------------------

    bytes32 constant FEED_ID =
        0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43; // BTC/USD

    // Prices expressed as Pyth raw int64 with expo -8  (i.e. value * 1e8)
    int32  constant EXPO           = -8;
    int64  constant ENTRY_RAW      = 6000000000000; // $60 000.00000000
    int64  constant STRIKE_RAW     = 6100000000000; // $61 000.00000000
    int64  constant ABOVE_STRIKE   = 6200000000000; // $62 000  (long wins)
    int64  constant BELOW_STRIKE   = 6050000000000; // $60 500  (short wins)
    int64  constant AT_STRIKE      = 6100000000000; // $61 000  (== strike)

    // 18-decimal normalised equivalents  (raw * 10^(18-8) = raw * 1e10)
    uint256 constant ENTRY_18    = uint256(uint64(ENTRY_RAW))  * 1e10;
    uint256 constant STRIKE_18   = uint256(uint64(STRIKE_RAW)) * 1e10;
    uint256 constant ABOVE_18    = uint256(uint64(ABOVE_STRIKE))* 1e10;
    uint256 constant BELOW_18    = uint256(uint64(BELOW_STRIKE))* 1e10;

    uint256 constant STAKE       = 1 ether;
    uint256 constant EXPIRY_DELTA = 1 days; // offset from deployment time

    address bookie  = makeAddr("bookie");
    address gambler = makeAddr("gambler");
    address rando   = makeAddr("rando");

    MockPyth   mock;
    BucketShop shop;
    uint256    expiry;

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _deploy() internal {
        expiry = block.timestamp + EXPIRY_DELTA;
        mock   = new MockPyth();
        shop   = new BucketShop(
            bookie,
            gambler,
            "BTC/USD",
            expiry,
            address(mock),
            FEED_ID
        );
        // Fund actors
        vm.deal(bookie,  100 ether);
        vm.deal(gambler, 100 ether);
        vm.deal(rando,   10 ether);
        // Prime oracle with a fresh entry price
        mock.setPrice(FEED_ID, ENTRY_RAW, EXPO);
    }

    /// Full happy-path setup up to (but not including) settle.
    function _setupFunded(string memory dir) internal {
        _deploy();
        vm.prank(bookie);
        shop.escrowBookie{value: STAKE}();

        vm.prank(gambler);
        shop.fundBet{value: STAKE}(dir, STRIKE_18);
    }

    // -----------------------------------------------------------------------
    // A. Deployment / constructor
    // -----------------------------------------------------------------------

    function test_A_constructorStoresParams() public {
        _deploy();
        assertEq(shop.getBookie(),           bookie);
        assertEq(shop.getGambler(),          gambler);
        assertEq(shop.getUnderlyingTicker(), "BTC/USD");
        assertEq(shop.getExecutionTimestamp(), expiry);
        assertEq(shop.getPythFeedId(),       FEED_ID);
        assertFalse(shop.isBookieEscrowed());
        assertFalse(shop.isFunded());
        assertFalse(shop.isSettled());
    }

    // -----------------------------------------------------------------------
    // B. escrowBookie()
    // -----------------------------------------------------------------------

    function test_B_bookieEscrowHappyPath() public {
        _deploy();
        uint256 before = address(shop).balance;

        vm.expectEmit(true, false, false, true, address(shop));
        emit BucketShop.BookieEscrowed(bookie, STAKE);

        vm.prank(bookie);
        shop.escrowBookie{value: STAKE}();

        assertTrue(shop.isBookieEscrowed());
        assertEq(shop.getStakeWei(), STAKE);
        assertEq(address(shop).balance, before + STAKE);
    }

    function test_B_onlyBookieCanEscrow() public {
        _deploy();
        vm.prank(gambler);
        vm.expectRevert("Only the bookie may escrow");
        shop.escrowBookie{value: STAKE}();
    }

    function test_B_cannotEscrowTwice() public {
        _deploy();
        vm.prank(bookie);
        shop.escrowBookie{value: STAKE}();

        vm.prank(bookie);
        vm.expectRevert("Bookie already escrowed");
        shop.escrowBookie{value: STAKE}();
    }

    function test_B_cannotEscrowZero() public {
        _deploy();
        vm.prank(bookie);
        vm.expectRevert("Must send ETH");
        shop.escrowBookie{value: 0}();
    }

    function test_B_cannotEscrowAfterExpiry() public {
        _deploy();
        vm.warp(expiry + 1);
        vm.prank(bookie);
        vm.expectRevert("Bet window has passed");
        shop.escrowBookie{value: STAKE}();
    }

    // -----------------------------------------------------------------------
    // C. fundBet()
    // -----------------------------------------------------------------------

    function test_C_gamblerFundHappyPath() public {
        _deploy();
        vm.prank(bookie);
        shop.escrowBookie{value: STAKE}();

        uint256 before = address(shop).balance;

        vm.expectEmit(true, false, false, true, address(shop));
        emit BucketShop.BetFunded(gambler, STAKE, "long", STRIKE_18, ENTRY_18);

        vm.prank(gambler);
        shop.fundBet{value: STAKE}("long", STRIKE_18);

        assertTrue(shop.isFunded());
        assertEq(shop.getDirection(),   "long");
        assertEq(shop.getStrikePrice(), STRIKE_18);
        assertEq(shop.getEntryPrice(),  ENTRY_18);
        assertEq(shop.getTotalPot(),    STAKE * 2);
        assertEq(address(shop).balance, before + STAKE);
    }

    function test_C_onlyGamblerCanFund() public {
        _deploy();
        vm.prank(bookie);
        shop.escrowBookie{value: STAKE}();

        vm.prank(rando);
        vm.expectRevert("Only the designated gambler may fund");
        shop.fundBet{value: STAKE}("long", STRIKE_18);
    }

    function test_C_mustEscrowFirst() public {
        _deploy();
        vm.prank(gambler);
        vm.expectRevert("Bookie has not escrowed yet");
        shop.fundBet{value: STAKE}("long", STRIKE_18);
    }

    function test_C_mustMatchStakeExactly() public {
        _deploy();
        vm.prank(bookie);
        shop.escrowBookie{value: STAKE}();

        vm.prank(gambler);
        vm.expectRevert("Must match bookie's stake exactly");
        shop.fundBet{value: STAKE + 1}("long", STRIKE_18);
    }

    function test_C_cannotFundTwice() public {
        _setupFunded("long");
        vm.prank(gambler);
        vm.expectRevert("Already funded");
        shop.fundBet{value: STAKE}("long", STRIKE_18);
    }

    function test_C_invalidDirectionReverts() public {
        _deploy();
        vm.prank(bookie);
        shop.escrowBookie{value: STAKE}();

        vm.prank(gambler);
        vm.expectRevert("Direction must be 'long' or 'short'");
        shop.fundBet{value: STAKE}("up", STRIKE_18);
    }

    function test_C_cannotFundAfterExpiry() public {
        _deploy();
        vm.prank(bookie);
        shop.escrowBookie{value: STAKE}();

        vm.warp(expiry + 1);
        mock.setPrice(FEED_ID, ENTRY_RAW, EXPO); // keep price fresh

        vm.prank(gambler);
        vm.expectRevert("Bet window has passed");
        shop.fundBet{value: STAKE}("long", STRIKE_18);
    }

    function test_C_shortDirectionAccepted() public {
        _deploy();
        vm.prank(bookie);
        shop.escrowBookie{value: STAKE}();

        vm.prank(gambler);
        shop.fundBet{value: STAKE}("short", STRIKE_18);

        assertEq(shop.getDirection(), "short");
    }

    // -----------------------------------------------------------------------
    // D. settle() — long wins (price >= strike)
    // -----------------------------------------------------------------------

    function test_D_longWinsAboveStrike() public {
        _setupFunded("long");

        vm.warp(expiry);
        mock.setPrice(FEED_ID, ABOVE_STRIKE, EXPO);

        uint256 gamblerBefore = gambler.balance;
        uint256 bookieBefore  = bookie.balance;

        vm.expectEmit(false, false, false, true, address(shop));
        emit BucketShop.BetSettled(ABOVE_18, gambler, STAKE * 2);

        shop.settle();

        assertTrue(shop.isSettled());
        assertEq(gambler.balance, gamblerBefore + STAKE * 2);
        assertEq(bookie.balance,  bookieBefore);
        assertEq(address(shop).balance, 0);
    }

    function test_D_longWinsAtStrike() public {
        _setupFunded("long");

        vm.warp(expiry);
        mock.setPrice(FEED_ID, AT_STRIKE, EXPO);

        uint256 gamblerBefore = gambler.balance;

        shop.settle();

        // price == strike → long wins (>= check)
        assertEq(gambler.balance, gamblerBefore + STAKE * 2);
    }

    function test_D_longLosesBelowStrike() public {
        _setupFunded("long");

        vm.warp(expiry);
        mock.setPrice(FEED_ID, BELOW_STRIKE, EXPO);

        uint256 bookieBefore = bookie.balance;

        shop.settle();

        assertEq(bookie.balance, bookieBefore + STAKE * 2);
    }

    // -----------------------------------------------------------------------
    // E. settle() — short wins (price < strike)
    // -----------------------------------------------------------------------

    function test_E_shortWinsBelowStrike() public {
        _setupFunded("short");

        vm.warp(expiry);
        mock.setPrice(FEED_ID, BELOW_STRIKE, EXPO);

        uint256 gamblerBefore = gambler.balance;

        vm.expectEmit(false, false, false, true, address(shop));
        emit BucketShop.BetSettled(BELOW_18, gambler, STAKE * 2);

        shop.settle();

        assertEq(gambler.balance, gamblerBefore + STAKE * 2);
    }

    function test_E_shortLosesAboveStrike() public {
        _setupFunded("short");

        vm.warp(expiry);
        mock.setPrice(FEED_ID, ABOVE_STRIKE, EXPO);

        uint256 bookieBefore = bookie.balance;
        shop.settle();
        assertEq(bookie.balance, bookieBefore + STAKE * 2);
    }

    function test_E_shortLosesAtStrike() public {
        _setupFunded("short");

        // price == strike → short LOSES (< check, not <=)
        vm.warp(expiry);
        mock.setPrice(FEED_ID, AT_STRIKE, EXPO);

        uint256 bookieBefore = bookie.balance;
        shop.settle();
        assertEq(bookie.balance, bookieBefore + STAKE * 2);
    }

    // -----------------------------------------------------------------------
    // F. settle() — edge & revert cases
    // -----------------------------------------------------------------------

    function test_F_cannotSettleTooEarly() public {
        _setupFunded("long");
        // still before expiry
        vm.expectRevert("Too early to settle");
        shop.settle();
    }

    function test_F_cannotSettleIfNotFunded() public {
        _deploy();
        vm.warp(expiry);
        vm.expectRevert("Contract not funded");
        shop.settle();
    }

    function test_F_cannotSettleTwice() public {
        _setupFunded("long");
        vm.warp(expiry);
        mock.setPrice(FEED_ID, ABOVE_STRIKE, EXPO);
        shop.settle();

        vm.expectRevert("Already settled");
        shop.settle();
    }

    function test_F_anyoneCanSettle() public {
        _setupFunded("long");
        vm.warp(expiry);
        mock.setPrice(FEED_ID, ABOVE_STRIKE, EXPO);

        // rando (not bookie or gambler) calls settle — should succeed
        vm.prank(rando);
        shop.settle();
        assertTrue(shop.isSettled());
    }

    function test_F_stalePythPriceRevertsOnSettle() public {
        _setupFunded("long");
        vm.warp(expiry);

        // Age the price beyond MAX_PRICE_AGE (60 s)
        mock.setPriceWithTime(FEED_ID, ABOVE_STRIKE, EXPO, block.timestamp - 61);

        vm.expectRevert("MockPyth: price too stale");
        shop.settle();
    }

    // -----------------------------------------------------------------------
    // G. cancel()
    // -----------------------------------------------------------------------

    function test_G_bookieCancelBeforeGamblerFunds() public {
        _deploy();
        vm.prank(bookie);
        shop.escrowBookie{value: STAKE}();

        uint256 bookieBefore = bookie.balance;

        vm.expectEmit(true, false, false, true, address(shop));
        emit BucketShop.BetCancelled(bookie, STAKE);

        vm.prank(bookie);
        shop.cancel();

        assertFalse(shop.isBookieEscrowed());
        assertEq(shop.getStakeWei(), 0);
        assertEq(bookie.balance, bookieBefore + STAKE);
        assertEq(address(shop).balance, 0);
    }

    function test_G_cancelWithNoEscrowIsNoOp() public {
        _deploy();
        uint256 bookieBefore = bookie.balance;

        vm.prank(bookie);
        shop.cancel(); // refund == 0, should not revert

        assertEq(bookie.balance, bookieBefore); // no change
    }

    function test_G_onlyBookieCanCancel() public {
        _deploy();
        vm.prank(gambler);
        vm.expectRevert("Only bookie may cancel");
        shop.cancel();
    }

    function test_G_cannotCancelAfterFunded() public {
        _setupFunded("long");

        vm.prank(bookie);
        vm.expectRevert("Cannot cancel a funded bet");
        shop.cancel();
    }

    // -----------------------------------------------------------------------
    // H. refreshPythPrice()
    // -----------------------------------------------------------------------

    function test_H_refreshForwardsUpdateFee() public {
        _deploy();
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"deadbeef";

        uint256 shopBefore = address(shop).balance;

        // MockPyth.getUpdateFee returns 1 wei; send exactly that.
        vm.prank(rando);
        shop.refreshPythPrice{value: 1 wei}(updateData);

        // No excess, contract balance unchanged (fee went to MockPyth)
        assertEq(address(shop).balance, shopBefore);
    }

    function test_H_refreshRefundsExcessFee() public {
        _deploy();
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"deadbeef";

        uint256 randoBefore = rando.balance;

        // Send 1 ether; only 1 wei is the fee → 1 ether - 1 wei refunded
        vm.prank(rando);
        shop.refreshPythPrice{value: 1 ether}(updateData);

        assertApproxEqAbs(rando.balance, randoBefore - 1 wei, 0);
    }

    function test_H_refreshRevertsIfFeeTooLow() public {
        _deploy();
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"deadbeef";

        vm.prank(rando);
        vm.expectRevert("Insufficient fee for Pyth update");
        shop.refreshPythPrice{value: 0}(updateData); // fee is 1 wei
    }

    // -----------------------------------------------------------------------
    // I. Pyth price normalisation — expo variations
    // -----------------------------------------------------------------------

    /// expo = -8  (standard Pyth, e.g. BTC feeds)
    function test_I_normalisationExpoMinus8() public {
        _deploy();
        vm.prank(bookie);
        shop.escrowBookie{value: STAKE}();

        // price = 5000_0000_0000 (raw), expo = -8 → $50 000.00
        // normalised = 50000_0000_0000 * 10^(18-8) = 50000e18
        mock.setPrice(FEED_ID, 5000000000000, -8);

        vm.prank(gambler);
        shop.fundBet{value: STAKE}("long", STRIKE_18);

        uint256 expected = uint256(5000000000000) * 1e10; // 1e10 = 10^(18-8)
        assertEq(shop.getEntryPrice(), expected);
    }

    /// expo = -5  (less common, e.g. some commodity feeds)
    function test_I_normalisationExpoMinus5() public {
        _deploy();
        vm.prank(bookie);
        shop.escrowBookie{value: STAKE}();

        // price = 200_00000 (raw), expo = -5 → $2000.00000
        // normalised = 200_00000 * 10^(18-5) = 200_00000 * 10^13
        mock.setPrice(FEED_ID, 20000000, -5);

        vm.prank(gambler);
        shop.fundBet{value: STAKE}("long", STRIKE_18);

        uint256 expected = uint256(20000000) * (10 ** 13);
        assertEq(shop.getEntryPrice(), expected);
    }

    /// expo = 0  (hypothetical integer price)
    function test_I_normalisationExpoZero() public {
        _deploy();
        vm.prank(bookie);
        shop.escrowBookie{value: STAKE}();

        // price = 60000, expo = 0 → $60000 exactly
        // normalised = 60000 * 10^18
        mock.setPrice(FEED_ID, 60000, 0);

        vm.prank(gambler);
        shop.fundBet{value: STAKE}("long", STRIKE_18);

        uint256 expected = uint256(60000) * (10 ** 18);
        assertEq(shop.getEntryPrice(), expected);
    }

    // -----------------------------------------------------------------------
    // J. Fuzz — stake amounts & strike prices
    // -----------------------------------------------------------------------

    /// Long bet: gambler wins when settlement > strike regardless of amounts.
    function testFuzz_J_longWinnerIsAlwaysGambler(
        uint72 stakeAmount,   // uint72 keeps us well below address balance
        uint64 strikeRaw,
        uint64 settlementRaw
    ) public {
        vm.assume(stakeAmount > 0);
        vm.assume(strikeRaw   > 0);
        vm.assume(settlementRaw > strikeRaw); // long wins

        _deploy();

        uint256 stake18      = uint256(stakeAmount);
        uint256 strike18     = uint256(strikeRaw)     * 1e10;
        uint256 settlement18 = uint256(settlementRaw) * 1e10;

        vm.deal(bookie,  stake18 * 2);
        vm.deal(gambler, stake18 * 2);

        // Bookie escrows
        vm.prank(bookie);
        shop.escrowBookie{value: stake18}();

        // Set entry price and fund
        mock.setPrice(FEED_ID, int64(strikeRaw), EXPO); // entry = arbitrary
        vm.prank(gambler);
        shop.fundBet{value: stake18}("long", strike18);

        // Settle with price above strike
        vm.warp(expiry);
        mock.setPrice(FEED_ID, int64(settlementRaw), EXPO);

        uint256 gamblerBefore = gambler.balance;
        shop.settle();
        assertEq(gambler.balance, gamblerBefore + stake18 * 2);
    }

    /// Short bet: bookie wins when settlement >= strike.
    function testFuzz_J_shortLoserIsAlwaysBookie(
        uint72 stakeAmount,
        uint64 strikeRaw,
        uint64 settlementRaw
    ) public {
        vm.assume(stakeAmount > 0);
        vm.assume(strikeRaw   > 0);
        vm.assume(settlementRaw >= strikeRaw); // short loses

        _deploy();

        uint256 stake18      = uint256(stakeAmount);
        uint256 strike18     = uint256(strikeRaw)     * 1e10;
        uint256 settlement18 = uint256(settlementRaw) * 1e10;

        vm.deal(bookie,  stake18 * 2);
        vm.deal(gambler, stake18 * 2);

        vm.prank(bookie);
        shop.escrowBookie{value: stake18}();

        mock.setPrice(FEED_ID, int64(strikeRaw), EXPO);
        vm.prank(gambler);
        shop.fundBet{value: stake18}("short", strike18);

        vm.warp(expiry);
        mock.setPrice(FEED_ID, int64(settlementRaw), EXPO);

        uint256 bookieBefore = bookie.balance;
        shop.settle();
        assertEq(bookie.balance, bookieBefore + stake18 * 2);
    }

    /// Full pot is always conserved: winner gets exactly 2× stake.
    function testFuzz_J_potConservation(uint72 stakeAmount) public {
        vm.assume(stakeAmount > 0);

        _deploy();
        uint256 stake18 = uint256(stakeAmount);
        vm.deal(bookie,  stake18 * 2);
        vm.deal(gambler, stake18 * 2);

        uint256 gamblerBefore = gambler.balance;
        uint256 bookieBefore  = bookie.balance;

        vm.prank(bookie);
        shop.escrowBookie{value: stake18}();

        mock.setPrice(FEED_ID, ENTRY_RAW, EXPO);
        vm.prank(gambler);
        shop.fundBet{value: stake18}("long", STRIKE_18);

        vm.warp(expiry);
        mock.setPrice(FEED_ID, ABOVE_STRIKE, EXPO); // long wins

        shop.settle();

        // Total ETH held by both parties is unchanged (just moved)
        uint256 totalAfter = gambler.balance + bookie.balance;
        uint256 totalBefore = gamblerBefore + bookieBefore;
        assertEq(totalAfter, totalBefore);
        assertEq(address(shop).balance, 0);
    }
}
