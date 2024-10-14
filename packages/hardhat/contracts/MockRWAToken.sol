// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import "@openzeppelin/contracts/access/Ownable.sol";

contract MockRWAToken is ERC721, Ownable {
    uint256 private _nextTokenId;

    constructor(address initialOwner) ERC721("MOCK RWA", "MRWA") Ownable(initialOwner) {}

    // minting function

    function safeMint(address to) public onlyOwner {

        uint256 tokenId = _nextTokenId++;

        _safeMint(to, tokenId);

        
    }
} //ffa