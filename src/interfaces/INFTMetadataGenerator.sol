// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import 'src/interfaces/ISmartVault.sol';

interface INFTMetadataGenerator {
    function generateNFTMetadata(
        uint _tokenId,
        ISmartVault.Status memory _vaultStatus
    )
        external
        view
        returns (string memory);
}
