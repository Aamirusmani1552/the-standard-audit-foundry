// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import {Common} from "../Common.t.sol";

contract Handler is Common{
    uint256 initialUserAmountOfTokens = 1000 ether;
    uint256 randomNonce = 0;
    bool initialized;

    function setUp() public override {
        if(initialized) return;
        super.setUp();
        vm.deal(address(this), 1000 ether);
        initialized = true;
    }


    function increaseLiquidationPoolPosition(uint256 amountEuros, uint256 amountTSTs) public returns(uint256, uint256) {
        address user = _createRandomUser();

        amountEuros = bound(amountEuros, 1000, 1000_000 ether);
        amountTSTs = bound(amountTSTs, 1000, 1_000_000 ether);

        tokens.eurosToken.mint(address(user), amountEuros);
        tokens.tstToken.mint(address(user), amountTSTs);

        vm.startPrank(user);
        // approve the liquidation pool to spend the user's tokens
        tokens.eurosToken.approve(address(contracts.liquidationPool), amountEuros);
        tokens.tstToken.approve(address(contracts.liquidationPool), amountTSTs);

        // deposit the user's tokens into the liquidation pool
        contracts.liquidationPool.increasePosition(amountEuros, amountTSTs);
        vm.stopPrank();

        return(amountEuros, amountTSTs);
    }

    function _createRandomUser() internal returns (address) {
        address user = address(uint160(uint256(keccak256(abi.encodePacked(block.timestamp, block.difficulty, randomNonce++)))));
        vm.deal(user, 1000 ether);
        return user;
    }

    // contracts Getter
    function getProtocolContracts() public view returns (ContractInstances memory) {
        return contracts;
    }

    function getTokensContracts() public view returns (TokensInstances memory) {
        return tokens;
    }

    function getPriceFeedsContracts() public view returns (PriceFeedsInstances memory) {
        return priceFeeds;
    }

}