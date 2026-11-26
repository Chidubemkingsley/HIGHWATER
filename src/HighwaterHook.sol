// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

import {NavLib} from "./libraries/NavLib.sol";
import {HighwaterLib} from "./libraries/HighwaterLib.sol";

/// @title HIGHWATER
/// @notice Curated Uniswap v4 liquidity vault where the curator earns a performance fee
///         only after beating an unmanaged HODL benchmark — settled ex-post each epoch.
/// @dev UHI11: Active Management & Curation.
///      - Hook owns the single shared position (external modifyLiquidity gated).
///      - Depositors hold ERC-20 vault shares and follow the curator.
///      - Curator rebalances the active tick range.
///      - `settleEpoch` compares strategy NAV vs HODL of epoch-start inventory (oracle-free)
///        and mints fee shares to the curator only on alpha above the high-water mark.
contract HighwaterHook is BaseHook, ERC20, IUnlockCallback, ReentrancyGuardTransient {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // Constants / config
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Shared position salt — one hook-owned range for all depositors.
    bytes32 public constant POSITION_SALT = keccak256("HIGHWATER_POSITION_V1");

    /// @dev Dead shares burned on first deposit (inflation guard).
    uint256 public constant DEAD_SHARES = 1_000;

    /// @dev Default epoch length (1 day). Configurable per deployment via constructor.
    uint32 public immutable epochDuration;

    /// @dev Performance fee in bps of positive alpha (e.g. 2000 = 20%).
    uint16 public immutable performanceFeeBps;

    /// @dev Max performance fee (50%).
    uint16 public constant MAX_FEE_BPS = 5_000;

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error AlreadyInitialized();
    error PoolNotBound();
    error WrongPool();
    error OnlyCurator();
    error OnlyOwner();
    error OnlyCuratorOrKeeper();
    error LiquidityOnlyViaHook();
    error ZeroAmount();
    error ZeroLiquidity();
    error ZeroShares();
    error InvalidTicks();
    error EpochNotElapsed();
    error Slippage();
    error InvalidFee();
    error InvalidCurator();
    error InsufficientShares();
    error InvalidEpochDuration();
    error KeeperTickInRange();
    error UnsupportedCurrency();

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event CuratorUpdated(address indexed oldCurator, address indexed newCurator);
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event OwnerUpdated(address indexed oldOwner, address indexed newOwner);
    event Deposited(address indexed user, uint256 shares, uint256 amount0, uint256 amount1, uint256 navWad);
    event Withdrawn(address indexed user, uint256 shares, uint256 amount0, uint256 amount1, uint256 navWad);
    event Rebalanced(address indexed curator, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event EpochSettled(
        uint256 indexed epochId,
        uint256 strategyNavWad,
        uint256 benchmarkNavWad,
        uint256 alphaWad,
        uint256 feeWad,
        uint256 curatorShares,
        uint256 highWaterMark
    );
    event StrategyMigrated(address indexed oldCurator, address indexed newCurator, int24 tickLower, int24 tickUpper);

    // ─────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────

    address public owner;
    address public curator;
    /// @dev Optional keeper address (may be zero = disabled). Can trigger rebalance
    ///      only when the current pool tick has drifted outside the active range.
    address public keeper;

    PoolKey private _poolKey;
    PoolId public boundId;
    bool public bound;

    int24 public tickLower;
    int24 public tickUpper;

    uint8 public decimals0;
    uint8 public decimals1;
    bool public numeraireIsToken1;

    uint256 public epochId;
    uint256 public epochStartTimestamp;
    uint256 public highWaterMark; // NAV per share WAD

    /// @dev HODL benchmark inventory snapshotted at epoch open (raw token units).
    uint256 public benchAmount0;
    uint256 public benchAmount1;

    // Unlock callback ops
    uint8 private constant OP_DEPOSIT = 1;
    uint8 private constant OP_WITHDRAW = 2;
    uint8 private constant OP_REBALANCE = 3;
    uint8 private constant OP_POKE = 4; // liquidityDelta=0 → realize fees into hook idle

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyCurator() {
        if (msg.sender != curator) revert OnlyCurator();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /// @param _poolManager Uniswap v4 PoolManager.
    /// @param _owner Admin who can migrate curator / transfer ownership.
    /// @param _curator Initial strategy curator (directs rebalances).
    /// @param _epochDuration Seconds per settlement epoch.
    /// @param _performanceFeeBps Fee on positive alpha, in bps (max 5000).
    /// @param _numeraireIsToken1 If true, NAV is quoted in token1.
    constructor(
        IPoolManager _poolManager,
        address _owner,
        address _curator,
        uint32 _epochDuration,
        uint16 _performanceFeeBps,
        bool _numeraireIsToken1
    ) BaseHook(_poolManager) ERC20("HIGHWATER Vault Share", "HWTR") {
        if (_owner == address(0) || _curator == address(0)) revert InvalidCurator();
        if (_performanceFeeBps > MAX_FEE_BPS) revert InvalidFee();
        if (_epochDuration == 0) revert InvalidEpochDuration();

        owner = _owner;
        curator = _curator;
        epochDuration = _epochDuration;
        performanceFeeBps = _performanceFeeBps;
        numeraireIsToken1 = _numeraireIsToken1;
        highWaterMark = HighwaterLib.WAD; // start at 1.0 NAV/share
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Hook permissions
    // ─────────────────────────────────────────────────────────────────────────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, // bind single pool + seed epoch
            beforeAddLiquidity: true, // gate external LPs
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true, // gate external removes
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        if (bound) revert AlreadyInitialized();

        _poolKey = key;
        boundId = key.toId();
        bound = true;

        // Default to full-range until curator rebalances.
        (tickLower, tickUpper,,) = NavLib.fullRangeBounds(key.tickSpacing);

        decimals0 = _currencyDecimals(key.currency0);
        decimals1 = _currencyDecimals(key.currency1);

        epochId = 0;
        epochStartTimestamp = block.timestamp;
        // Bench starts empty until first deposit snapshots inventory.

        return BaseHook.afterInitialize.selector;
    }

    function _beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        _requireBoundPool(key);
        // Only the hook itself may modify liquidity (via unlock).
        if (sender != address(this)) revert LiquidityOnlyViaHook();
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        _requireBoundPool(key);
        if (sender != address(this)) revert LiquidityOnlyViaHook();
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────

    function poolKey() public view returns (PoolKey memory) {
        return _poolKey;
    }

    /// @notice Current strategy NAV in numéraire WAD (position + idle ERC-20 balances).
    function strategyNav() public view returns (uint256 navWad) {
        if (!bound) return 0;
        (uint256 amount0, uint256 amount1) = _inventory();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(boundId);
        return NavLib.valueInNumeraire(amount0, amount1, sqrtPriceX96, numeraireIsToken1, decimals0, decimals1);
    }

    /// @notice Unmanaged HODL benchmark NAV: epoch-start inventory marked at current pool price.
    function benchmarkNav() public view returns (uint256 navWad) {
        if (!bound) return 0;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(boundId);
        return
            NavLib.valueInNumeraire(benchAmount0, benchAmount1, sqrtPriceX96, numeraireIsToken1, decimals0, decimals1);
    }

    /// @notice Preview settle without state changes.
    function previewSettle()
        external
        view
        returns (
            uint256 strategyNavWad,
            uint256 benchmarkNavWad,
            uint256 alphaWad,
            uint256 feeWad,
            uint256 curatorShares
        )
    {
        strategyNavWad = strategyNav();
        benchmarkNavWad = benchmarkNav();
        (feeWad,, alphaWad) =
            HighwaterLib.settleFee(strategyNavWad, benchmarkNavWad, totalSupply(), highWaterMark, performanceFeeBps);
        curatorShares = HighwaterLib.curatorSharesForFee(feeWad, strategyNavWad, totalSupply());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Deposit / withdraw
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deposit tokens and mint vault shares. Assets go into the active curated range.
    function deposit(uint256 amount0Max, uint256 amount1Max, uint256 minShares)
        external
        nonReentrant
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        if (!bound) revert PoolNotBound();
        if (amount0Max == 0 && amount1Max == 0) revert ZeroAmount();

        uint256 navBefore = strategyNav();

        bytes memory result = poolManager.unlock(
            abi.encode(OP_DEPOSIT, msg.sender, amount0Max, amount1Max, tickLower, tickUpper, uint128(0))
        );
        (amount0, amount1) = abi.decode(result, (uint256, uint256));

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(boundId);
        uint256 depositNav =
            NavLib.valueInNumeraire(amount0, amount1, sqrtPriceX96, numeraireIsToken1, decimals0, decimals1);
        if (depositNav == 0) revert ZeroLiquidity();

        shares = HighwaterLib.sharesForDeposit(depositNav, totalSupply(), navBefore);
        if (shares < minShares) revert Slippage();
        if (shares == 0) revert ZeroShares();

        // First depositor: burn dead shares to the zero address's sibling (0xdead).
        if (totalSupply() == 0) {
            if (shares <= DEAD_SHARES) revert ZeroShares();
            _mint(address(0xdead), DEAD_SHARES);
            shares -= DEAD_SHARES;
        }

        _mint(msg.sender, shares);

        // If this is the first capital of the epoch (bench empty), open the HODL snapshot.
        if (benchAmount0 == 0 && benchAmount1 == 0) {
            _snapshotBenchmark();
        }

        emit Deposited(msg.sender, shares, amount0, amount1, depositNav);
    }

    /// @notice Burn shares and withdraw a pro-rata slice of the curated position.
    function withdraw(uint256 shares, uint256 minAmount0, uint256 minAmount1)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (!bound) revert PoolNotBound();
        if (shares == 0) revert ZeroShares();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();

        uint128 liq = _positionLiquidity();
        uint256 supply = totalSupply();
        uint128 liqToRemove = uint128((uint256(liq) * shares) / supply);

        // Never empty the position while other shares (incl. dead) still claim it —
        // floor division can otherwise zero liquidity and leave live shares with NAV=0.
        if (shares < supply && liqToRemove > 0 && liqToRemove >= liq) {
            liqToRemove = liq - 1;
        }

        _burn(msg.sender, shares);

        // Remove principal to user; ALL accrued fees go to the hook idle first,
        // then the user receives a pro-rata slice of idle (fees shared fairly).
        // Dust shares (liqToRemove rounds to 0) still poke so fee idle is claimable.
        if (liqToRemove > 0) {
            bytes memory result = poolManager.unlock(
                abi.encode(OP_WITHDRAW, msg.sender, uint256(0), uint256(0), tickLower, tickUpper, liqToRemove)
            );
            (amount0, amount1) = abi.decode(result, (uint256, uint256));
        } else if (liq > 0) {
            poolManager.unlock(
                abi.encode(OP_POKE, msg.sender, uint256(0), uint256(0), tickLower, tickUpper, uint128(0))
            );
        }

        amount0 += _payoutIdle(msg.sender, _poolKey.currency0, shares, supply);
        amount1 += _payoutIdle(msg.sender, _poolKey.currency1, shares, supply);

        // Remaining shareholders (incl. dead / curator) must retain positive NAV.
        // Floor rounding on tiny positions can otherwise leave shares claiming nothing.
        if (totalSupply() > 0 && strategyNav() == 0) revert ZeroLiquidity();

        if (amount0 < minAmount0 || amount1 < minAmount1) revert Slippage();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(boundId);
        uint256 navOut =
            NavLib.valueInNumeraire(amount0, amount1, sqrtPriceX96, numeraireIsToken1, decimals0, decimals1);

        emit Withdrawn(msg.sender, shares, amount0, amount1, navOut);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Curation: rebalance / migrate / settle
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Curator moves the active range. Inventory is withdrawn from the old range
    ///         and redeposited into `[newLower, newUpper]`.
    function rebalance(int24 newLower, int24 newUpper) external onlyCurator nonReentrant {
        if (!bound) revert PoolNotBound();
        _validateTicks(newLower, newUpper);

        uint128 liq = _positionLiquidity();
        if (liq > 0) {
            poolManager.unlock(abi.encode(OP_REBALANCE, msg.sender, uint256(0), uint256(0), newLower, newUpper, liq));
        } else {
            tickLower = newLower;
            tickUpper = newUpper;
        }

        emit Rebalanced(msg.sender, tickLower, tickUpper, _positionLiquidity());
    }

    /// @notice Keeper-triggered rebalance. Only callable when the current pool tick has
    ///         drifted outside [tickLower, tickUpper]. The new range is supplied by the
    ///         caller (typically computed off-chain or by HighwaterKeeper) but must pass
    ///         the same tick validation as a curator rebalance.
    /// @dev Separates *who decides the range* (curator, any time) from
    ///      *automatic execution* (keeper, only when price leaves the active range).
    function keeperRebalance(int24 newLower, int24 newUpper) external nonReentrant {
        if (msg.sender != keeper) revert OnlyCuratorOrKeeper();
        if (!bound) revert PoolNotBound();

        (, int24 currentTick,,) = poolManager.getSlot0(boundId);
        if (currentTick >= tickLower && currentTick <= tickUpper) revert KeeperTickInRange();

        _validateTicks(newLower, newUpper);

        // S3 fix: the new range must actually cover the current tick.
        // Without this, a compromised keeper could move the range to a tick-free zone,
        // leaving depositor inventory permanently out of range and earning no fees.
        if (currentTick < newLower || currentTick > newUpper) revert InvalidTicks();

        uint128 liq = _positionLiquidity();
        if (liq > 0) {
            poolManager.unlock(abi.encode(OP_REBALANCE, msg.sender, uint256(0), uint256(0), newLower, newUpper, liq));
        } else {
            tickLower = newLower;
            tickUpper = newUpper;
        }

        emit Rebalanced(msg.sender, tickLower, tickUpper, _positionLiquidity());
    }

    /// @notice Owner migrates curation rights (and optionally the active range) to a new curator.
    function migrateStrategy(address newCurator, int24 newLower, int24 newUpper, bool doRebalance)
        external
        onlyOwner
        nonReentrant
    {
        if (newCurator == address(0)) revert InvalidCurator();
        address old = curator;
        curator = newCurator;
        emit CuratorUpdated(old, newCurator);

        if (doRebalance) {
            _validateTicks(newLower, newUpper);
            uint128 liq = _positionLiquidity();
            if (liq > 0) {
                // Temporarily allow unlock path; curator check is bypassed because owner drives migration.
                poolManager.unlock(
                    abi.encode(OP_REBALANCE, newCurator, uint256(0), uint256(0), newLower, newUpper, liq)
                );
            } else {
                tickLower = newLower;
                tickUpper = newUpper;
            }
            // S2 fix: refresh the HODL benchmark to reflect the post-migration inventory
            // composition. Without this, the next epoch compares strategy NAV against the
            // old range's snapshot, attributing the forced composition shift as alpha.
            _snapshotBenchmark();
        }

        emit StrategyMigrated(old, newCurator, tickLower, tickUpper);
    }

    /// @notice Permissionless epoch settlement.
    /// @dev Compares strategy NAV to HODL of epoch-start inventory. Mints fee shares to curator
    ///      only on positive alpha above the high-water mark. Then opens the next epoch snapshot.
    function settleEpoch() external nonReentrant returns (uint256 feeWad, uint256 curatorShares) {
        if (!bound) revert PoolNotBound();
        if (block.timestamp < epochStartTimestamp + epochDuration) revert EpochNotElapsed();

        // Realize uncollected fees into idle so NAV and the next HODL snapshot agree.
        if (_positionLiquidity() > 0) {
            poolManager.unlock(
                abi.encode(OP_POKE, address(this), uint256(0), uint256(0), tickLower, tickUpper, uint128(0))
            );
        }

        uint256 strategyNavWad = strategyNav();
        uint256 benchmarkNavWad = benchmarkNav();
        uint256 supply = totalSupply();

        uint256 alphaWad;
        uint256 newHwm;
        (feeWad, newHwm, alphaWad) =
            HighwaterLib.settleFee(strategyNavWad, benchmarkNavWad, supply, highWaterMark, performanceFeeBps);

        curatorShares = HighwaterLib.curatorSharesForFee(feeWad, strategyNavWad, supply);
        if (curatorShares > 0) {
            _mint(curator, curatorShares);
        }
        highWaterMark = newHwm;

        emit EpochSettled(epochId, strategyNavWad, benchmarkNavWad, alphaWad, feeWad, curatorShares, highWaterMark);

        // Roll epoch + refresh HODL snapshot to current inventory.
        unchecked {
            epochId += 1;
        }
        epochStartTimestamp = block.timestamp;
        _snapshotBenchmark();
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert OnlyOwner();
        address old = owner;
        owner = newOwner;
        emit OwnerUpdated(old, newOwner);
    }

    function setCurator(address newCurator) external onlyOwner {
        if (newCurator == address(0)) revert InvalidCurator();
        address old = curator;
        curator = newCurator;
        emit CuratorUpdated(old, newCurator);
    }

    /// @notice Owner sets (or clears) the keeper address. Pass address(0) to disable.
    /// @dev The keeper may only call `keeperRebalance`, and only when the tick is out of range.
    function setKeeper(address newKeeper) external onlyOwner {
        address old = keeper;
        keeper = newKeeper;
        emit KeeperUpdated(old, newKeeper);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Unlock callback
    // ─────────────────────────────────────────────────────────────────────────

    function unlockCallback(bytes calldata rawData) external override onlyPoolManager returns (bytes memory) {
        (uint8 op, address user, uint256 amount0Max, uint256 amount1Max, int24 tLower, int24 tUpper, uint128 liqArg) =
            abi.decode(rawData, (uint8, address, uint256, uint256, int24, int24, uint128));

        PoolKey memory key = _poolKey;

        if (op == OP_DEPOSIT) {
            (uint256 used0, uint256 used1) = _unlockDeposit(key, user, amount0Max, amount1Max, tLower, tUpper);
            return abi.encode(used0, used1);
        }
        if (op == OP_WITHDRAW) {
            (uint256 out0, uint256 out1) = _unlockWithdraw(key, user, tLower, tUpper, liqArg);
            return abi.encode(out0, out1);
        }
        if (op == OP_REBALANCE) {
            _unlockRebalance(key, tLower, tUpper, liqArg);
            return abi.encode(uint256(0), uint256(0));
        }
        if (op == OP_POKE) {
            _unlockPoke(key, tLower, tUpper);
            return abi.encode(uint256(0), uint256(0));
        }
        revert HookNotImplemented();
    }

    /// @dev v4 returns callerDelta = principalDelta + feesAccrued. We MUST separate them:
    ///      principal ↔ user; fees → hook idle (shared by all shareholders).
    function _unlockDeposit(
        PoolKey memory key,
        address user,
        uint256 amount0Max,
        uint256 amount1Max,
        int24 tLower,
        int24 tUpper
    ) internal returns (uint256 used0, uint256 used1) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(boundId);
        uint128 liquidity = NavLib.liquidityForAmounts(sqrtPriceX96, tLower, tUpper, amount0Max, amount1Max);
        if (liquidity == 0) revert ZeroLiquidity();

        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tLower, tickUpper: tUpper, liquidityDelta: int256(uint256(liquidity)), salt: POSITION_SALT
            }),
            ""
        );

        BalanceDelta principal = callerDelta - feesAccrued;
        used0 = _settlePrincipalFrom(key.currency0, principal.amount0(), user);
        used1 = _settlePrincipalFrom(key.currency1, principal.amount1(), user);
        _takeFeesToHook(key, feesAccrued);
    }

    function _unlockWithdraw(PoolKey memory key, address user, int24 tLower, int24 tUpper, uint128 liqToRemove)
        internal
        returns (uint256 out0, uint256 out1)
    {
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tLower, tickUpper: tUpper, liquidityDelta: -int256(uint256(liqToRemove)), salt: POSITION_SALT
            }),
            ""
        );

        BalanceDelta principal = callerDelta - feesAccrued;
        // Fees stay with the vault (idle); only principal goes to the withdrawer.
        _takeFeesToHook(key, feesAccrued);
        out0 = _takePrincipalTo(key.currency0, principal.amount0(), user);
        out1 = _takePrincipalTo(key.currency1, principal.amount1(), user);
    }

    function _unlockPoke(PoolKey memory key, int24 tLower, int24 tUpper) internal {
        uint128 liq = _positionLiquidity();
        if (liq == 0) return;

        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tLower, tickUpper: tUpper, liquidityDelta: 0, salt: POSITION_SALT}),
            ""
        );

        // poke: principal should be ~0; take everything owed to the hook as idle.
        BalanceDelta principal = callerDelta - feesAccrued;
        _takeFeesToHook(key, feesAccrued);
        _takePrincipalTo(key.currency0, principal.amount0(), address(this));
        _takePrincipalTo(key.currency1, principal.amount1(), address(this));
    }

    function _unlockRebalance(PoolKey memory key, int24 newLower, int24 newUpper, uint128 oldLiq) internal {
        // Split exit/enter to avoid stack-too-deep under solc without via-IR.
        _exitRangeToHook(key, oldLiq);
        _enterRangeFromHook(key, newLower, newUpper);
        tickLower = newLower;
        tickUpper = newUpper;
    }

    function _exitRangeToHook(PoolKey memory key, uint128 oldLiq) internal {
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(oldLiq)),
                salt: POSITION_SALT
            }),
            ""
        );

        BalanceDelta principal = callerDelta - feesAccrued;
        _takeFeesToHook(key, feesAccrued);
        _takePrincipalTo(key.currency0, principal.amount0(), address(this));
        _takePrincipalTo(key.currency1, principal.amount1(), address(this));
    }

    function _enterRangeFromHook(PoolKey memory key, int24 newLower, int24 newUpper) internal {
        uint256 got0 = key.currency0.balanceOf(address(this));
        uint256 got1 = key.currency1.balanceOf(address(this));

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(boundId);
        uint128 newLiq = NavLib.liquidityForAmounts(sqrtPriceX96, newLower, newUpper, got0, got1);
        if (newLiq == 0) revert ZeroLiquidity();

        (BalanceDelta addCaller, BalanceDelta addFees) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: newLower, tickUpper: newUpper, liquidityDelta: int256(uint256(newLiq)), salt: POSITION_SALT
            }),
            ""
        );

        BalanceDelta addPrincipal = addCaller - addFees;
        _settlePrincipalFrom(key.currency0, addPrincipal.amount0(), address(this));
        _settlePrincipalFrom(key.currency1, addPrincipal.amount1(), address(this));
        _takeFeesToHook(key, addFees);
    }

    function _takeFeesToHook(PoolKey memory key, BalanceDelta feesAccrued) internal {
        // Fees are credits (non-negative). Cast via int256 like OZ BaseCustomAccounting.
        if (feesAccrued.amount0() > 0) {
            key.currency0.take(poolManager, address(this), uint256(int256(feesAccrued.amount0())), false);
        }
        if (feesAccrued.amount1() > 0) {
            key.currency1.take(poolManager, address(this), uint256(int256(feesAccrued.amount1())), false);
        }
    }

    function _settlePrincipalFrom(Currency currency, int128 deltaAmount, address payer)
        internal
        returns (uint256 paid)
    {
        if (deltaAmount >= 0) return 0;
        paid = SignedMath.abs(int256(deltaAmount));
        currency.settle(poolManager, payer, paid, false);
    }

    function _takePrincipalTo(Currency currency, int128 deltaAmount, address recipient)
        internal
        returns (uint256 received)
    {
        if (deltaAmount <= 0) return 0;
        received = uint256(uint128(deltaAmount));
        currency.take(poolManager, recipient, received, false);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────────────────

    function _requireBoundPool(PoolKey calldata key) internal view {
        if (!bound) revert PoolNotBound();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(boundId)) revert WrongPool();
    }

    function _validateTicks(int24 lower, int24 upper) internal view {
        int24 spacing = _poolKey.tickSpacing;
        if (lower >= upper) revert InvalidTicks();
        if (lower % spacing != 0 || upper % spacing != 0) revert InvalidTicks();
        if (lower < TickMath.minUsableTick(spacing) || upper > TickMath.maxUsableTick(spacing)) {
            revert InvalidTicks();
        }
    }

    function _positionLiquidity() internal view returns (uint128 liq) {
        (liq,,) = poolManager.getPositionInfo(boundId, address(this), tickLower, tickUpper, POSITION_SALT);
    }

    /// @dev Principal amounts in-range + uncollected fees (fee-growth) + idle ERC-20 balances.
    ///      Uncollected fees MUST count toward strategy NAV or curators are under-paid vs HODL.
    function _inventory() internal view returns (uint256 amount0, uint256 amount1) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(boundId);
        (uint128 liq, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) =
            poolManager.getPositionInfo(boundId, address(this), tickLower, tickUpper, POSITION_SALT);

        if (liq > 0) {
            (amount0, amount1) = NavLib.getPositionTokenAmounts(
                sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liq
            );

            (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
                poolManager.getFeeGrowthInside(boundId, tickLower, tickUpper);

            // Unchecked: fee-growth deltas are designed to wrap (v3/v4 convention).
            unchecked {
                amount0 += FullMath.mulDiv(liq, feeGrowthInside0X128 - feeGrowthInside0LastX128, FixedPoint128.Q128);
                amount1 += FullMath.mulDiv(liq, feeGrowthInside1X128 - feeGrowthInside1LastX128, FixedPoint128.Q128);
            }
        }

        amount0 += _poolKey.currency0.balanceOf(address(this));
        amount1 += _poolKey.currency1.balanceOf(address(this));
    }

    function _snapshotBenchmark() internal {
        (uint256 a0, uint256 a1) = _inventory();
        benchAmount0 = a0;
        benchAmount1 = a1;
    }

    function _payoutIdle(address user, Currency currency, uint256 shares, uint256 supply)
        internal
        returns (uint256 paid)
    {
        uint256 bal = currency.balanceOf(address(this));
        if (bal == 0 || supply == 0) return 0;
        // shares already burned — use supply = pre-burn supply passed in.
        paid = (bal * shares) / supply;
        // Keep ≥1 wei for remaining shareholders when any balance remains.
        if (shares < supply && paid > 0 && paid == bal) paid = bal - 1;
        if (paid == 0) return 0;
        if (currency.isAddressZero()) {
            (bool ok,) = user.call{value: paid}("");
            require(ok, "ETH_TRANSFER");
        } else {
            IERC20(Currency.unwrap(currency)).safeTransfer(user, paid);
        }
    }

    function _currencyDecimals(Currency currency) internal view returns (uint8) {
        if (currency.isAddressZero()) return 18;
        (bool ok, bytes memory data) = Currency.unwrap(currency).staticcall(abi.encodeWithSignature("decimals()"));
        // Never guess 18: a token with fewer decimals would silently mis-scale NAV
        // and misprice shares. Fail closed instead.
        if (!ok || data.length < 32) revert UnsupportedCurrency();
        return abi.decode(data, (uint8));
    }

    receive() external payable {}
}
