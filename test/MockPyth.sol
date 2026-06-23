// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Re-use the structs declared in BucketShop.sol
import "../src/BucketShop.sol";

/**
 * @title MockPyth
 * @notice Minimal Pyth oracle mock for Foundry tests.
 *
 *  - Set an arbitrary price with `setPrice(feedId, price, expo)`.
 *  - Staleness is controlled by `setPublishTime(feedId, t)` or defaults to
 *    block.timestamp so it is always fresh unless you deliberately age it.
 *  - `getUpdateFee` always returns 1 wei; `updatePriceFeeds` is a no-op
 *    (the test controls prices directly).
 */
contract MockPyth is IPyth {

    struct Feed {
        int64  price;
        uint64 conf;
        int32  expo;
        uint   publishTime;
        bool   exists;
    }

    mapping(bytes32 => Feed) private feeds;

    // -----------------------------------------------------------------------
    // Test helpers
    // -----------------------------------------------------------------------

    function setPrice(bytes32 id, int64 price, int32 expo) external {
        feeds[id] = Feed({
            price:       price,
            conf:        0,
            expo:        expo,
            publishTime: block.timestamp,
            exists:      true
        });
    }

    function setPriceWithTime(
        bytes32 id,
        int64   price,
        int32   expo,
        uint    publishTime
    ) external {
        feeds[id] = Feed({
            price:       price,
            conf:        0,
            expo:        expo,
            publishTime: publishTime,
            exists:      true
        });
    }

    // -----------------------------------------------------------------------
    // IPyth implementation
    // -----------------------------------------------------------------------

    function getPriceNoOlderThan(
        bytes32 id,
        uint    age
    ) external view override returns (PythPrice memory) {
        Feed memory f = feeds[id];
        require(f.exists, "MockPyth: unknown feed");
        require(
            block.timestamp - f.publishTime <= age,
            "MockPyth: price too stale"
        );
        return PythPrice({
            price:       f.price,
            conf:        f.conf,
            expo:        f.expo,
            publishTime: f.publishTime
        });
    }

    function getUpdateFee(
        bytes[] calldata /*updateData*/
    ) external pure override returns (uint) {
        return 1 wei;
    }

    function updatePriceFeeds(
        bytes[] calldata /*updateData*/
    ) external payable override {
        // no-op in tests — price is set directly via setPrice()
    }
}
