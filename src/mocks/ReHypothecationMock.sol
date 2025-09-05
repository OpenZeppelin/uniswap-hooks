// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.26;

// import {ReHypothecationHook} from "src/general/ReHypothecationHook.sol";
// import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
// import {Currency} from "v4-core/src/types/Currency.sol";
// import {PoolKey} from "v4-core/src/types/PoolKey.sol";
// import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
// import {ERC4626} from "openzeppelin/token/ERC20/extensions/ERC4626.sol";
// import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

// contract ERC4626Mock is ERC4626 {
//     constructor(IERC20 token, string memory name, string memory symbol) ERC4626(token) ERC20(name, symbol) {}
// }

// contract ReHypothecationMock is ReHypothecationHook {
//     address private _yieldSource0;
//     address private _yieldSource1;

//     constructor(IPoolManager poolManager_, address yieldSource0_, address yieldSource1_)
//         ReHypothecationHook(poolManager_)
//         ERC20("ReHypothecationMock", "RHM")
//     {
//         _yieldSource0 = yieldSource0_;
//         _yieldSource1 = yieldSource1_;
//     }

//     // overrides for testing
//     function getYieldSourceForCurrency(Currency currency) public view override returns (address) {
//         PoolKey memory poolKey = getPoolKey();
//         if (currency == poolKey.currency0) return _yieldSource0;
//         if (currency == poolKey.currency1) return _yieldSource1;
//         revert UnsupportedCurrency();
//     }

//     // Exclude from coverage report
//     function test() public {}
// }
