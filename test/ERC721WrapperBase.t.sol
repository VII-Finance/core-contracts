// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {ERC721WrapperBase} from "src/ERC721WrapperBase.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {ERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {ERC6909} from "lib/openzeppelin-contracts/contracts/token/ERC6909/draft-ERC6909.sol";

contract ERC721WrapperBaseMock is ERC721WrapperBase {
    constructor(address _evc, address _underlying, address _oracle, address _unitOfAccount)
        ERC721WrapperBase(_evc, _underlying, _oracle, _unitOfAccount)
    {}

    function getTokenIdToSkim() public view override returns (uint256) {}

    function validatePosition(uint256 tokenId) public view override {}
    function _unwrap(address to, uint256 tokenId, uint256, uint256 amount, bytes calldata extraData)
        internal
        override
    {}

    function _settleFullUnwrap(uint256 tokenId, address to) internal override {}

    function calculateValueOfTokenId(uint256, uint256 amount) public pure override returns (uint256) {
        return amount; // each tokenId is worth FULL_AMOUNT
    }
}

contract ERC721Mint is ERC721 {
    uint256 public tokenIdCounter;

    constructor() ERC721("ERC721Mint", "MINT") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

contract ERC721WrapperBaseTest is Test {
    ERC721WrapperBaseMock public wrapper;
    EthereumVaultConnector public evc = new EthereumVaultConnector();
    ERC721Mint public underlying = new ERC721Mint();

    address operator = makeAddr("operator");

    function setUp() public {
        wrapper = new ERC721WrapperBaseMock(address(evc), address(underlying), address(0), address(0));
    }

    function enableTokenIdAsCollateral(uint256 tokenId) public {
        uint256 totalTokenIdsEnabledBefore = wrapper.totalTokenIdsEnabledBy(address(this));
        //it should return TokenIdEnabled event
        vm.expectEmit();
        emit ERC721WrapperBase.TokenIdEnabled(address(this), tokenId, true);

        assertTrue(wrapper.enableTokenIdAsCollateral(tokenId));

        assertEq(wrapper.totalTokenIdsEnabledBy(address(this)), totalTokenIdsEnabledBefore + 1);
        assertEq(wrapper.tokenIdOfOwnerByIndex(address(this), totalTokenIdsEnabledBefore), tokenId);
    }

    function test_enableTokenIdAsCollateral(uint256 tokenId) public {
        enableTokenIdAsCollateral(tokenId);
    }

    function test_enableTokenIdAsCollateralReturnsFalseIfAlreadyAdded(uint256 tokenId) public {
        enableTokenIdAsCollateral(tokenId);

        //if tokenId is already enabled, it will return false
        assertFalse(wrapper.enableTokenIdAsCollateral(tokenId));
    }

    function test_max_allowed_token_ids() public {
        //enabling more than MAX_TOKENIDS_ALLOWED should revert
        for (uint256 i = 0; i < wrapper.MAX_TOKENIDS_ALLOWED(); i++) {
            uint256 tokenId = i;
            enableTokenIdAsCollateral(tokenId);
        }

        vm.expectRevert(ERC721WrapperBase.MaximumAllowedTokenIdsReached.selector);
        wrapper.enableTokenIdAsCollateral(1000);
    }

    function disableTokeIdsAsCollateral(uint256 tokenId) public {
        //returns false if it was never enabled
        assertFalse(wrapper.disableTokenIdAsCollateral(tokenId));
        enableTokenIdAsCollateral(tokenId);
        uint256 totalTokenIdsEnabledBefore = wrapper.totalTokenIdsEnabledBy(address(this));
        vm.expectEmit();

        emit ERC721WrapperBase.TokenIdEnabled(address(this), tokenId, false);

        assertTrue(wrapper.disableTokenIdAsCollateral(tokenId));
        assertEq(wrapper.totalTokenIdsEnabledBy(address(this)), totalTokenIdsEnabledBefore - 1);
    }

    function test_disableTokenIdAsCollateral(uint256 tokenId) public {
        disableTokeIdsAsCollateral(tokenId);
    }

    function wrap(uint256 tokenId, address to) public {
        underlying.mint(address(this), tokenId);
        underlying.approve(address(wrapper), tokenId);

        wrapper.wrap(tokenId, to);

        assertEq(underlying.ownerOf(tokenId), address(wrapper));
        assertEq(wrapper.balanceOf(to, tokenId), wrapper.FULL_AMOUNT());
    }

    function test_wrap(uint256 tokenId) public {
        wrap(tokenId, address(this));
    }

    function unwrap(uint256 tokenId, address from, address to) public {
        wrapper.unwrap(from, tokenId, to);

        assertEq(underlying.ownerOf(tokenId), to);
        assertEq(wrapper.balanceOf(from, tokenId), 0);
    }

    function test_unwrap(uint256 tokenId) public {
        wrap(tokenId, address(this));

        unwrap(tokenId, address(this), address(this));
    }

    function test_partialUnwrap(uint256 tokenId, uint256 unwrapAmount) public {
        wrap(tokenId, address(this));

        unwrapAmount = bound(unwrapAmount, 0, wrapper.FULL_AMOUNT());
        wrapper.unwrap(address(this), tokenId, address(this), unwrapAmount, "");

        assertEq(wrapper.balanceOf(address(this), tokenId), wrapper.FULL_AMOUNT() - unwrapAmount);
        assertEq(underlying.ownerOf(tokenId), address(wrapper));
    }

    function test_unwrapFrom(uint256 tokenId) public {
        wrap(tokenId, address(this));

        vm.startPrank(operator);
        // vm.expectRevert(abi.encodeWithSelector(ERC6909.ERC6909InsufficientAllowance.selector, 0, FULL_AMOUNT, tokenId));
        vm.expectPartialRevert(ERC6909.ERC6909InsufficientAllowance.selector);
        wrapper.unwrap(address(this), tokenId, operator);
        vm.stopPrank();
    }

    function test_balanceOf() public {
        wrap(1, address(this));
        wrap(2, address(this));

        wrapper.enableTokenIdAsCollateral(1);
        assertEq(wrapper.balanceOf(address(this)), wrapper.FULL_AMOUNT());

        uint256[] memory enabledTokenIds = wrapper.getEnabledTokenIds(address(this));
        assertEq(enabledTokenIds.length, 1);
        assertEq(enabledTokenIds[0], 1);

        wrapper.enableTokenIdAsCollateral(2);
        assertEq(wrapper.balanceOf(address(this)), 2 * wrapper.FULL_AMOUNT());

        enabledTokenIds = wrapper.getEnabledTokenIds(address(this));
        assertEq(enabledTokenIds.length, 2);
        assertEq(enabledTokenIds[0], 1);

        //if user splits tokenId then the balance should be be decreased as well
        assertTrue(wrapper.transfer(address(1), wrapper.FULL_AMOUNT()));
        assertEq(wrapper.balanceOf(address(this)), wrapper.FULL_AMOUNT());
    }
}
