// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

interface ILiquidationPool {
    function distributeFees(uint _amount) external;
}
