// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import 'src/interfaces/ITokenManager.sol';

interface ISmartVault {
    struct Asset {
        ITokenManager.Token token;
        uint amount;
        uint collateralValue;
    }

    struct Status {
        address vaultAddress;
        uint minted;
        uint maxMintable;
        uint totalCollateralValue;
        Asset[] collateral;
        bool liquidated;
        uint8 version;
        bytes32 vaultType;
    }

    function status() external view returns (Status memory);

    function undercollateralised() external view returns (bool);

    function setOwner(address _newOwner) external;

    function liquidate() external;
}
