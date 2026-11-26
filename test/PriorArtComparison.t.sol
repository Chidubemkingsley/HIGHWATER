// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PriorArtFeeModels} from "../src/comparators/PriorArtFeeModels.sol";

/// @notice Same-tape fee comparison: AUM skim vs HWM-only vs HIGHWATER.
/// @dev Reproducible scoreboard — run: forge test --match-contract PriorArtComparison -vv
contract PriorArtComparisonTest is Test {
    uint256 constant WAD = 1e18;
    uint16 constant PERF_BPS = 2000; // 20% of billable alpha / gain
    uint16 constant AUM_BPS = 200; // 2% of NAV per epoch (aggressive to make skim visible)

    function test_Scoreboard_UnderperformHODL() public pure {
        // Strategy flat / below HODL bench — managing did not create alpha.
        uint256 strategy = 100e18;
        uint256 bench = 110e18;
        uint256 shares = 100e18;
        uint256 hwm = WAD;

        uint256 aum = PriorArtFeeModels.aumSkimFee(strategy, AUM_BPS);
        (uint256 hwmOnly,) = PriorArtFeeModels.hwmOnlyFee(strategy, shares, hwm, PERF_BPS);
        (uint256 hw,, uint256 alpha) =
            PriorArtFeeModels.highwaterFee(strategy, bench, shares, hwm, PERF_BPS);

        assertEq(alpha, 0);
        assertEq(hw, 0, "HIGHWATER must pay 0 when under HODL");
        assertGt(aum, 0, "AUM skim still charges on underperformance");
        // nps = 1.0 == hwm → HWM-only also 0 here
        assertEq(hwmOnly, 0);

        _logRow("underperform HODL", aum, hwmOnly, hw);
    }

    function test_Scoreboard_FlatNoAlpha_AumStillPays() public pure {
        // Strategy == bench, nps flat at HWM — pure "managed but no edge".
        uint256 strategy = 100e18;
        uint256 bench = 100e18;
        uint256 shares = 100e18;
        uint256 hwm = WAD;

        uint256 aum = PriorArtFeeModels.aumSkimFee(strategy, AUM_BPS);
        (uint256 hwmOnly,) = PriorArtFeeModels.hwmOnlyFee(strategy, shares, hwm, PERF_BPS);
        (uint256 hw,,) = PriorArtFeeModels.highwaterFee(strategy, bench, shares, hwm, PERF_BPS);

        assertEq(hw, 0);
        assertEq(hwmOnly, 0);
        assertEq(aum, 2e18); // 2% of 100

        _logRow("flat / no alpha", aum, hwmOnly, hw);
    }

    function test_Scoreboard_BeatHODLAndHWM() public pure {
        // Clear outperformance: strategy 120, bench 100, nps 1.2 > HWM 1.0
        uint256 strategy = 120e18;
        uint256 bench = 100e18;
        uint256 shares = 100e18;
        uint256 hwm = WAD;

        uint256 aum = PriorArtFeeModels.aumSkimFee(strategy, AUM_BPS);
        (uint256 hwmOnly,) = PriorArtFeeModels.hwmOnlyFee(strategy, shares, hwm, PERF_BPS);
        (uint256 hw,, uint256 alpha) =
            PriorArtFeeModels.highwaterFee(strategy, bench, shares, hwm, PERF_BPS);

        assertEq(alpha, 20e18);
        assertEq(hw, 4e18); // 20% of min(20, 20)
        assertGt(hwmOnly, 0);
        assertGt(aum, 0);
        assertLe(hw, alpha);

        _logRow("beat HODL + HWM", aum, hwmOnly, hw);
    }

    function test_Scoreboard_PriceUpButNoAlpha_HwmOnlyChargesHighwaterDoesNot() public pure {
        // Inventory HODL also marked up with price — strategy == bench, but nps rose
        // via share-count quirk: fewer shares than NAV (e.g. after donations / dead).
        // HWM-only sees a new high; HIGHWATER sees alpha = 0.
        uint256 strategy = 150e18;
        uint256 bench = 150e18; // HODL matched the mark-up
        uint256 shares = 100e18; // nps = 1.5 > HWM 1.0
        uint256 hwm = WAD;

        uint256 aum = PriorArtFeeModels.aumSkimFee(strategy, AUM_BPS);
        (uint256 hwmOnly,) = PriorArtFeeModels.hwmOnlyFee(strategy, shares, hwm, PERF_BPS);
        (uint256 hw,, uint256 alpha) =
            PriorArtFeeModels.highwaterFee(strategy, bench, shares, hwm, PERF_BPS);

        assertEq(alpha, 0);
        assertEq(hw, 0, "no HODL alpha => HIGHWATER fee 0");
        assertGt(hwmOnly, 0, "HWM-only still fees on share-price rise");
        assertGt(aum, 0);

        _logRow("price up, matched HODL", aum, hwmOnly, hw);
    }

    function test_Scoreboard_SecondEpochBlockedByHWM() public pure {
        // After a fee event, HWM sits at post-dilution. Same NAV again → HIGHWATER 0.
        uint256 strategy = 120e18;
        uint256 bench = 100e18;
        uint256 shares = 100e18;

        (uint256 fee1, uint256 hwm1,) =
            PriorArtFeeModels.highwaterFee(strategy, bench, shares, WAD, PERF_BPS);
        assertGt(fee1, 0);

        // Next epoch: bench resnapshotted to ~strategy, mild leftover alpha vs old tape
        // but nps at/below post-dilution HWM.
        uint256 strategy2 = 116e18; // equals post-dilution mark from fee1=4
        uint256 bench2 = 100e18;
        (uint256 fee2,,) = PriorArtFeeModels.highwaterFee(strategy2, bench2, shares, hwm1, PERF_BPS);
        assertEq(fee2, 0, "HWM blocks repeat fee without new high");

        uint256 aum2 = PriorArtFeeModels.aumSkimFee(strategy2, AUM_BPS);
        assertGt(aum2, 0);

        _logRow("2nd epoch @ HWM", aum2, 0, fee2);
    }

    function test_PrintedTable_ForJudges() public view {
        console2.log("=== HIGHWATER prior-art fee tape (same inputs) ===");
        console2.log("cols: scenario | AUM(2%) | HWM-only(20%) | HIGHWATER(20% alpha)");
        _scenarioLog("underperform", 100e18, 110e18, 100e18, WAD);
        _scenarioLog("flat", 100e18, 100e18, 100e18, WAD);
        _scenarioLog("beat both", 120e18, 100e18, 100e18, WAD);
        _scenarioLog("matched HODL nps up", 150e18, 150e18, 100e18, WAD);
    }

    function _scenarioLog(
        string memory name,
        uint256 strategy,
        uint256 bench,
        uint256 shares,
        uint256 hwm
    ) internal pure {
        uint256 aum = PriorArtFeeModels.aumSkimFee(strategy, AUM_BPS);
        (uint256 hwmOnly,) = PriorArtFeeModels.hwmOnlyFee(strategy, shares, hwm, PERF_BPS);
        (uint256 hw,,) = PriorArtFeeModels.highwaterFee(strategy, bench, shares, hwm, PERF_BPS);
        _logRow(name, aum, hwmOnly, hw);
    }

    function _logRow(string memory name, uint256 aum, uint256 hwmOnly, uint256 hw) internal pure {
        console2.log(name);
        console2.log("  AUM     ", aum);
        console2.log("  HWM-only", hwmOnly);
        console2.log("  HIGHWATER", hw);
    }
}
