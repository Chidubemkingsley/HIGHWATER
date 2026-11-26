// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {HighwaterLib} from "../libraries/HighwaterLib.sol";

/// @title PriorArtFeeModels
/// @notice Pure fee models for same-tape comparison against HIGHWATER.
/// @dev These are intentionally simplified stand-ins for common curation/vault fee
///      designs — not full protocol ports. Used only in PriorArtComparison tests.
library PriorArtFeeModels {
    uint256 internal constant WAD = 1e18;
    uint16 internal constant BPS_DENOM = 10_000;

    /// @notice Continuous AUM skim: fee = NAV * bps / 10_000, paid every epoch
    ///         regardless of alpha or high-water. Managing alone always pays.
    function aumSkimFee(uint256 strategyNavWad, uint16 aumBps) internal pure returns (uint256 feeWad) {
        if (strategyNavWad == 0 || aumBps == 0) return 0;
        feeWad = FullMath.mulDiv(strategyNavWad, aumBps, BPS_DENOM);
        if (feeWad >= strategyNavWad) feeWad = strategyNavWad > 0 ? strategyNavWad - 1 : 0;
    }

    /// @notice Share-price HWM only (no HODL benchmark). Fees on NAV/share gains
    ///         above the mark even if the strategy underperformed a frozen inventory HODL.
    function hwmOnlyFee(
        uint256 strategyNavWad,
        uint256 totalShares,
        uint256 highWaterMark,
        uint16 performanceFeeBps
    ) internal pure returns (uint256 feeWad, uint256 newHighWaterMark) {
        if (totalShares == 0 || performanceFeeBps == 0) {
            return (0, highWaterMark);
        }
        uint256 nps = HighwaterLib.navPerShare(strategyNavWad, totalShares);
        newHighWaterMark = highWaterMark;
        if (nps <= highWaterMark) return (0, highWaterMark);

        uint256 gain = strategyNavWad - FullMath.mulDiv(highWaterMark, totalShares, WAD);
        feeWad = FullMath.mulDiv(gain, performanceFeeBps, BPS_DENOM);
        if (feeWad >= strategyNavWad) feeWad = strategyNavWad > 0 ? strategyNavWad - 1 : 0;
        if (feeWad == 0) return (0, highWaterMark);

        uint256 postNps = FullMath.mulDiv(strategyNavWad - feeWad, WAD, totalShares);
        newHighWaterMark = postNps > highWaterMark ? postNps : highWaterMark;
    }

    /// @notice HIGHWATER settle (ex-post alpha vs HODL + HWM). Thin wrapper for tables.
    function highwaterFee(
        uint256 strategyNavWad,
        uint256 benchmarkNavWad,
        uint256 totalShares,
        uint256 highWaterMark,
        uint16 performanceFeeBps
    ) internal pure returns (uint256 feeWad, uint256 newHighWaterMark, uint256 alphaWad) {
        return HighwaterLib.settleFee(strategyNavWad, benchmarkNavWad, totalShares, highWaterMark, performanceFeeBps);
    }
}
