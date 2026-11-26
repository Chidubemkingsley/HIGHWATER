// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {HighwaterHook} from "../src/HighwaterHook.sol";

/// @notice Mines a CREATE2 salt for HIGHWATER permissions and deploys the hook.
contract DeployHighwaterScript is BaseScript {
    function run() public {
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        address owner_ = getDeployer();
        address curator_ = vm.envOr("CURATOR", owner_);
        uint32 epochDuration = uint32(vm.envOr("EPOCH_DURATION", uint256(1 days)));
        uint16 feeBps = uint16(vm.envOr("PERFORMANCE_FEE_BPS", uint256(2000)));
        bool numeraireIsToken1 = vm.envOr("NUMERAIRE_IS_TOKEN1", true);

        bytes memory constructorArgs =
            abi.encode(poolManager, owner_, curator_, epochDuration, feeBps, numeraireIsToken1);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(HighwaterHook).creationCode, constructorArgs);

        vm.startBroadcast();
        HighwaterHook hook = new HighwaterHook{salt: salt}(
            poolManager, owner_, curator_, epochDuration, feeBps, numeraireIsToken1
        );
        vm.stopBroadcast();

        require(address(hook) == hookAddress, "DeployHighwater: Hook Address Mismatch");
    }
}
