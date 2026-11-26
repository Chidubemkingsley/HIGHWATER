// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {HighwaterLib} from "../src/libraries/HighwaterLib.sol";

/// @notice Property fuzzes for settlement math (fee ≤ billable, HWM monotone, post-dilution).
contract HighwaterLibFuzzTest is Test {
    function testFuzz_feeNeverExceedsAlpha(
        uint256 strategyNav,
        uint256 benchmarkNav,
        uint256 totalShares,
        uint256 highWaterMark,
        uint16 feeBps
    ) public pure {
        strategyNav = bound(strategyNav, 0, 1e30);
        benchmarkNav = bound(benchmarkNav, 0, 1e30);
        totalShares = bound(totalShares, 0, 1e30);
        highWaterMark = bound(highWaterMark, 0, 1e24);
        feeBps = uint16(bound(feeBps, 0, 5_000));

        (uint256 fee,, uint256 alpha) =
            HighwaterLib.settleFee(strategyNav, benchmarkNav, totalShares, highWaterMark, feeBps);

        assertLe(fee, alpha);
        if (strategyNav <= benchmarkNav || feeBps == 0 || totalShares == 0) {
            assertEq(fee, 0);
        }
    }

    function testFuzz_hwmNeverDecreasesOnSettle(
        uint256 strategyNav,
        uint256 benchmarkNav,
        uint256 totalShares,
        uint256 highWaterMark,
        uint16 feeBps
    ) public pure {
        strategyNav = bound(strategyNav, 1, 1e30);
        benchmarkNav = bound(benchmarkNav, 0, 1e30);
        totalShares = bound(totalShares, 1, 1e30);
        highWaterMark = bound(highWaterMark, 0, 1e24);
        feeBps = uint16(bound(feeBps, 0, 5_000));

        (, uint256 newHwm,) =
            HighwaterLib.settleFee(strategyNav, benchmarkNav, totalShares, highWaterMark, feeBps);

        assertGe(newHwm, highWaterMark);
    }

    function testFuzz_curatorSharesZeroWhenFeeZero(uint256 nav, uint256 shares) public pure {
        nav = bound(nav, 1, 1e30);
        shares = bound(shares, 1, 1e30);
        assertEq(HighwaterLib.curatorSharesForFee(0, nav, shares), 0);
    }

    function testFuzz_sharesForDepositProRata(uint256 depositNav, uint256 totalShares, uint256 totalNav)
        public
        pure
    {
        // Keep products inside uint256: max ~1e18 * 1e18 = 1e36.
        depositNav = bound(depositNav, 1, 1e18);
        totalShares = bound(totalShares, 1, 1e18);
        totalNav = bound(totalNav, 1, 1e18);

        uint256 minted = HighwaterLib.sharesForDeposit(depositNav, totalShares, totalNav);
        // Floor division: minted == depositNav * totalShares / totalNav
        assertEq(minted, (depositNav * totalShares) / totalNav);
    }

    function testFuzz_navPerShareConsistent(uint256 nav, uint256 shares) public pure {
        nav = bound(nav, 0, 1e18);
        shares = bound(shares, 0, 1e18);
        uint256 nps = HighwaterLib.navPerShare(nav, shares);
        if (shares == 0) {
            assertEq(nps, HighwaterLib.WAD);
        } else {
            assertEq(nps, (nav * HighwaterLib.WAD) / shares);
        }
    }

    function testFuzz_postDilutionHwmMatchesMint(
        uint256 strategyNav,
        uint256 benchmarkNav,
        uint256 totalShares,
        uint256 highWaterMark,
        uint16 feeBps
    ) public pure {
        // Keep magnitudes realistic so mulDiv floor drift stays tiny.
        strategyNav = bound(strategyNav, 1e18, 1e24);
        benchmarkNav = bound(benchmarkNav, 0, strategyNav);
        totalShares = bound(totalShares, 1e18, 1e24);
        highWaterMark = bound(highWaterMark, 0, 2e18);
        feeBps = uint16(bound(feeBps, 1, 5_000));

        (uint256 fee, uint256 newHwm,) =
            HighwaterLib.settleFee(strategyNav, benchmarkNav, totalShares, highWaterMark, feeBps);

        assertGe(newHwm, highWaterMark);

        // HWM only ratchets on a fee event. Underperformance / below-HWM leaves it unchanged
        // even if raw NAV/share is above the mark.
        if (fee == 0) {
            assertEq(newHwm, highWaterMark);
            return;
        }

        uint256 fromFormula = FullMath.mulDiv(strategyNav - fee, HighwaterLib.WAD, totalShares);
        uint256 expected = fromFormula > highWaterMark ? fromFormula : highWaterMark;
        assertEq(newHwm, expected);

        uint256 curatorShares = HighwaterLib.curatorSharesForFee(fee, strategyNav, totalShares);
        if (curatorShares == 0) return;

        uint256 postNps = FullMath.mulDiv(strategyNav, HighwaterLib.WAD, totalShares + curatorShares);
        assertApproxEqRel(fromFormula, postNps, 0.0001e18); // 1 bp
        assertGe(postNps, highWaterMark);
    }
}
