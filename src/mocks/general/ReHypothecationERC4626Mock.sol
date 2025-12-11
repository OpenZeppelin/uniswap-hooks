// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// Internal imports
import {BaseHook} from "../../base/BaseHook.sol";
import {ReHypothecationHook} from "../../general/ReHypothecationHook.sol";

/// @title ERC4626Mock
/// @notice A mock implementation of the ERC-4626 yield source.
contract ERC4626YieldSourceMock is ERC4626 {
    constructor(IERC20 token) ERC4626(token) ERC20("ERC4626YieldSourceMock", "E4626YS") {}
}

/// @title ReHypothecationERC4626Mock
/// @notice A mock implementation of the ReHypothecationHook for ERC-4626 yield sources.
contract ReHypothecationERC4626Mock is ReHypothecationHook {
    using Math for *;
    using SafeERC20 for IERC20;

    /// @dev Error thrown when attempting to use an unsupported currency.
    error UnsupportedCurrency();

    /// @dev Error thrown when attempting to use an invalid yield source.
    error InvalidYieldSource();

    address private immutable yieldSource0;
    address private immutable yieldSource1;

    constructor(IPoolManager _poolManager, address yieldSource0_, address yieldSource1_)
        BaseHook(_poolManager)
        ERC20("ReHypothecatatedShare", "RHM")
    {
        if (yieldSource0_ == address(0) || yieldSource1_ == address(0)) {
            revert InvalidYieldSource();
        }
        yieldSource0 = yieldSource0_;
        yieldSource1 = yieldSource1_;
    }

    /// @dev Override to disable native currency, which is not supported by ERC-4626 yield sources.
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        override
        returns (bytes4)
    {
        if (key.currency0.isAddressZero()) revert UnsupportedCurrency();
        return super._beforeInitialize(sender, key, sqrtPriceX96);
    }

    /// @inheritdoc ReHypothecationHook
    function getCurrencyYieldSource(Currency currency) public view override returns (address) {
        PoolKey memory poolKey = getPoolKey();
        if (currency == poolKey.currency0) return yieldSource0;
        if (currency == poolKey.currency1) return yieldSource1;
        revert UnsupportedCurrency();
    }

    /// @inheritdoc ReHypothecationHook
    function _depositToYieldSource(Currency currency, uint256 amount) internal virtual override {
        address yieldSource = getCurrencyYieldSource(currency);
        if (yieldSource == address(0)) revert UnsupportedCurrency();
        IERC20(Currency.unwrap(currency)).approve(address(yieldSource), amount);
        IERC4626(yieldSource).deposit(amount, address(this));
    }

    /// @inheritdoc ReHypothecationHook
    function _withdrawFromYieldSource(Currency currency, uint256 amount) internal virtual override {
        IERC4626 yieldSource = IERC4626(getCurrencyYieldSource(currency));
        if (address(yieldSource) == address(0)) revert UnsupportedCurrency();
        yieldSource.withdraw(amount, address(this), address(this));
    }

    /// @inheritdoc ReHypothecationHook
    function _getAmountInYieldSource(Currency currency) internal view virtual override returns (uint256 amount) {
        IERC4626 yieldSource = IERC4626(getCurrencyYieldSource(currency));
        uint256 yieldSourceShares = yieldSource.balanceOf(address(this));
        return yieldSource.convertToAssets(yieldSourceShares);
    }

    /// @dev Override to disable native currency, which is not supported by ERC-4626 yield sources.
    receive() external payable override {
        revert UnsupportedCurrency();
    }

    /// @dev Exposed internal function for testing
    function getAmountInYieldSource(Currency currency) public view returns (uint256) {
        return _getAmountInYieldSource(currency);
    }

    /// @dev Exposed internal function for testing
    function burnYieldSourcesBalance(Currency currency, uint256 amount) public returns (uint256) {
        IERC4626 yieldSource = IERC4626(getCurrencyYieldSource(currency));
        if (address(yieldSource) == address(0)) revert UnsupportedCurrency();
        return yieldSource.withdraw(amount, address(0), address(this));
    }

    // Exclude from coverage report
    function test() public {}
}
