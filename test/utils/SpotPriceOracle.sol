// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHighwaterOracle} from "../../src/interfaces/IHighwaterOracle.sol";

/// @notice Test-only oracle that returns the current v4 spot price. It deliberately has no
///         manipulation resistance — it exists so settlement math can be exercised locally.
contract SpotPriceOracle is IHighwaterOracle {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    uint160 public fixedPrice;

    constructor(IPoolManager pm) {
        poolManager = pm;
    }

    function setFixedPrice(uint160 priceX96) external {
        fixedPrice = priceX96;
    }

    function getReferenceSqrtPriceX96(PoolKey calldata key) external view returns (uint160 sqrtPriceX96) {
        if (fixedPrice != 0) return fixedPrice;
        (sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
    }
}
