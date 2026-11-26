// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title Highwater oracle adapter
/// @notice A manipulation-resistant price source for settlement. v4 has no built-in oracle;
///         integrators should wire a two-source adapter (push feed verified by a deep v3 TWAP),
///         mirroring the pattern used by production v4 LP-native protocols.
interface IHighwaterOracle {
    /// @notice Reference price in sqrtPriceX96 (Q64.96) for the given pool.
    /// @dev Must revert or return 0 when the reference cannot be trusted.
    function getReferenceSqrtPriceX96(PoolKey calldata key) external view returns (uint160 sqrtPriceX96);
}
