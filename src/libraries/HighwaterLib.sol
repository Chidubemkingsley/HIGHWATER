// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title HighwaterLib
/// @notice Pure settlement math: ex-post performance fee only on alpha above a high-water mark.
/// @dev
/// Strategy NAV and benchmark NAV are both WAD scalars in the same numéraire.
/// Alpha = strategyNav - benchmarkNav.
/// Fee is charged only when:
///   1) alpha > 0 (beat the unmanaged HODL of epoch-start inventory), AND
///   2) strategyNavPerShare > highWaterMark (classic HWM gate).
/// Fee assets are taken from alpha: fee = alpha * feeBps / 10_000.
/// Shares minted to the curator = fee * totalShares / (strategyNav - fee), so dilution
/// equals the fee without touching the PoolManager in the pure path.
library HighwaterLib {
    uint256 internal constant WAD = 1e18;
    uint16 internal constant BPS_DENOM = 10_000;

    /// @notice NAV per share in WAD. First deposit uses 1:1 (nav == shares notionally).
    function navPerShare(uint256 navWad, uint256 totalShares) internal pure returns (uint256) {
        if (totalShares == 0) return WAD;
        return FullMath.mulDiv(navWad, WAD, totalShares);
    }

    /// @notice Shares to mint for a deposit valued at `depositNavWad`.
    function sharesForDeposit(uint256 depositNavWad, uint256 totalShares, uint256 totalNavWad)
        internal
        pure
        returns (uint256 shares)
    {
        if (depositNavWad == 0) return 0;
        if (totalShares == 0 || totalNavWad == 0) return depositNavWad;
        return FullMath.mulDiv(depositNavWad, totalShares, totalNavWad);
    }

    /// @notice Assets (NAV WAD) owed for burning `shares`.
    function navForShares(uint256 shares, uint256 totalShares, uint256 totalNavWad) internal pure returns (uint256) {
        if (shares == 0 || totalShares == 0) return 0;
        return FullMath.mulDiv(shares, totalNavWad, totalShares);
    }

    /// @notice Compute performance fee and updated high-water mark.
    /// @dev Fee base is `min(alpha, NAV above HWM)` so dilution cannot push NAV/share
    ///      below the prior mark (Tokemak/Sherlock HWM class). HWM is set to the
    ///      *post-dilution* NAV/share (`(NAV - fee) / shares`), never pre-fee NPS.
    /// @return feeWad Fee in numéraire WAD (0 if no alpha or below HWM).
    /// @return newHighWaterMark Updated HWM (nav/share WAD, post-dilution).
    /// @return alphaWad Positive alpha for events/telemetry (0 if negative).
    function settleFee(
        uint256 strategyNavWad,
        uint256 benchmarkNavWad,
        uint256 totalShares,
        uint256 highWaterMark,
        uint16 performanceFeeBps
    ) internal pure returns (uint256 feeWad, uint256 newHighWaterMark, uint256 alphaWad) {
        if (totalShares == 0 || performanceFeeBps == 0) {
            return (0, highWaterMark, 0);
        }

        uint256 nps = navPerShare(strategyNavWad, totalShares);
        newHighWaterMark = highWaterMark;

        if (strategyNavWad <= benchmarkNavWad) {
            // Underperformed unmanaged HODL — no fee. HWM does not move down.
            return (0, highWaterMark, 0);
        }

        alphaWad = strategyNavWad - benchmarkNavWad;

        // Classic high-water: no fee until NAV/share makes a new high.
        if (nps <= highWaterMark) {
            return (0, highWaterMark, alphaWad);
        }

        // Only bill the overlap of (beat HODL) and (new high vs HWM).
        uint256 hwmNav = FullMath.mulDiv(highWaterMark, totalShares, WAD);
        uint256 gainAboveHwm = strategyNavWad > hwmNav ? strategyNavWad - hwmNav : 0;
        uint256 billable = alphaWad < gainAboveHwm ? alphaWad : gainAboveHwm;

        feeWad = FullMath.mulDiv(billable, performanceFeeBps, BPS_DENOM);
        // Never take more than billable / strategy NAV; leave ≥1 wei of NAV if possible.
        if (feeWad > billable) feeWad = billable;
        if (feeWad >= strategyNavWad) {
            feeWad = strategyNavWad > 0 ? strategyNavWad - 1 : 0;
        }

        // Dust fee (mulDiv floors to 0): do not ratchet HWM — that would lock LPs out of
        // future fees without the curator paying dilution.
        if (feeWad == 0) {
            return (0, highWaterMark, alphaWad);
        }

        // Post-dilution NPS: equivalent to NAV / (S + curatorShares) after mint.
        uint256 postNps = FullMath.mulDiv(strategyNavWad - feeWad, WAD, totalShares);
        newHighWaterMark = postNps > highWaterMark ? postNps : highWaterMark;
    }

    /// @notice Shares to mint to curator for `feeWad` of NAV, diluting existing holders.
    function curatorSharesForFee(uint256 feeWad, uint256 strategyNavWad, uint256 totalShares)
        internal
        pure
        returns (uint256)
    {
        if (feeWad == 0 || totalShares == 0) return 0;
        if (feeWad >= strategyNavWad) return 0;
        // shares = fee * S / (NAV - fee)
        return FullMath.mulDiv(feeWad, totalShares, strategyNavWad - feeWad);
    }
}
