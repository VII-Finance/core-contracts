// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

// forge-std
import {Test} from "forge-std/Test.sol";

import {Constants} from "lib/v4-periphery/lib/v4-core/test/utils/Constants.sol";
import {
    PositionManager,
    IAllowanceTransfer,
    IPositionDescriptor,
    IWETH9
} from "lib/v4-periphery/src/PositionManager.sol";

import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";

import {GenericFactory} from "lib/euler-vault-kit/src/GenericFactory/GenericFactory.sol";
import {EVault} from "lib/euler-vault-kit/src/EVault/EVault.sol";
import {BalanceForwarder} from "lib/euler-vault-kit/src/EVault/modules/BalanceForwarder.sol";
import {Borrowing} from "lib/euler-vault-kit/src/EVault/modules/Borrowing.sol";
import {Governance} from "lib/euler-vault-kit/src/EVault/modules/Governance.sol";
import {Initialize} from "lib/euler-vault-kit/src/EVault/modules/Initialize.sol";
import {Liquidation} from "lib/euler-vault-kit/src/EVault/modules/Liquidation.sol";
import {RiskManager} from "lib/euler-vault-kit/src/EVault/modules/RiskManager.sol";
import {Token} from "lib/euler-vault-kit/src/EVault/modules/Token.sol";
import {Vault} from "lib/euler-vault-kit/src/EVault/modules/Vault.sol";
import {Base} from "lib/euler-vault-kit/src/EVault/shared/Base.sol";
import {Dispatch} from "lib/euler-vault-kit/src/EVault/Dispatch.sol";
import {ProtocolConfig} from "lib/euler-vault-kit/src/ProtocolConfig/ProtocolConfig.sol";
import {SequenceRegistry} from "lib/euler-vault-kit/src/SequenceRegistry/SequenceRegistry.sol";
import {IEVault} from "lib/euler-vault-kit/src/EVault/IEVault.sol";

import {MockPriceOracle} from "lib/euler-vault-kit/test/mocks/MockPriceOracle.sol";
import {MockBalanceTracker} from "lib/euler-vault-kit/test/mocks/MockBalanceTracker.sol";
import {TestERC20} from "lib/euler-vault-kit/test/mocks/TestERC20.sol";
import {IRMTestDefault} from "lib/euler-vault-kit/test/mocks/IRMTestDefault.sol";

import {UniswapV4WrapperFactory} from "src/uniswap/factory/UniswapV4WrapperFactory.sol";
import {UniswapV4Wrapper} from "src/uniswap/UniswapV4Wrapper.sol";

import {BaseSetup} from "test/invariant/BaseSetup.sol";
import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IMockUniswapWrapper} from "test/helpers/IMockUniswapWrapper.sol";
import {console} from "forge-std/console.sol";

struct TokenIdInfo {
    bool isWrapped;
    mapping(address user => bool isEnabled) isEnabled;
    EnumerableSet.AddressSet holders;
}

