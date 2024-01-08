// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import 'src/interfaces/ITokenManager.sol';

interface ILiquidationPoolManager {
    struct Asset {
        ITokenManager.Token token;
        uint amount;
    }

    function distributeFees() external;

    function runLiquidation(uint _tokenId) external;
}
