// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Common, console2, LiquidationPool, SmartVaultV3} from "../Common.t.sol";

contract Unit is Common {
    function setUp() public override {
        super.setUp();
    }

    // @audit test passed
    function test_decreaseStakeCanCauseLossOfFeeReward() public {
        ////////////////////////////////////////////
        ///     Minting some tokens to users     ///
        ////////////////////////////////////////////

        uint256 amount = 1000 ether; // 1000 tokens

        tokens.eurosToken.mint(alice, amount * 2);
        tokens.eurosToken.mint(bob, amount * 2);

        tokens.tstToken.mint(alice, amount * 2);
        tokens.tstToken.mint(bob, amount * 2);

        /////////////////////////////////////////////////////////
        ///     Alice and Bob deposits tokens in the pool     ///
        /////////////////////////////////////////////////////////

        vm.startPrank(alice);
        tokens.tstToken.approve(address(contracts.liquidationPool), amount);
        tokens.eurosToken.approve(address(contracts.liquidationPool), amount);
        vm.stopPrank();

        vm.startPrank(bob);
        tokens.tstToken.approve(address(contracts.liquidationPool), amount);
        tokens.eurosToken.approve(address(contracts.liquidationPool), amount);
        vm.stopPrank();

        vm.prank(alice);
        contracts.liquidationPool.increasePosition(amount, amount);

        vm.prank(bob);
        contracts.liquidationPool.increasePosition(amount, amount);

        ////////////////////////////////////////////////////////////
        /////   Checking if correct value has been deposited   /////
        ////////////////////////////////////////////////////////////

        (LiquidationPool.Position memory alicePosition, ) = contracts
            .liquidationPool
            .position(alice);
        (LiquidationPool.Position memory bobPosition, ) = contracts
            .liquidationPool
            .position(bob);

        assertEq(
            alicePosition.EUROs,
            amount,
            "Alice's euros amount are not eqaul"
        );
        assertEq(
            alicePosition.TST,
            amount,
            "Alice's TSTs amount are not eqaul"
        );
        assertEq(bobPosition.EUROs, amount, "Bob's euros amount are not eqaul");
        assertEq(bobPosition.TST, amount, "Bob's TSTs amount are not eqaul");

        /////////////////////////////////////////////////////////
        ///     Skipping some time to consolidate stakes     ////
        /////////////////////////////////////////////////////////

        // NOTE: Actual consolidation will be done when someone increases or decreases their positions
        skip(block.timestamp + 1 weeks);

        /////////////////////////////////////////////////////////////////////////////
        ///     Alice and bob holds 1000 TST and EUROs Each in Pending Stakes     ///
        /////////////////////////////////////////////////////////////////////////////

        ////////////////////////////////////
        ///     Mike Creates a Vault     ///
        ////////////////////////////////////

        address mike = makeAddr("mike");
        (address mikesSmartVault, uint256 tokenIdMinted) = _createSmartVault(
            mike
        );

        //////////////////////////////////////////////////////////
        ///     Checking If Mike is the owner of the vault     ///
        //////////////////////////////////////////////////////////

        assertEq(
            contracts.smartVaultManagerV5.ownerOf(tokenIdMinted),
            mike,
            "Mike is not the owner"
        );

        ////////////////////////////////////////////////////////
        ///     Mike deposits some tokens in the vault    //////
        ////////////////////////////////////////////////////////

        vm.startPrank(mike);
        uint256 mikePaxgAmount = 1000 ether;
        tokens.paxgToken.mint(mike, mikePaxgAmount);
        tokens.paxgToken.transfer(mikesSmartVault, amount);
        vm.stopPrank();

        //////////////////////////////////////////////////////////////////////////////////
        ///     Checking if the correct balances has been transferred to the vault     ///
        //////////////////////////////////////////////////////////////////////////////////

        uint256 mikePaxgBalanceInVault = tokens.paxgToken.balanceOf(
            mikesSmartVault
        );

        assertEq(
            mikePaxgAmount,
            mikePaxgBalanceInVault,
            "Balance is not equal"
        );

        /////////////////////////////////////////////////////////////////////////////////////////////
        ///     Mike decides to mint some euros from the vault that generates some fees           ///
        ///     feeGenerated = (eurosMikeWant * constants.PROTOCOL_FEE_RATE) / 100000             ///
        ///     feeGenerated =  500 ether * 500 / 100000                                          ///
        ///     feeGenerated =  2.5 ether                                                         ///
        /////////////////////////////////////////////////////////////////////////////////////////////

        vm.startPrank(mike);
        uint256 eurosMikeWant = mikePaxgBalanceInVault / 2;
        SmartVaultV3(payable(mikesSmartVault)).mint(mike, eurosMikeWant);
        vm.stopPrank();

        /////////////////////////////////////////////////////////////////////////////////////////
        ///     Checking if the correct amount of euros has been minted from the vault     //////
        /////////////////////////////////////////////////////////////////////////////////////////

        uint256 mikeEurosBalance = tokens.eurosToken.balanceOf(mike);
        assertEq(mikeEurosBalance, eurosMikeWant, "Balance is not equal");

        ///////////////////////////////////////////////////////////////////////////
        ///     There should be some euros fee in the liqudiationPoolManager    ///
        ///////////////////////////////////////////////////////////////////////////

        uint256 feeGenerated = (eurosMikeWant * constants.PROTOCOL_FEE_RATE) /
            100000;
        uint256 eurosFeeInLiquidationManager = tokens.eurosToken.balanceOf(
            address(contracts.liquidationPoolManager)
        );
        assertEq(
            eurosFeeInLiquidationManager,
            feeGenerated,
            "fee is not equal"
        );
        assertEq(eurosFeeInLiquidationManager, 2.5 ether, "fee is not equal");

        ///////////////////////////////////////////////////////////////////////////////////////////////////
        ///    Bob add more tokens to his positions. This time there is a fee                           ///
        ///    in the liquidationPoolManager that will be added to his stakes                           ///
        ///    Proporational to his stakes                                                              ///
        ///    Bob's fee share = feeGenerated * (balance before the stake) / (Total TST balance)        ///
        ///    Bob's fee share = 2.5 tokens * 1000 tokens / 4000 tokens (2000 bobs and 2000 alice's)    ///
        ///    Bob's fee share = 0.625 euros                                                            ///
        ///////////////////////////////////////////////////////////////////////////////////////////////////

        vm.startPrank(bob);
        tokens.eurosToken.approve(address(contracts.liquidationPool), amount);
        tokens.tstToken.approve(address(contracts.liquidationPool), amount);
        contracts.liquidationPool.increasePosition(amount, amount);
        vm.stopPrank();

        ////////////////////////////////////////////////////////////////////////////////////////////
        ///    Checking if the correct value has been deposited to the pool and bob's position   ///
        ////////////////////////////////////////////////////////////////////////////////////////////

        (bobPosition, ) = contracts.liquidationPool.position(bob);

        uint256 bobsFeeShare = (eurosFeeInLiquidationManager * (amount)) /
            tokens.tstToken.totalSupply();

        assertEq(
            bobPosition.EUROs,
            amount * 2 + bobsFeeShare,
            "Bob's euros amount are not eqaul"
        );
        assertEq(bobsFeeShare, 0.625 ether, "Bob's fee share is not equal");
        assertEq(
            bobPosition.TST,
            amount * 2,
            "Bob's TSTs amount are not eqaul"
        );

        ////////////////////////////////////////////////////////////////////////////////////////
        ///     Bob now holds 1000 TSTs and 1000.0625 euros in consolidated stakes          ////
        ///     and 1000 TSTs and 1000 euros in pending stakes                              ////
        ////////////////////////////////////////////////////////////////////////////////////////

        ///////////////////////////////////////////////////////////////////////
        ///     Bob decides to withdraw his stake for some reason           ///
        ///     on same day. Since he deposited the tokens on the           ///
        ///     same day, he can only withdraw his consolidated stake.      ///
        ///     Bob's consolidated stake = 1000 Tst and 1000.0625 euros     ///
        ///     Since he is withdrawing all of his consolidated stake,      ///
        ///     his address will be removed from holders array.             ///
        ///////////////////////////////////////////////////////////////////////

        vm.startPrank(bob);
        contracts.liquidationPool.decreasePosition(
            amount,
            amount + 0.625 ether
        );
        vm.stopPrank();

        ////////////////////////////////////////////////////////////////////////////////
        ///     Checking bob's position. There is only balance in pending stakes     ///
        ///     Bob's consolidated stake = 0 Tst and 0 euros                         ///
        ///     Bob's pending stake = 1000 Tst and 1000 euros                        ///
        ////////////////////////////////////////////////////////////////////////////////

        (bobPosition, ) = contracts.liquidationPool.position(bob);

        assertEq(bobPosition.EUROs, amount, "Bob's euros amount are not eqaul");
        assertEq(bobPosition.TST, amount, "Bob's euros amount are not eqaul");

        //////////////////////////////////////////////////////////////////////////////////////
        ///     Mike decides to mint some more tokens against his vault balances.          ///
        ///     More fee will be generated and added to the liquidationPoolManager         ///
        ///     feeGenerated = 2.5 tokens          (i.e because same amount is deposited)  ///
        //////////////////////////////////////////////////////////////////////////////////////

        tokens.paxgToken.mint(mike, amount);
        vm.startPrank(mike);
        tokens.paxgToken.transfer(mikesSmartVault, amount);
        SmartVaultV3(payable(mikesSmartVault)).mint(mike, eurosMikeWant);
        vm.stopPrank();

        ///////////////////////////////////////////////////////////////////////////
        ///     Checking if correct balance has been deposited to the vault     ///
        ///////////////////////////////////////////////////////////////////////////

        mikePaxgBalanceInVault = tokens.paxgToken.balanceOf(mikesSmartVault);

        assertEq(
            mikePaxgAmount * 2, // because mike deposited 1000 tokens before
            mikePaxgBalanceInVault,
            "Balance is not equal"
        );

        ////////////////////////////////////////////////////
        ///     Checking if correct fee is generated     ///
        ////////////////////////////////////////////////////

        eurosFeeInLiquidationManager = tokens.eurosToken.balanceOf(
            address(contracts.liquidationPoolManager)
        );

        assertEq(
            eurosFeeInLiquidationManager,
            feeGenerated,
            "Balance is empty"
        );
        assertEq(eurosFeeInLiquidationManager, 2.5 ether, "Balance is empty");

        /////////////////////////////////////////////////////
        ///     Skipping some time to consolidate stakes  ///
        /////////////////////////////////////////////////////

        skip(block.timestamp + 1 weeks);

        ///////////////////////////////////////////////////////////////////////////////////////////
        ///     Since enough time has passed bob decides to withdraw rest of his amount.        ///
        ///     Also there is a fee in liquidationPoolManager that will be added to his         ///
        ///     stakes corresponding to his stake ratio.                                        ///
        ///     Bob's fee share = 0.625       (since both fee generated and stake is same)      ///
        ///////////////////////////////////////////////////////////////////////////////////////////

        vm.startPrank(bob);
        contracts.liquidationPool.decreasePosition(amount, amount);
        vm.stopPrank();

        /////////////////////////////////////////////////////////////////////////////////
        ///     Since bob has withdrawn all of his stakes excluding fee received,     ///
        ///     there should be amount equals to his fee share in the position.       ///
        ///     That means bob's position should be 0 TST and 0.625 euros             ///
        /////////////////////////////////////////////////////////////////////////////////

        (bobPosition, ) = contracts.liquidationPool.position(bob);

        ///////////////////////////////////////////////////////////////////////////////////////////////////
        ///     But fee is not received since bob's address has been withdrawn from the holders array   ///
        ///     So his position should be 0 TST and 0 euros                                             ///
        ///////////////////////////////////////////////////////////////////////////////////////////////////

        assertEq(bobPosition.EUROs, 0, "Bob's euros amount is not zero");
        assertEq(bobPosition.TST, 0);
    }

    function _createSmartVault(
        address _user
    ) internal returns (address, uint256) {
        vm.prank(_user);
        (address smartVault, uint256 tokenId) = contracts
            .smartVaultManagerV5
            .mint();
        vm.stopPrank();
        return (smartVault, tokenId);
    }
}
