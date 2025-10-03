// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Internal imports
import {ReHypothecationHook} from "../general/ReHypothecationHook.sol";
import {ERC4626YieldSourceMock} from "./ReHypothecationERC4626Mock.sol";

/// @notice A mock implementation of a native yield source.
/// NOTE: This mock implementation of a native yield source is for testing purposes only.
contract NativeYieldSourceMock is ERC20 {
    using Math for *;

    error InvalidAmount();

    constructor() ERC20("NativeYieldSourceMock", "NYSM") {}

    function totalAssets() public view virtual returns (uint256) {
        return address(this).balance;
    }

    function convertToAssets(uint256 shares) public view virtual returns (uint256) {
        return _convertToAssets(shares);
    }

    function convertToShares(uint256 assets) public view virtual returns (uint256) {
        return _convertToShares(assets);
    }

    function _convertToShares(uint256 assets) internal view virtual returns (uint256) {
        return assets.mulDiv(totalSupply(), totalAssets());
    }

    function _convertToAssets(uint256 shares) internal view virtual returns (uint256) {
        return shares.mulDiv(totalAssets(), totalSupply());
    }

    function deposit(uint256 amount, address to) public payable {
        if (msg.value != amount) revert InvalidAmount();
        _mint(to, amount);
    }

    function withdraw(uint256 assets, address to) public payable {
        uint256 shares = _convertToShares(assets);
        _burn(msg.sender, shares);
        payable(to).transfer(assets);
    }
}

/// @title ReHypothecationNativeMock
/// @notice A mock implementation of the ReHypothecationHook for a mixed use case of native ETH and ERC20 tokens.
/// The ERC20 is invested into an ERC-4626 yield source, while the native ETH is invested into a native yield source.
contract ReHypothecationNativeMock is ReHypothecationHook {
    using SafeERC20 for IERC20;

    address private _yieldSource0;
    address private _yieldSource1;

    /// @dev Error thrown when attempting to use an unsupported currency.
    error UnsupportedCurrency();

    constructor(address yieldSource0_, address yieldSource1_) ReHypothecationHook("ReHypothecationMock", "RHM") {
        _yieldSource0 = yieldSource0_;
        _yieldSource1 = yieldSource1_;
    }

    /// @inheritdoc ReHypothecationHook
    function getCurrencyYieldSource(Currency currency) public view override returns (address) {
        PoolKey memory poolKey = getPoolKey();
        if (currency == poolKey.currency0) return _yieldSource0;
        if (currency == poolKey.currency1) return _yieldSource1;
        revert UnsupportedCurrency();
    }

    /// @inheritdoc ReHypothecationHook
    function _depositToYieldSource(Currency currency, uint256 amount) internal virtual override {
        address yieldSource = getCurrencyYieldSource(currency);
        if (yieldSource == address(0)) revert UnsupportedCurrency();
        if (currency.isAddressZero()) {
            NativeYieldSourceMock(yieldSource).deposit{value: amount}(amount, address(this));
        } else {
            IERC20(Currency.unwrap(currency)).approve(address(yieldSource), amount);
            NativeYieldSourceMock(yieldSource).deposit(amount, address(this));
        }
    }

    /// @inheritdoc ReHypothecationHook
    function _withdrawFromYieldSource(Currency currency, uint256 amount) internal virtual override {
        address yieldSource = getCurrencyYieldSource(currency);
        if (address(yieldSource) == address(0)) revert UnsupportedCurrency();
        if (currency.isAddressZero()) {
            NativeYieldSourceMock(yieldSource).withdraw(amount, address(this));
        } else {
            ERC4626YieldSourceMock(yieldSource).withdraw(amount, address(this), address(this));
        }
    }

    /// @inheritdoc ReHypothecationHook
    function _getAmountInYieldSource(Currency currency) internal view virtual override returns (uint256 amount) {
        address yieldSource = getCurrencyYieldSource(currency);
        uint256 yieldSourceShares = IERC20(yieldSource).balanceOf(address(this));
        return NativeYieldSourceMock(yieldSource).convertToAssets(yieldSourceShares);
    }

    /// Override required to handle native ETH
    function _transferFromSenderToHook(Currency currency, uint256 amount, address sender) internal virtual override {
        if (currency.isAddressZero()) {
            if (msg.value < amount) revert InvalidMsgValue();
            if (msg.value > amount) {
                (bool success,) = msg.sender.call{value: msg.value - amount}("");
                if (!success) revert RefundFailed();
            }
        } else {
            super._transferFromSenderToHook(currency, amount, sender);
        }
    }

    /// @dev Helpers for testing
    function getAmountInYieldSource(Currency currency) public view returns (uint256) {
        return _getAmountInYieldSource(currency);
    }

    // Exclude from coverage report
    function test() public {}
}
