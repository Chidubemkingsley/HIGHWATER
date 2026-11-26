// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

/// @notice Smoke-check canonical v4 PoolManager on a mainnet fork (Base by default).
/// @dev Skips when BASE_RPC_URL (or FORK_RPC_URL) is unset — local CI stays green offline.
///      Run: BASE_RPC_URL=$RPC forge test --match-contract HighwaterForkSmoke -vv
contract HighwaterForkSmokeTest is Test {
    function test_CanonicalPoolManager_HasCode_OnBaseFork() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            rpc = vm.envOr("FORK_RPC_URL", string(""));
        }
        if (bytes(rpc).length == 0) {
            console2.log("SKIP: set BASE_RPC_URL or FORK_RPC_URL to run fork smoke");
            return;
        }

        vm.createSelectFork(rpc);

        address pm = AddressConstants.getPoolManagerAddress(8453); // Base
        uint256 codeLen = pm.code.length;
        console2.log("Base PoolManager", pm);
        console2.log("code length", codeLen);
        assertGt(codeLen, 0, "canonical Base PoolManager missing code on fork");
    }
}
