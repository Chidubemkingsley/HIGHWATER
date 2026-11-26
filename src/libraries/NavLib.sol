// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "./LiquidityAmounts.sol";

/// @title NavLib
/// @notice Oracle-free mark-to-market helpers using the pool's own `sqrtPriceX96`.
/// @dev Valuation floors (FullMath.mulDiv) — safe direction for fee accounting.
library NavLib {
    uint256 internal constant WAD = 1e18;

    /// @notice Tick-spacing-aligned full-range bounds and their sqrt prices.
    function fullRangeBounds(int24 tickSpacing)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper, uint160 sqrtLowerX96, uint160 sqrtUpperX96)
    {
        tickLower = TickMath.minUsableTick(tickSpacing);
        tickUpper = TickMath.maxUsableTick(tickSpacing);
        sqrtLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        sqrtUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);
    }

    /// @notice Token amounts for `liquidity` over `[sqrtLower, sqrtUpper]` at `sqrtPriceX96`.
    function getPositionTokenAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        return LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, liquidity);
    }

    /// @notice Value (amount0, amount1) as a WAD scalar in the numéraire token.
    /// @param numeraireIsToken1 True if token1 is the unit of account (default for ETH/USDC-style pools).
    function valueInNumeraire(
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPriceX96,
        bool numeraireIsToken1,
        uint8 decimals0,
        uint8 decimals1
    ) internal pure returns (uint256 valueWad) {
        if (sqrtPriceX96 == 0) return 0;
        if (amount0 == 0 && amount1 == 0) return 0;

        if (numeraireIsToken1) {
            // amount0 · (sqrtP / Q96)² → token1 raw units
            uint256 value0In1 = FullMath.mulDiv(
                FullMath.mulDiv(amount0, sqrtPriceX96, FixedPoint96.Q96), sqrtPriceX96, FixedPoint96.Q96
            );
            valueWad = toWad(value0In1 + amount1, decimals1);
        } else {
            uint256 value1In0 = FullMath.mulDiv(
                FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtPriceX96), FixedPoint96.Q96, sqrtPriceX96
            );
            valueWad = toWad(amount0 + value1In0, decimals0);
        }

        // Extreme prices can floor a nonzero inventory to 0 via mulDiv. Keep a 1-wei
        // WAD floor so shares still mark a claim (avoids "live shares, zero NAV").
        if (valueWad == 0) return 1;
    }

    function toWad(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        if (decimals < 18) return amount * (10 ** (18 - decimals));
        return amount / (10 ** (decimals - 18));
    }

    /// @notice Liquidity for desired amounts at the current price and tick range.
    function liquidityForAmounts(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal pure returns (uint128 liquidity) {
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Desired,
            amount1Desired
        );
    }
}
