// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

//RWA Oracle

contract RWAOracle is Ownable {
    constructor(address initialOwner) Ownable(initialOwner) {}

    mapping(uint256 => uint256) private rwaValues;

    event RWAValueUpdated(uint256 indexed tokenId, uint256 value);

    function updateRWAValue(
        uint256 _tokenId,
        uint256 _value
    ) external onlyOwner {
        rwaValues[_tokenId] = _value;
        emit RWAValueUpdated(_tokenId, _value);
    }

    function getRWAValue(uint256 _tokenId) external view returns (uint256) {
        return rwaValues[_tokenId];
    }
} //hhs