contract Handler is Test, BaseSetup {
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.UintSet internal allTokenIds;

    mapping(address => EnumerableSet.UintSet tokenIds) internal tokenIdsHeldByActor;
    mapping(uint256 tokenId => TokenIdInfo) internal tokenIdInfo;

    address[] public actors;

    address internal currentActor;

    IMockUniswapWrapper internal uniswapWrapper;

    modifier useActor(uint256 actorIndexSeed) {
        currentActor = actors[bound(actorIndexSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    modifier useUniswapWrapper(bool isV3) {
        uniswapWrapper =
            isV3 ? IMockUniswapWrapper(address(uniswapV3Wrapper)) : IMockUniswapWrapper(address(uniswapV4Wrapper));
        _;
    }

    function setUp() public override {
        BaseSetup.setUp();

        for (uint256 i = 0; i < 10; i++) {
            address actor = makeAddr(string(abi.encodePacked("Actor ", i)));
            actors.push(actor);
            vm.label(actor, string(abi.encodePacked("Actor ", i)));
        }
    }

    function actorsLength() public view returns (uint256) {
        return actors.length;
    }

    function getTokenIdsHeldByActor(address actor) public view returns (uint256[] memory tokenId) {
        return tokenIdsHeldByActor[actor].values();
    }

    function isTokenIdWrapped(uint256 tokenId) public view returns (bool isWrapped) {
        return tokenIdInfo[tokenId].isWrapped;
    }

    function getUsersHoldingWrappedTokenId(uint256 tokenId) public view returns (address[] memory users) {
        return tokenIdInfo[tokenId].holders.values();
    }

    function getAllTokenIdsLength() public view returns (uint256) {
        return allTokenIds.length();
    }

    function getAllTokenIds() public view returns (uint256[] memory) {
        return allTokenIds.values();
    }

    function mintPositionAndWrap(uint256 actorIndexSeed, bool isV3, LiquidityParams memory params)
        public
        useActor(actorIndexSeed)
        useUniswapWrapper(false)
    {
        (uint256 tokenIdMinted,,) = boundLiquidityParamsAndMint(currentActor, params, false);

        startHoax(currentActor);
        positionManager.approve(address(uniswapWrapper), tokenIdMinted);

        //randomly generate a receiver address
        address receiver = actors[bound(actorIndexSeed / 2, 0, actors.length - 1)];

        uint256 wrapperBalanceBefore = uniswapWrapper.balanceOf(receiver);
        uniswapWrapper.wrap(tokenIdMinted, receiver);

        //push the tokenId to the mapping
        tokenIdsHeldByActor[receiver].add(tokenIdMinted);
        tokenIdInfo[tokenIdMinted].isWrapped = true;
        allTokenIds.add(tokenIdMinted);
        tokenIdInfo[tokenIdMinted].holders.add(receiver);

        assertEq(
            uniswapWrapper.balanceOf(receiver),
            wrapperBalanceBefore,
            "uniswapWrapper: wrap should not increase balance of receiver"
        );
        assertEq(
            uniswapWrapper.balanceOf(receiver, tokenIdMinted),
            uniswapWrapper.FULL_AMOUNT(),
            "uniswapWrapper: wrap should mint FULL_AMOUNT of ERC6909 tokens"
        );
    }

    function shouldNextActionFail(address account, uint256 valueToBeTransferred, address collateral)
        internal
        view
        returns (bool)
    {
        address[] memory enabledControllers = evc.getControllers(account);
        if (enabledControllers.length == 0) return false;

        IEVault vault = IEVault(enabledControllers[0]);
        if (vault.debtOf(account) == 0) return false;

        //get account liquidity
        address[] memory collaterals = evc.getCollaterals(account);

        //get user balance of collaterals
        uint256 totalCollateralValueAfterTransfer = 0;
        for (uint256 i = 0; i < collaterals.length; i++) {
            uint256 balance = IEVault(collaterals[i]).balanceOf(account);
            uint256 collateralValue = oracle.getQuote(balance, collaterals[i], unitOfAccount);

            if (collaterals[i] == collateral) {
                if (collateralValue < valueToBeTransferred) {
                    return true; //if the collateral value is less than the value to be transferred, the action should fail
                }
                collateralValue -= valueToBeTransferred;
            }
            uint256 LTVLiquidation = vault.LTVLiquidation(collaterals[i]);
            collateralValue = collateralValue * LTVLiquidation / 1e4;

            totalCollateralValueAfterTransfer += collateralValue;
        }

        //get user liability value
        (, uint256 liabilityValue) = vault.accountLiquidity(account, false);

        if (totalCollateralValueAfterTransfer <= liabilityValue) {
            return true; //if the total collateral value after transfer is less than the liability value, the action should fail
        }

        return false;
    }

    function transferWrappedTokenId(
        uint256 actorIndexSeed,
        bool isV3,
        uint256 toIndexSeed,
        uint256 tokenIdIndexSeed,
        uint256 transferAmount
    ) public useActor(actorIndexSeed) useUniswapWrapper(false) {
        uint256[] memory tokenIds = getTokenIdsHeldByActor(currentActor);
        if (tokenIds.length == 0) {
            return; //skip if current actor has no tokenIds
        }
        uint256 tokenId = tokenIds[bound(tokenIdIndexSeed, 0, tokenIds.length - 1)];
        address to = actors[bound(toIndexSeed, 0, actors.length - 1)];

        uint256 fromBalanceBeforeTransfer = uniswapWrapper.balanceOf(currentActor, tokenId);
        uint256 toBalanceBeforeTransfer = uniswapWrapper.balanceOf(to, tokenId);

        if (fromBalanceBeforeTransfer == 0) {
            return; //skip if transfer amount is 0
        }

        transferAmount = bound(transferAmount, 0, fromBalanceBeforeTransfer);

        uint256 tokenIdValueBeforeTransfer = uniswapWrapper.calculateValueOfTokenId(tokenId, fromBalanceBeforeTransfer);

        uint256 expectTokenIdValueAfterTransfer =
            uniswapWrapper.calculateValueOfTokenId(tokenId, fromBalanceBeforeTransfer - transferAmount);

        //get the value of the tokenId
        uint256 tokenIdValueToTransfer = tokenIdValueBeforeTransfer - expectTokenIdValueAfterTransfer; //We are not calculating the amount directly to avoid miscalculation due to rounding error

        //if this tokenId is not enabled as collateral then the value being transferred is 0
        if (!tokenIdInfo[tokenId].isEnabled[currentActor]) {
            tokenIdValueToTransfer = 0;
        }

        bool shouldTransferFail = shouldNextActionFail(currentActor, tokenIdValueToTransfer, address(uniswapWrapper));

        if (shouldTransferFail && to != currentActor) {
            vm.expectRevert();
        }

        uniswapWrapper.transfer(to, tokenId, transferAmount);

        if (shouldTransferFail) return; //if the transfer should fail, we can skip the rest of the assertions
        //if transfer to self then we make sure the balance does not change
        if (to == currentActor) {
            assertEq(
                uniswapWrapper.balanceOf(currentActor, tokenId),
                fromBalanceBeforeTransfer,
                "uniswapWrapper: transfer to self should not change balance"
            );
            return; //skip the rest
        }
        assertEq(
            uniswapWrapper.balanceOf(currentActor, tokenId),
            fromBalanceBeforeTransfer - transferAmount,
            "uniswapWrapper: transfer should decrease balance of sender"
        );
        assertEq(
            uniswapWrapper.balanceOf(to, tokenId),
            toBalanceBeforeTransfer + transferAmount,
            "uniswapWrapper: transfer should increase balance of receiver"
        );

        if (transferAmount == fromBalanceBeforeTransfer) {
            tokenIdsHeldByActor[currentActor].remove(tokenId);
            tokenIdInfo[tokenId].holders.remove(currentActor);
        } else {
            //if the transfer amount is less than the full balance, we should not remove the tokenId from the mapping
            //but we should still add the receiver to the holders
            if (!tokenIdInfo[tokenId].holders.contains(to)) {
                tokenIdInfo[tokenId].holders.add(to);
            }
        }
        tokenIdsHeldByActor[to].add(tokenId);
        tokenIdInfo[tokenId].holders.add(to);
    }

    function partialUnwrap(uint256 actorIndexSeed, bool isV3, uint256 tokenIdIndexSeed, uint256 unwrapAmount)
        public
        useActor(actorIndexSeed)
        useUniswapWrapper(false)
    {
        uint256[] memory tokenIds = getTokenIdsHeldByActor(currentActor);
        if (tokenIds.length == 0) {
            return; //skip if current actor has no tokenIds
        }
        uint256 tokenId = tokenIds[bound(tokenIdIndexSeed, 0, tokenIds.length - 1)];

        uint256 balanceBeforeUnwrap = uniswapWrapper.balanceOf(currentActor, tokenId);

        if (balanceBeforeUnwrap == 0) {
            return; //skip if current actor has no balance
        }

        unwrapAmount = bound(unwrapAmount, 0, balanceBeforeUnwrap);

        uint256 tokenIdValueBeforeUnwrap = uniswapWrapper.calculateValueOfTokenId(tokenId, balanceBeforeUnwrap);

        uint256 expectTokenIdValueAfterUnwrap =
            uniswapWrapper.calculateExactedValueOfTokenIdAfterUnwrap(tokenId, unwrapAmount, balanceBeforeUnwrap);

        //get the value of the tokenId
        uint256 tokenIdValueToTransfer = tokenIdValueBeforeUnwrap - expectTokenIdValueAfterUnwrap; //We are not calculating the amount directly to avoid miscalculation due to rounding error

        //if this tokenId is not enabled as collateral then the value being transferred is 0
        if (!tokenIdInfo[tokenId].isEnabled[currentActor]) {
            tokenIdValueToTransfer = 0;
        }

        bool shouldUnwrapFail = shouldNextActionFail(currentActor, tokenIdValueToTransfer, address(uniswapWrapper));

        if (shouldUnwrapFail) {
            vm.expectRevert();
        }

        uniswapWrapper.unwrap(currentActor, tokenId, currentActor, unwrapAmount, "");

        if (shouldUnwrapFail) return; //if the unwrap should fail, we can skip the rest of the assertions

        //We need to independently find out the amount user spent on the tokenId
        if (unwrapAmount == balanceBeforeUnwrap) {
            tokenIdsHeldByActor[currentActor].remove(tokenId);
            tokenIdInfo[tokenId].holders.remove(currentActor);
        }

        assertEq(
            uniswapWrapper.balanceOf(currentActor, tokenId),
            balanceBeforeUnwrap - unwrapAmount,
            "uniswapWrapper: partial unwrap should decrease balance of sender"
        );
    }

    function enableTokenIdAsCollateral(uint256 actorIndexSeed, bool isV3, uint256 tokenIdIndexSeed)
        public
        useActor(actorIndexSeed)
        useUniswapWrapper(false)
    {
        uint256[] memory tokenIds = getTokenIdsHeldByActor(currentActor);
        if (tokenIds.length == 0) {
            return; //skip if current actor has no tokenIds
        }
        uint256 tokenId = tokenIds[bound(tokenIdIndexSeed, 0, tokenIds.length - 1)];

        //if the tokenId is already enabled, we can skip
        if (tokenIdInfo[tokenId].isEnabled[currentActor]) {
            return;
        }

        tokenIdInfo[tokenId].isEnabled[currentActor] = true;

        uint256 enabledTokenIdsLengthBefore = uniswapWrapper.totalTokenIdsEnabledBy(currentActor);

        if (enabledTokenIdsLengthBefore == 7) vm.expectRevert(); //we know it is not allowed to enable more than 7 tokenIds

        uniswapWrapper.enableTokenIdAsCollateral(tokenId);

        if (enabledTokenIdsLengthBefore == 7) return; //if it reverted, we can skip the assertions

        assertEq(
            uniswapWrapper.totalTokenIdsEnabledBy(currentActor),
            enabledTokenIdsLengthBefore + 1,
            "uniswapWrapper: enableTokenIdAsCollateral should increase total enabled tokenIds"
        );
        assertEq(
            uniswapWrapper.tokenIdOfOwnerByIndex(currentActor, enabledTokenIdsLengthBefore),
            tokenId,
            "UniswapWrapper: tokenIdOfOwnerByIndex should return the correct tokenId"
        );
    }

    function disableTokenIdAsCollateral(uint256 actorIndexSeed, bool isV3, uint256 tokenIdIndexSeed)
        public
        useActor(actorIndexSeed)
        useUniswapWrapper(false)
    {
        uint256[] memory tokenIds = getTokenIdsHeldByActor(currentActor);
        if (tokenIds.length == 0) {
            return; //skip if current actor has no tokenIds
        }
        uint256 tokenId = tokenIds[bound(tokenIdIndexSeed, 0, tokenIds.length - 1)];

        //if the tokenId is not enabled, we can skip
        if (!tokenIdInfo[tokenId].isEnabled[currentActor]) {
            return;
        }
        uint256 enabledTokenIdsLengthBefore = uniswapWrapper.totalTokenIdsEnabledBy(currentActor);

        uint256 tokenIdBalanceBefore = uniswapWrapper.balanceOf(currentActor, tokenId);

        bool shouldDisableTokenIdFail;
        if (tokenIdBalanceBefore != 0) {
            shouldDisableTokenIdFail = shouldNextActionFail(
                currentActor,
                uniswapWrapper.calculateValueOfTokenId(tokenId, tokenIdBalanceBefore),
                address(uniswapWrapper)
            );

            if (shouldDisableTokenIdFail) {
                vm.expectRevert();
            }
        }

        uniswapWrapper.disableTokenIdAsCollateral(tokenId);

        if (shouldDisableTokenIdFail) return; //if the disable should fail, we can skip the rest of the assertions

        tokenIdInfo[tokenId].isEnabled[currentActor] = false;

        assertEq(
            uniswapWrapper.totalTokenIdsEnabledBy(currentActor),
            enabledTokenIdsLengthBefore - 1,
            "uniswapWrapper: disableTokenIdAsCollateral should decrease total enabled tokenIds"
        );
    }

    function transferWithoutActiveLiquidation(
        uint256 actorIndexSeed,
        bool isV3,
        uint256 toIndexSeed,
        uint256 transferAmount
    ) public useActor(actorIndexSeed) useUniswapWrapper(false) {
        address to = actors[bound(toIndexSeed, 0, actors.length - 1)];

        uint256 fromBalanceBeforeTransfer = uniswapWrapper.balanceOf(currentActor);

        if (fromBalanceBeforeTransfer == 0) {
            return; //skip if current actor has no balance
        }

        transferAmount = bound(transferAmount, 0, fromBalanceBeforeTransfer);

        //we get all of the enabled tokenIds of the current actor
        uint256[] memory tokenIds = getTokenIdsHeldByActor(currentActor);
        uint256[] memory fromTokenIdBalancesBefore = new uint256[](tokenIds.length);
        uint256[] memory toTokenIdBalancesBefore = new uint256[](tokenIds.length);
        uint256[] memory transferAmounts = new uint256[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            fromTokenIdBalancesBefore[i] = uniswapWrapper.balanceOf(currentActor, tokenIds[i]);
            toTokenIdBalancesBefore[i] = uniswapWrapper.balanceOf(to, tokenIds[i]);

            if (tokenIdInfo[tokenIds[i]].isEnabled[currentActor] && currentActor != to) {
                //if the tokenId is enabled, we should proportionally reduce the balance
                transferAmounts[i] = Math.mulDiv(
                    fromTokenIdBalancesBefore[i], transferAmount, fromBalanceBeforeTransfer, Math.Rounding.Ceil
                );
                vm.stopPrank();
                //we also enable this tokenId for the receiver as well to make sure transfer in terms of unit of account is the same as well
                vm.prank(to);
                uniswapWrapper.enableTokenIdAsCollateral(tokenIds[i]);

                vm.startPrank(currentActor);
            } else {
                //if the tokenId is not enabled, that tokenId transfer amount is 0
                transferAmounts[i] = 0;
            }
        }

        uint256 toBalanceBeforeTransfer = uniswapWrapper.balanceOf(to);

        try uniswapWrapper.transfer(to, transferAmount) {
            if (currentActor != to) {
                //TODO: why is there 1 wei of error here?
                assertLe(
                    uniswapWrapper.balanceOf(currentActor),
                    fromBalanceBeforeTransfer - transferAmount + 2,
                    "uniswapWrapper: transferWithoutActiveLiquidation should decrease balance of sender"
                );
                assertGe(
                    uniswapWrapper.balanceOf(to) + 2,
                    toBalanceBeforeTransfer + transferAmount,
                    "uniswapWrapper: transferWithoutActiveLiquidation should increase balance of receiver"
                );

                for (uint256 i = 0; i < tokenIds.length; i++) {
                    assertEq(
                        uniswapWrapper.balanceOf(currentActor, tokenIds[i]),
                        fromTokenIdBalancesBefore[i] - transferAmounts[i],
                        "uniswapWrapper: transferWithoutActiveLiquidation should proportionally reduce tokenId balances"
                    );
                    assertEq(
                        uniswapWrapper.balanceOf(to, tokenIds[i]),
                        toTokenIdBalancesBefore[i] + transferAmounts[i],
                        "uniswapWrapper: transferWithoutActiveLiquidation should proportionally increase tokenId balances"
                    );

                    if (transferAmounts[i] > 0 && currentActor != to) {
                        tokenIdsHeldByActor[to].add(tokenIds[i]);
                        tokenIdInfo[tokenIds[i]].holders.add(to);
                    }
                }
            }
        } catch {
            // If revert, do nothing (expected for some cases)
        }

        for (uint256 i = 0; i < tokenIds.length; i++) {
            //we make the enabled tokenIds for the receiver to disabled to make sure no change really happened in the state
            //we only did this earlier to make sure the transfer in terms of unit of account is the same
            if (!tokenIdInfo[tokenIds[i]].isEnabled[to]) {
                vm.stopPrank();
                vm.prank(to);
                uniswapWrapper.disableTokenIdAsCollateral(tokenIds[i]);

                vm.startPrank(currentActor);
            }
        }
    }

    function borrowUpToMax(address account, IEVault vault, uint256 borrowAmount) internal returns (uint256) {
        uint256 maxBorrowAmount = getMaxBorrowAmount(account, vault);

        maxBorrowAmount = bound(maxBorrowAmount, 0, type(uint104).max); //avoid amount too large to encode error in euler vaults

        borrowAmount = bound(borrowAmount, 0, maxBorrowAmount);

        //mint borrowAmount + 1 to the vault to make sure currentAccount have enough liquidity to borrow
        TestERC20(vault.asset()).mint(address(vault), borrowAmount + 1);
        vault.skim(type(uint256).max, account);

        address[] memory enabledControllers = evc.getControllers(account);

        if (enabledControllers.length == 0) {
            evc.enableController(account, address(vault));
            evc.enableCollateral(account, address(uniswapWrapper));
            vault.borrow(borrowAmount, account);
            return borrowAmount;
        }

        if (enabledControllers[0] == address(vault)) {
            vault.borrow(borrowAmount, account);
            return borrowAmount;
        }

        return 0;
    }

    function getMaxBorrowAmount(address account, IEVault vault) internal view returns (uint256 maxBorrowAmount) {
        uint256 remainingCollateralValue = uniswapV3Wrapper.balanceOf(account) + uniswapV4Wrapper.balanceOf(account);

        //if user has already borrowed from this vault, we deduct the liability from the collateral value
        if (vault.debtOf(account) != 0) {
            (uint256 collateralValue, uint256 liabilityValue) = vault.accountLiquidity(account, false);
            remainingCollateralValue = collateralValue - liabilityValue;
        }

        uint256 LTVBorrow = vault.LTVBorrow(address(uniswapWrapper));
        uint256 maxBorrowAmountInUOA = (remainingCollateralValue) * LTVBorrow / 1e4;
        uint256 oneTokenValueInUOA = oracle.getQuote(1e18, vault.asset(), unitOfAccount);

        maxBorrowAmount = maxBorrowAmountInUOA * 1e18 / (oneTokenValueInUOA + 1); // add +1 to the price to make sure it's not the exact maxBorrowAmount. It fails if LTV is exactly equal to LTVBorrow as well
    }

    function borrowTokenA(uint256 actorIndexSeed, bool isV3, uint256 borrowAmount)
        public
        useActor(actorIndexSeed)
        useUniswapWrapper(false)
    {
        borrowUpToMax(currentActor, eTokenAVault, borrowAmount);
    }

    function borrowTokenB(uint256 actorIndexSeed, bool isV3, uint256 borrowAmount)
        public
        useActor(actorIndexSeed)
        useUniswapWrapper(false)
    {
        borrowUpToMax(currentActor, eTokenBVault, borrowAmount);
    }
}
