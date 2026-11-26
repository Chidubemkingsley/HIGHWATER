// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HighwaterLib} from "../src/libraries/HighwaterLib.sol";

contract HighwaterLibTest is Test {
    uint256 constant WAD = 1e18;

    function test_NoFeeWhenUnderperformBenchmark() public pure {
        // strategy 90, bench 100 → no fee
        (uint256 fee, uint256 hwm, uint256 alpha) = HighwaterLib.settleFee({
            strategyNavWad: 90e18,
            benchmarkNavWad: 100e18,
            totalShares: 100e18,
            highWaterMark: WAD,
            performanceFeeBps: 2000
        });
        assertEq(fee, 0);
        assertEq(alpha, 0);
        assertEq(hwm, WAD); // HWM does not fall
    }

    function test_FeeOnAlphaAboveHighWater() public pure {
        // strategy 120, bench 100 → alpha 20; gainAboveHwm 20; fee 20% = 4
        // nav/share = 120/100 = 1.2 > HWM 1.0
        // post-dilution HWM = (120 - 4) / 100 = 1.16
        (uint256 fee, uint256 hwm, uint256 alpha) = HighwaterLib.settleFee({
            strategyNavWad: 120e18,
            benchmarkNavWad: 100e18,
            totalShares: 100e18,
            highWaterMark: WAD,
            performanceFeeBps: 2000
        });
        assertEq(alpha, 20e18);
        assertEq(fee, 4e18);
        assertEq(hwm, 116e16); // 1.16e18 post-dilution
    }

    function test_FeeBillableIsMinAlphaAndGainAboveHwm() public pure {
        // nps = 1.2, HWM = 1.1 → gainAboveHwm = 10; alpha = 50 → billable = 10; fee 20% = 2
        (uint256 fee, uint256 hwm, uint256 alpha) = HighwaterLib.settleFee({
            strategyNavWad: 120e18,
            benchmarkNavWad: 70e18,
            totalShares: 100e18,
            highWaterMark: 11e17,
            performanceFeeBps: 2000
        });
        assertEq(alpha, 50e18);
        assertEq(fee, 2e18);
        // post = (120 - 2) / 100 = 1.18
        assertEq(hwm, 118e16);
    }

    function test_DustFeeDoesNotRatchetHwm() public pure {
        // Tiny alpha vs huge share supply → fee mulDiv floors to 0; HWM must stay put.
        (uint256 fee, uint256 hwm, uint256 alpha) = HighwaterLib.settleFee({
            strategyNavWad: 1e18 + 1,
            benchmarkNavWad: 1e18,
            totalShares: 1e24,
            highWaterMark: 1e12,
            performanceFeeBps: 1
        });
        assertEq(alpha, 1);
        assertEq(fee, 0);
        assertEq(hwm, 1e12);
    }

    function test_PostDilutionHwmNotAboveActualNavPerShare() public pure {
        (uint256 fee, uint256 hwm,) = HighwaterLib.settleFee({
            strategyNavWad: 120e18,
            benchmarkNavWad: 100e18,
            totalShares: 100e18,
            highWaterMark: WAD,
            performanceFeeBps: 2000
        });
        uint256 curatorShares = HighwaterLib.curatorSharesForFee(fee, 120e18, 100e18);
        uint256 postNps = (120e18 * WAD) / (100e18 + curatorShares);
        assertApproxEqAbs(hwm, postNps, 1);
    }

    function test_NoFeeBelowHighWaterEvenWithAlpha() public pure {
        // alpha positive but NAV/share below HWM → no fee
        (uint256 fee, uint256 hwm, uint256 alpha) = HighwaterLib.settleFee({
            strategyNavWad: 110e18,
            benchmarkNavWad: 100e18,
            totalShares: 100e18,
            highWaterMark: 15e17, // HWM at 1.5
            performanceFeeBps: 2000
        });
        assertEq(alpha, 10e18);
        assertEq(fee, 0);
        assertEq(hwm, 15e17);
    }

    function test_CuratorSharesDilution() public pure {
        // fee 4, NAV 120, shares 100 → curator shares = 4*100/(120-4)
        uint256 shares = HighwaterLib.curatorSharesForFee(4e18, 120e18, 100e18);
        uint256 expected = (uint256(4e18) * uint256(100e18)) / uint256(116e18);
        assertEq(shares, expected);
    }

    function test_SharesForDepositFirstAndProRata() public pure {
        assertEq(HighwaterLib.sharesForDeposit(50e18, 0, 0), 50e18);
        assertEq(HighwaterLib.sharesForDeposit(50e18, 100e18, 200e18), 25e18);
    }

    function test_ZeroFeeBps() public pure {
        (uint256 fee,,) = HighwaterLib.settleFee(200e18, 100e18, 100e18, WAD, 0);
        assertEq(fee, 0);
    }
}
