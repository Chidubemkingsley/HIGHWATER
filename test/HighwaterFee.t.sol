// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HighwaterLib} from "../src/libraries/HighwaterLib.sol";
import {NavLib} from "../src/libraries/NavLib.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @dev Focused fee/NAV unit proofs that do not need a live PoolManager.
contract HighwaterFeeMathTest is Test {
    function test_NavValueSymmetricAtOneToOne() public pure {
        // At price 1.0, 100 token0 + 100 token1 → 200 token1 WAD
        uint256 nav = NavLib.valueInNumeraire(100e18, 100e18, Constants.SQRT_PRICE_1_1, true, 18, 18);
        assertEq(nav, 200e18);
    }

    function test_LiquidityForEqualAmounts() public pure {
        uint128 liq = NavLib.liquidityForAmounts(Constants.SQRT_PRICE_1_1, -600, 600, 100e18, 100e18);
        assertGt(liq, 0);
    }

    function test_FullRangeBoundsAligned() public pure {
        (int24 lower, int24 upper,,) = NavLib.fullRangeBounds(60);
        assertEq(lower % 60, 0);
        assertEq(upper % 60, 0);
        assertTrue(lower < upper);
        assertEq(lower, TickMath.minUsableTick(60));
        assertEq(upper, TickMath.maxUsableTick(60));
    }

    function test_FeeNeverExceedsAlpha() public pure {
        (uint256 fee,, uint256 alpha) = HighwaterLib.settleFee(1_000e18, 100e18, 100e18, 1e18, 5_000);
        assertLe(fee, alpha);
        assertEq(fee, alpha / 2); // 50% of alpha
    }

    function test_HighWaterRatchesUp() public pure {
        // fee 10% of billable 100 → 10; post-dilution HWM = (200-10)/100 = 1.9
        (uint256 fee1, uint256 hwm1,) = HighwaterLib.settleFee(200e18, 100e18, 100e18, 1e18, 1000);
        assertEq(fee1, 10e18);
        assertEq(hwm1, 19e17);

        // NAV/share exactly at post-dilution HWM → no further fee
        (uint256 fee2, uint256 hwm2, uint256 alpha2) = HighwaterLib.settleFee(190e18, 90e18, 100e18, hwm1, 1000);
        assertEq(alpha2, 100e18);
        assertEq(fee2, 0);
        assertEq(hwm2, hwm1);
    }
}
