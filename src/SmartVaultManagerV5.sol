// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "@openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin-contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "src/interfaces/INFTMetadataGenerator.sol";
import "src/interfaces/IEUROs.sol";
import "src/interfaces/ISmartVault.sol";
import "src/interfaces/ISmartVaultDeployer.sol";
import "src/interfaces/ISmartVaultIndex.sol";
import "src/interfaces/ISmartVaultManager.sol";
import "src/interfaces/ISmartVaultManagerV2.sol";

// @audit ownable contract not initialized as well as erc721
// @audit upgradeable version of initializable should be used
contract SmartVaultManagerV5 is
    ISmartVaultManager,
    ISmartVaultManagerV2,
    Initializable,
    ERC721Upgradeable,
    OwnableUpgradeable
{
    using SafeERC20 for IERC20;

    uint256 public constant HUNDRED_PC = 1e5;

    address public protocol;
    address public liquidator;
    address public euros;
    uint256 public collateralRate;
    address public tokenManager;
    address public smartVaultDeployer;
    ISmartVaultIndex private smartVaultIndex;
    uint256 private lastToken;
    address public nftMetadataGenerator;
    uint256 public mintFeeRate;
    uint256 public burnFeeRate;
    // newly added data
    uint256 public swapFeeRate;
    address public weth;
    address public swapRouter;
    address public swapRouter2;

    event VaultDeployed(
        address indexed vaultAddress,
        address indexed owner,
        address vaultType,
        uint256 tokenId
    );
    event VaultLiquidated(address indexed vaultAddress);
    event VaultTransferred(uint256 indexed tokenId, address from, address to);

    struct SmartVaultData {
        uint256 tokenId;
        uint256 collateralRate;
        uint256 mintFeeRate;
        uint256 burnFeeRate;
        ISmartVault.Status status;
    }

    function initialize() public initializer {}

    modifier onlyLiquidator() {
        require(msg.sender == liquidator, "err-invalid-liquidator");
        _;
    }

    // returns the vaults owned by the msg.sender
    function vaults() external view returns (SmartVaultData[] memory) {
        // get the tokenIds owned by the msg.sender
        uint256[] memory tokenIds = smartVaultIndex.getTokenIds(msg.sender);
        uint256 idsLength = tokenIds.length;
        // create an array of SmartVaultData structs
        // struct Status {
        //     address vaultAddress;
        //     uint256 minted;
        //     uint256 maxMintable;
        //     uint256 totalCollateralValue;
        //     Asset[] collateral;
        //     bool liquidated;
        //     uint8 version;
        //     bytes32 vaultType;
        // }
        SmartVaultData[] memory vaultData = new SmartVaultData[](idsLength);

        // for each tokenId owned by the msg.sender, get the vault address and status
        for (uint256 i = 0; i < idsLength; i++) {
            uint256 tokenId = tokenIds[i];
            vaultData[i] = SmartVaultData({
                tokenId: tokenId,
                collateralRate: collateralRate,
                mintFeeRate: mintFeeRate,
                burnFeeRate: burnFeeRate,
                status: ISmartVault(smartVaultIndex.getVaultAddress(tokenId))
                    .status()
            });
        }
        return vaultData;
    }

    // @audit is it allowed to mint more than one vault for a particular msg.sender
    // mint new vault token to the msg.sender
    function mint() external returns (address vault, uint256 tokenId) {
        // increment the tokenId and mint the new vault
        // @audit 0 token id will not be minted. will that cause any issues?
        tokenId = lastToken + 1;
        _safeMint(msg.sender, tokenId);
        lastToken = tokenId;

        // deploy the vault
        vault = ISmartVaultDeployer(smartVaultDeployer).deploy(
            address(this), // manager
            msg.sender, // owner
            euros // euros token
        );

        // add the vault address to the smart vault index
        smartVaultIndex.addVaultAddress(tokenId, payable(vault));

        // grant the vault the minter and burner roles in euros token
        IEUROs(euros).grantRole(IEUROs(euros).MINTER_ROLE(), vault);
        IEUROs(euros).grantRole(IEUROs(euros).BURNER_ROLE(), vault);
        emit VaultDeployed(vault, msg.sender, euros, tokenId);
    }

    // liquidate the vault with the given tokenId
    // can be called by the liquidator only
    // @audit who is going to be the liquidator?
    // @audit who is going to be benefitted from the liquidation? would that be protocol or the stakers?
    function liquidateVault(uint256 _tokenId) external onlyLiquidator {
        // get the vault address from the smart vault index
        ISmartVault vault = ISmartVault(
            smartVaultIndex.getVaultAddress(_tokenId)
        );

        // @audit should this be checked whether the vault is deployed for the tokenId?

        // try calling undercollateralised() on the vault to get the status
        try vault.undercollateralised() returns (bool _undercollateralised) {
            // if the vault is undercollateralised, liquidate it
            require(_undercollateralised, "vault-not-undercollateralised");
            vault.liquidate();

            // revoke the minter and burner roles from the vault in euros token
            IEUROs(euros).revokeRole(
                IEUROs(euros).MINTER_ROLE(),
                address(vault)
            );
            IEUROs(euros).revokeRole(
                IEUROs(euros).BURNER_ROLE(),
                address(vault)
            );
            emit VaultLiquidated(address(vault));
        } catch {
            // if undercollateralised() reverts, revert with the error message
            revert("other-liquidation-error");
        }
    }

    // get the tokenURI for the given tokenId
    function tokenURI(
        uint256 _tokenId
    ) public view virtual override returns (string memory) {
        // get the vault status from the smart vault index
        ISmartVault.Status memory vaultStatus = ISmartVault(
            smartVaultIndex.getVaultAddress(_tokenId)
        ).status();

        // return the tokenURI generated by the nftMetadataGenerator
        return
            INFTMetadataGenerator(nftMetadataGenerator).generateNFTMetadata(
                _tokenId,
                vaultStatus
            );
    }

    // get the totalSupply of the smart vault manager NFT
    function totalSupply() external view returns (uint256) {
        return lastToken;
    }

    // set the MintFeeRate
    function setMintFeeRate(uint256 _rate) external onlyOwner {
        mintFeeRate = _rate;
    }

    // set the BurnFeeRate
    function setBurnFeeRate(uint256 _rate) external onlyOwner {
        burnFeeRate = _rate;
    }

    // set the SWapFeeRate
    function setSwapFeeRate(uint256 _rate) external onlyOwner {
        swapFeeRate = _rate;
    }

    // set the wethAddress
    function setWethAddress(address _weth) external onlyOwner {
        weth = _weth;
    }

    // set swapRouter2
    function setSwapRouter2(address _swapRouter) external onlyOwner {
        swapRouter2 = _swapRouter;
    }

    // set the metadata generator
    function setNFTMetadataGenerator(
        address _nftMetadataGenerator
    ) external onlyOwner {
        nftMetadataGenerator = _nftMetadataGenerator;
    }

    // set the smart vault Deployer
    function setSmartVaultDeployer(
        address _smartVaultDeployer
    ) external onlyOwner {
        smartVaultDeployer = _smartVaultDeployer;
    }

    // set the protocol address
    function setProtocolAddress(address _protocol) external onlyOwner {
        protocol = _protocol;
    }

    // set the liquidator address
    function setLiquidatorAddress(address _liquidator) external onlyOwner {
        liquidator = _liquidator;
    }

    // called during the token transfer
    // when the smart vault token is transferred from the from address to to address
    // transfer the tokenId from the smart vault index
    // transfer the ownership of the vault from the from address to the to address
    function _afterTokenTransfer(
        address _from,
        address _to,
        uint256 _tokenId,
        uint256
    ) internal override {
        smartVaultIndex.transferTokenId(_from, _to, _tokenId);
        if (address(_from) != address(0))
            ISmartVault(smartVaultIndex.getVaultAddress(_tokenId)).setOwner(
                _to
            );
        emit VaultTransferred(_tokenId, _from, _to);
    }

    // @audit should there be a _gap variable?
}
