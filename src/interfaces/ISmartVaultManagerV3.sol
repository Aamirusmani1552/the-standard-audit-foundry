// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "src/interfaces/ISmartVaultManager.sol";
import "src/interfaces/ISmartVaultManagerV2.sol";

interface ISmartVaultManagerV3 is ISmartVaultManagerV2, ISmartVaultManager {
    function swapRouter2() external view returns (address);
}
