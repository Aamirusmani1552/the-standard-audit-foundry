// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import '@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol' as Chainlink;
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import 'src/interfaces/IEUROs.sol';
import 'src/interfaces/ILiquidationPool.sol';
import 'src/interfaces/ILiquidationPoolManager.sol';
import 'src/interfaces/ISmartVaultManager.sol';
import 'src/interfaces/ITokenManager.sol';
import { console2 } from 'forge-std/console2.sol';

contract LiquidationPool is ILiquidationPool {
    using SafeERC20 for IERC20;

    address private immutable TST; // tst token
    address private immutable EUROs; // euros token
    address private immutable eurUsd; // euro usd chain link price feed

    address[] public holders; // positionn holders
    mapping(address => Position) private positions; // open positions
    mapping(bytes => uint) private rewards; // rewards for the addresses
    PendingStake[] private pendingStakes; // pending stakes for the holders

    address payable public manager; // manager of the contract
    address public tokenManager; // token manager

    struct Position {
        address holder;
        uint TST;
        uint EUROs;
    }

    struct Reward {
        bytes32 symbol;
        uint amount;
        uint8 dec;
    }

    struct PendingStake {
        address holder;
        uint createdAt;
        uint TST;
        uint EUROs;
    }

    constructor(address _TST, address _EUROs, address _eurUsd, address _tokenManager) {
        TST = _TST;
        EUROs = _EUROs;
        eurUsd = _eurUsd;
        tokenManager = _tokenManager;
        manager = payable(msg.sender);
    }

    modifier onlyManager() {
        require(msg.sender == manager, 'err-invalid-user');
        _;
    }

    // @audit-info don't forget to add the openzeppelin contract version dependency issue in the report: added
    // lesser from the two will be returned so that the stake of lesser one is incentivized
    // @audit-info but what if the there is a balance in TST but not in EUROs? Would a staker get the rewards: there should be amount
    // in both EUROs and TST to get the rewards
    function stake(Position memory _position) private pure returns (uint) {
        return _position.TST > _position.EUROs ? _position.EUROs : _position.TST;
    }

    // returns the total stakes of the holders. It will only count for the position of the holder in the lesser of the two asset deposited
    // @audit-info but in _stakes, both euro's and tst's will be added and both represent different assets. what is the purpose of this?
    // Both TST and EUROs will have same value in the _stakes
    function getStakeTotal() private view returns (uint _stakes) {
        for (uint i = 0; i < holders.length; i++) {
            Position memory _position = positions[holders[i]];
            _stakes += stake(_position);
        }
    }

    // returns the total TST of the holders. Both TST staked and TST pending
    // @audit-info why is that when the rewards are distributed, they are given to only those who have mature stakes. But when the rewards are calculated they consider the stakes that are not mature yet: design choice
    function getTstTotal() private view returns (uint _tst) {
        for (uint i = 0; i < holders.length; i++) {
            _tst += positions[holders[i]].TST;
        }
        for (uint i = 0; i < pendingStakes.length; i++) {
            _tst += pendingStakes[i].TST;
        }
    }

    function findRewards(address _holder) private view returns (Reward[] memory) {
        ITokenManager.Token[] memory _tokens = ITokenManager(tokenManager).getAcceptedTokens();

        Reward[] memory _rewards = new Reward[](_tokens.length);
        for (uint i = 0; i < _tokens.length; i++) {
            _rewards[i] =
                Reward(_tokens[i].symbol, rewards[abi.encodePacked(_holder, _tokens[i].symbol)], _tokens[i].dec);
        }
        return _rewards;
    }

    // returns only the pending stakes of the holder both in EURO and TST
    function holderPendingStakes(address _holder) private view returns (uint _pendingTST, uint _pendingEUROs) {
        for (uint i = 0; i < pendingStakes.length; i++) {
            PendingStake memory _pendingStake = pendingStakes[i];
            if (_pendingStake.holder == _holder) {
                _pendingTST += _pendingStake.TST;
                _pendingEUROs += _pendingStake.EUROs;
            }
        }
    }

    // returns the position of the holder. It will also add the pending stakes to the position
    // also returns the rewards along with the position info.

    function position(address _holder) external view returns (Position memory _position, Reward[] memory _rewards) {
        _position = positions[_holder];
        (uint _pendingTST, uint _pendingEUROs) = holderPendingStakes(_holder);
        _position.EUROs += _pendingEUROs;
        _position.TST += _pendingTST;

        // @audit-info if the position holds TST, why some percentage of manager's EURO balance is added to the position? - they represent undistributed fees to the staker
        // @audit-info position shows the incorrect balance of the staker. the pool receive percentage of the total balance not whole balance: added
        if (_position.TST > 0) {
            _position.EUROs += (IERC20(EUROs).balanceOf(manager) * _position.TST) / getTstTotal();
        }
        _rewards = findRewards(_holder);
    }

    // returns true only if the position is empty i.e. both TST and EUROs are 0
    function empty(Position memory _position) private pure returns (bool) {
        return _position.TST == 0 && _position.EUROs == 0;
    }

    // delete the holder from the holders array
    // This last holder will be moved to the index of the holder to be deleted
    // and then the last holder will be deleted
    function deleteHolder(address _holder) private {
        for (uint i = 0; i < holders.length; i++) {
            if (holders[i] == _holder) {
                holders[i] = holders[holders.length - 1];
                holders.pop();
            }
        }
    }

    // delete the pending stake from the pending stakes array
    // This last pending stake will be moved to the index of the pending stake to be deleted
    // and then the last pending stake will be deleted

    // @audit-info would that still work if there is only one pending staker: yes
    // @audit-info wouldn't it cause DoS if the number of holders is too large: yes it will
    // @audit-info no natspac added: added
    function deletePendingStake(uint _i) private {
        for (uint i = _i; i < pendingStakes.length - 1; i++) {
            pendingStakes[i] = pendingStakes[i + 1];
        }
        pendingStakes.pop();
    }

    // add the holder to the holders array if not already in the array
    // @audit-info would it cause dos as well when holders are too high: known issue
    function addUniqueHolder(address _holder) private {
        for (uint i = 0; i < holders.length; i++) {
            if (holders[i] == _holder) return;
        }
        holders.push(_holder);
    }

    // consolidate the pending stakes into the positions
    // add the pending stakes to the positions
    function consolidatePendingStakes() private {
        // get the deadlinn. It should be 1 day before so that the rewards can be consolidated
        uint deadline = block.timestamp - 1 days;
        // iterate over the pending stakes
        for (int i = 0; uint(i) < pendingStakes.length; i++) {
            // getting the staker at the index 'i'
            PendingStake memory _stake = pendingStakes[uint(i)];

            // if the stake was created before the deadline. add the stake to the positions
            if (_stake.createdAt < deadline) {
                positions[_stake.holder].holder = _stake.holder;
                positions[_stake.holder].TST += _stake.TST;
                positions[_stake.holder].EUROs += _stake.EUROs;
                // delete the stake from the pending stakes
                deletePendingStake(uint(i));
                // pause iterating on loop because there has been a deletion. "next" item has same index
                i--;
            }
        }
    }

    // increase the position of the user
    function increasePosition(uint _tstVal, uint _eurosVal) external {
        require(_tstVal > 0 || _eurosVal > 0);
        // update the pending stakes. Add the pending stakes to the positions
        consolidatePendingStakes();
        // distribute the fees
        ILiquidationPoolManager(manager).distributeFees();
        // transfer the tokens to the this contract from the staker
        if (_tstVal > 0) {
            IERC20(TST).safeTransferFrom(msg.sender, address(this), _tstVal);
        }
        if (_eurosVal > 0) {
            IERC20(EUROs).safeTransferFrom(msg.sender, address(this), _eurosVal);
        }

        // add the staker to the pending stakers
        // @audit-info does block.timestamp works differently on different chains. Yeah but it will not matter in this case
        pendingStakes.push(PendingStake(msg.sender, block.timestamp, _tstVal, _eurosVal));
        // add the staker to the holders if not present already
        addUniqueHolder(msg.sender);
    }

    // delete the position of the user
    function deletePosition(Position memory _position) private {
        // delete the holder from the holders
        deleteHolder(_position.holder);
        delete positions[_position.holder];
    }

    // decrease the position of the user
    function decreasePosition(uint _tstVal, uint _eurosVal) external {
        // add the pending stakes to the positions
        consolidatePendingStakes();
        // distribute the fees
        ILiquidationPoolManager(manager).distributeFees();

        // check if the user has enough tokens to decrease the position
        require(_tstVal <= positions[msg.sender].TST && _eurosVal <= positions[msg.sender].EUROs, 'invalid-decr-amount');

        // trnasfer the tokens to the user
        if (_tstVal > 0) {
            IERC20(TST).safeTransfer(msg.sender, _tstVal);
            positions[msg.sender].TST -= _tstVal;
        }
        if (_eurosVal > 0) {
            IERC20(EUROs).safeTransfer(msg.sender, _eurosVal);
            positions[msg.sender].EUROs -= _eurosVal;
        }

        // @audit-info shouldn't it check if there is a pending position for the msg.sender before deleting: yes added to findings

        // if the position is empty, delete the position
        if (empty(positions[msg.sender])) deletePosition(positions[msg.sender]);
    }

    // claim the rewards
    // anyone can call it. @audit-info can a not staker call it and get back rewards: nope
    // @audit-info can i claim rewards more than once: Nope, the rewards value are deleted before the claim
    // @audit-info if a token is removed from the token manager, then the rewards will be lost: added
    function claimRewards() external {
        // geth the accepted tokens from token manager
        ITokenManager.Token[] memory _tokens = ITokenManager(tokenManager).getAcceptedTokens();

        // iterate over the tokens
        for (uint i = 0; i < _tokens.length; i++) {
            ITokenManager.Token memory _token = _tokens[i];

            // get the reward amount for the tokens
            uint _rewardAmount = rewards[abi.encodePacked(msg.sender, _token.symbol)];

            // if reward amount is greater than 0, transfer the rewards to the user and delete the rewards
            if (_rewardAmount > 0) {
                delete rewards[abi.encodePacked(msg.sender, _token.symbol)];

                // if token is native (means address 0), transfer the native token to the user
                if (_token.addr == address(0)) {
                    (bool _sent,) = payable(msg.sender).call{ value: _rewardAmount }('');
                    require(_sent);
                    // if token is not native, transfer the token to the user
                } else {
                    // @audit-info ERC20 safeTransfer should be used: know issue
                    IERC20(_token.addr).transfer(msg.sender, _rewardAmount);
                }
            }
        }
    }

    // manager is going to call this function to distribute the fees
    function distributeFees(uint _amount) external onlyManager {
        uint tstTotal = getTstTotal();
        if (tstTotal > 0) {
            // fees will be transferred from the manager to this contract
            IERC20(EUROs).safeTransferFrom(msg.sender, address(this), _amount);

            // iterate over the holders and add the fees to the rewards
            // @audit-info distribute fees will only be received by the TST holder: yes, design choice
            // @audit-info why fee is only distributed on the basis of TST and not EUROs: desing choice
            for (uint i = 0; i < holders.length; i++) {
                address _holder = holders[i];
                positions[_holder].EUROs += (_amount * positions[_holder].TST) / tstTotal;
            }

            // iterate over the pending stakes and add the fees to the rewards
            // @audit-info why is this distributed to pending stakes? because total stakes also has pending stakes: No issue here
            for (uint i = 0; i < pendingStakes.length; i++) {
                pendingStakes[i].EUROs += (_amount * pendingStakes[i].TST) / tstTotal;
            }
        }
    }

    // return the unpurchased native tokens to the manager
    function returnUnpurchasedNative(ILiquidationPoolManager.Asset[] memory _assets, uint _nativePurchased) private {
        for (uint i = 0; i < _assets.length; i++) {
            if (_assets[i].token.addr == address(0) && _assets[i].token.symbol != bytes32(0)) {
                (bool _sent,) = manager.call{ value: _assets[i].amount - _nativePurchased }('');
                require(_sent);
            }
        }
    }

    // @audit-info if this transfer the assets to the different addresses then the liquidated function should transfer the tokens to
    // this contract right: yes and it does
    // @audit-info can't i just multiply my rewards by just calling it: it allows for manipulation
    // @audit-info if there will be a lot of holder it will not work due to gas greif right: yes but have to check in know issues
    // @audit-info will it burn some tokens of the users: yes the euros amount that is used to buy the liquidated assets at discount
    // @audit-info will it not cause the DoS if the number of holders are too high: yes it will have to check in known issues
    // @audit-info can't I just pass any value to steal the tokens: yes added to final report
    function distributeAssets(
        ILiquidationPoolManager.Asset[] memory _assets,
        uint _collateralRate,
        uint _hundredPC
    )
        external
        payable
    {
        consolidatePendingStakes();
        // @audit-info stale price can be used to manipulate the rewards: yes need to check the known issues
        // @audit some price feeds has too long heartbeat and deviation rate that could lead to the loss of the tokens
        // @audit for some assets, there is an active price feed on the L2s but not on mainnet or other chains
        (, int priceEurUsd,,,) = Chainlink.AggregatorV3Interface(eurUsd).latestRoundData();

        // @audit-info this only hold total stakes in the form of tst or euro or both. how is it calculated for the rewards because both represent different assets: both represent same value
        uint stakeTotal = getStakeTotal();
        uint burnEuros;
        uint nativePurchased;
        // run it for all holders
        for (uint j = 0; j < holders.length; j++) {
            // geth the position of the holder.
            Position memory _position = positions[holders[j]];
            // get the stake of the holder. It will only return the lesser of the two assets.
            uint _positionStake = stake(_position);
            // if the stake is greater than 0, distribute the rewards to staker for every asset
            if (_positionStake > 0) {
                // run it for all the assets that was liquidated
                for (uint i = 0; i < _assets.length; i++) {
                    // get the asset data
                    ILiquidationPoolManager.Asset memory asset = _assets[i];
                    // if the asset amount is greater than 0, calculate the rewards and transfer the rewards to the staker
                    if (asset.amount > 0) {
                        // get the asset's price in USD from chainlink
                        // @audit-info not price feed sanity check: added
                        (, int assetPriceUsd,,,) = Chainlink.AggregatorV3Interface(asset.token.clAddr).latestRoundData();
                        // calculate the portion of the asset for the staker based on his stake
                        // console2.log('\nrewards: ', string(abi.encode(asset.token.symbol)));
                        // console2.log('asset amount: ', asset.amount);
                        // console2.log('Position stake', _positionStake);
                        // console2.log('Total Stake', stakeTotal);
                        // console2.log('asset price in USD', assetPriceUsd);
                        uint _portion = (asset.amount * _positionStake) / stakeTotal;
                        // console2.log('Portion to be recieved: ', _portion);
                        // calculate the cost of the portion in euros
                        // @audit for now we will assume that it will return the value in correct decimals
                        // @audit-info don't forge to submit the rounding down vulnerability: added
                        // @audit so divide by collateral mean's that there will be some rewards for the assets right?
                        uint costInEuros = (
                            ((_portion * 10 ** (18 - asset.token.dec) * uint(assetPriceUsd)) / uint(priceEurUsd))
                                * _hundredPC
                        ) / _collateralRate;

                        // console2.log('price Eur to USD: ', priceEurUsd);
                        // console2.log('Cost in euros: ', costInEuros);

                        if (costInEuros > _position.EUROs) {
                            _portion = (_portion * _position.EUROs) / costInEuros;
                            // console2.log('Position Euros: ', _position.EUROs);
                            // console2.log('New portion: ', _portion);
                            costInEuros = _position.EUROs;
                            // console2.log('New cost in euros: %s \n', costInEuros);
                            // console2.log(
                            //     '_portion cost in euros: %s \n',
                            //     (_portion * 10 ** (18 - asset.token.dec) * uint(assetPriceUsd)) / uint(priceEurUsd)
                            // );
                        }
                        _position.EUROs -= costInEuros;
                        // add the rewards to the rewards mapping for the holder

                        rewards[abi.encodePacked(_position.holder, asset.token.symbol)] += _portion;
                        burnEuros += costInEuros;
                        if (asset.token.addr == address(0)) {
                            nativePurchased += _portion;
                        } else {
                            IERC20(asset.token.addr).safeTransferFrom(manager, address(this), _portion);
                        }
                    }
                }
            }

            // update the position of the holder
            positions[holders[j]] = _position;
        }
        if (burnEuros > 0) IEUROs(EUROs).burn(address(this), burnEuros);

        returnUnpurchasedNative(_assets, nativePurchased);
    }
}
