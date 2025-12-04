// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Handler, TokenIdInfo} from "test/invariant/Handler.sol";
import {IEVault} from "lib/euler-vault-kit/src/EVault/IEVault.sol";
import {IMockUniswapWrapper} from "test/helpers/IMockUniswapWrapper.sol";

contract UniswapV4WrapperInvariants is Test {
    Handler public handler;

    function setUp() public {
        handler = new Handler();
        handler.setUp();

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = Handler.mintPositionAndWrap.selector;
        selectors[1] = Handler.transferWrappedTokenId.selector;
        selectors[2] = Handler.partialUnwrap.selector;
        selectors[3] = Handler.enableTokenIdAsCollateral.selector;
        selectors[4] = Handler.disableTokenIdAsCollateral.selector;
        selectors[5] = Handler.transferWithoutActiveLiquidation.selector;
        selectors[6] = Handler.borrowTokenA.selector;
        selectors[7] = Handler.borrowTokenB.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function getUniswapWrapper(bool isV3) internal view returns (IMockUniswapWrapper) {
        return isV3
            ? IMockUniswapWrapper(address(handler.uniswapV3Wrapper()))
            : IMockUniswapWrapper(address(handler.uniswapV4Wrapper()));
    }

    //make sure totalSupply of any tokenId is in uniswapV4Wrapper is not greater than FULL_AMOUNT
    function assertTotalSupplyNotGreaterThanFullAmount(bool isV3) public view {
        for (uint256 i = 0; i < handler.actorsLength(); i++) {
            address actor = handler.actors(i);
            //get all wrapped tokenIds
            uint256[] memory tokenIds = handler.getTokenIdsHeldByActor(actor, isV3);
            for (uint256 j = 0; j < tokenIds.length; j++) {
                uint256 tokenId = tokenIds[j];
                bool isWrapped = handler.isTokenIdWrapped(tokenId, isV3);
                if (!isWrapped) {
                    continue;
                }
                assertLe(getUniswapWrapper(isV3).totalSupply(tokenId), getUniswapWrapper(isV3).FULL_AMOUNT());
            }
        }
    }

    function invariant_totalSupplyNotGreaterThanFullAmount() public view {
        assertTotalSupplyNotGreaterThanFullAmount(true);
        assertTotalSupplyNotGreaterThanFullAmount(false);
    }

    function assertTotal6909SupplyEqualsSumOfBalances(bool isV3) public view {
        uint256[] memory allTokenIds = handler.getAllTokenIds(isV3);
        for (uint256 i = 0; i < allTokenIds.length; i++) {
            uint256 tokenId = allTokenIds[i];
            address[] memory users = handler.getUsersHoldingWrappedTokenId(tokenId, isV3);
            uint256 totalBalance;
            for (uint256 j = 0; j < users.length; j++) {
                address user = users[j];
                totalBalance += getUniswapWrapper(isV3).balanceOf(user, tokenId);
            }
            uint256 total6909Supply = getUniswapWrapper(isV3).totalSupply(tokenId);
            assertEq(totalBalance, total6909Supply, "Total 6909 supply does not equal sum of balances");
        }
    }

    function invariant_total6909SupplyEqualsSumOfBalances() public view {
        assertTotal6909SupplyEqualsSumOfBalances(true);
        assertTotal6909SupplyEqualsSumOfBalances(false);
    }

    function invariant_liquidity() public view {
        for (uint256 i = 0; i < handler.actorsLength(); i++) {
            address actor = handler.actors(i);

            address[] memory enabledControllers = handler.evc().getControllers(actor);
            if (enabledControllers.length == 0) return;

            IEVault vault = IEVault(enabledControllers[0]);
            if (vault.debtOf(actor) == 0) return;

            (uint256 collateralValue, uint256 liabilityValue) = vault.accountLiquidity(actor, false);

            assertLt(liabilityValue, collateralValue, "Liability value should be less than collateral value");
        }
    }
}
