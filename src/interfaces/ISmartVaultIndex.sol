// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

interface ISmartVaultIndex {
    function getTokenIds(address _user) external view returns (uint[] memory);
    function getVaultAddress(uint _tokenId) external view returns (address payable);
    function addVaultAddress(uint _tokenId, address payable _vault) external;
    function transferTokenId(address _from, address _to, uint _tokenId) external;
}
