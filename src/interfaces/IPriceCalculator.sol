// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import 'src/interfaces/ITokenManager.sol';

interface IPriceCalculator {
    function tokenToEurAvg(ITokenManager.Token memory _token, uint _amount) external view returns (uint);

    function tokenToEur(ITokenManager.Token memory _token, uint _amount) external view returns (uint);

    function eurToToken(ITokenManager.Token memory _token, uint _amount) external view returns (uint);
}
