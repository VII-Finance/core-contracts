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
import {UniswapPositionValueHelper} from "src/libraries/UniswapPositionValueHelper.sol";
import {console} from "forge-std/console.sol";

struct TokenIdInfo {
    bool isWrapped;
    mapping(address user => bool isEnabled) isEnabled;
    EnumerableSet.AddressSet holders;
}

contract Handler is Test, BaseSetup {
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;

    mapping(bool isV3 => EnumerableSet.UintSet) internal allTokenIds;

    mapping(address => mapping(bool isV3 => EnumerableSet.UintSet)) internal tokenIdsHeldByActor;
    mapping(uint256 tokenId => mapping(bool isV3 => TokenIdInfo)) internal tokenIdInfo;

    address[] public actors;

    address internal currentActor;

    IMockUniswapWrapper internal uniswapWrapper;

    //If this is false than turn on the fail on revert flag in foundry.toml as well
    //Turning this flag to false would mean that the fuzzer will be able to do it's more without a lot of restrictions
    //If it is true, then the fuzzer will be more constrained but the invariant tests will also work as "fuzz" tests
    bool internal constant FAIL_ON_REVERT = true;

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

    function getTokenIdsHeldByActor(address actor, bool isV3) public view returns (uint256[] memory tokenId) {
        return tokenIdsHeldByActor[actor][isV3].values();
    }

    function isTokenIdWrapped(uint256 tokenId, bool isV3) public view returns (bool isWrapped) {
        return tokenIdInfo[tokenId][isV3].isWrapped;
    }

    function getUsersHoldingWrappedTokenId(uint256 tokenId, bool isV3) public view returns (address[] memory users) {
        return tokenIdInfo[tokenId][isV3].holders.values();
    }

    function getAllTokenIdsLength(bool isV3) public view returns (uint256) {
        return allTokenIds[isV3].length();
    }

    function getAllTokenIds(bool isV3) public view returns (uint256[] memory) {
        return allTokenIds[isV3].values();
    }

    function mintPositionAndWrap(uint256 actorIndexSeed, bool isV3, LiquidityParams memory params)
        public
        useActor(actorIndexSeed)
        useUniswapWrapper(isV3)
    {
        (uint256 tokenIdMinted,,) = boundLiquidityParamsAndMint(currentActor, params, isV3);

        startHoax(currentActor);
        uniswapWrapper.underlying().approve(address(uniswapWrapper), tokenIdMinted);

        //randomly generate a receiver address
        address receiver = actors[bound(actorIndexSeed / 2, 0, actors.length - 1)];

        uint256 wrapperBalanceBefore = uniswapWrapper.balanceOf(receiver);
        uniswapWrapper.wrap(tokenIdMinted, receiver);

        //push the tokenId to the mapping
        tokenIdsHeldByActor[receiver][isV3].add(tokenIdMinted);
        tokenIdInfo[tokenIdMinted][isV3].isWrapped = true;
        allTokenIds[isV3].add(tokenIdMinted);
        tokenIdInfo[tokenIdMinted][isV3].holders.add(receiver);

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
    ) public useActor(actorIndexSeed) useUniswapWrapper(isV3) {
        uint256[] memory tokenIds = getTokenIdsHeldByActor(currentActor, isV3);
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

        {
            uint256 tokenIdValueBeforeTransfer =
                uniswapWrapper.calculateValueOfTokenId(tokenId, fromBalanceBeforeTransfer);

            uint256 expectTokenIdValueAfterTransfer =
                uniswapWrapper.calculateValueOfTokenId(tokenId, fromBalanceBeforeTransfer - transferAmount);

            //get the value of the tokenId
            uint256 tokenIdValueToTransfer = tokenIdValueBeforeTransfer - expectTokenIdValueAfterTransfer; //We are not calculating the amount directly to avoid miscalculation due to rounding error

            //if this tokenId is not enabled as collateral then the value being transferred is 0
            if (!tokenIdInfo[tokenId][isV3].isEnabled[currentActor]) {
                tokenIdValueToTransfer = 0;
            }

            bool shouldTransferFail =
                shouldNextActionFail(currentActor, tokenIdValueToTransfer, address(uniswapWrapper));

            if (shouldTransferFail && to != currentActor && FAIL_ON_REVERT) {
                vm.expectRevert();
            }

            uniswapWrapper.transfer(to, tokenId, transferAmount);

            if (shouldTransferFail) return; //if the transfer should fail, we can skip the rest of the assertions
        }
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
            tokenIdsHeldByActor[currentActor][isV3].remove(tokenId);
            tokenIdInfo[tokenId][isV3].holders.remove(currentActor);
        } else {
            //if the transfer amount is less than the full balance, we should not remove the tokenId from the mapping
            //but we should still add the receiver to the holders
            if (!tokenIdInfo[tokenId][isV3].holders.contains(to)) {
                tokenIdInfo[tokenId][isV3].holders.add(to);
            }
        }
        tokenIdsHeldByActor[to][isV3].add(tokenId);
        tokenIdInfo[tokenId][isV3].holders.add(to);
    }

    //given unwrap amount, the UniswapV3Wrapper will calculate the liquidity to be removed
    //if the liquidity to be removed is zero, call to the UniswapV3Pool will fails
    //even if liquidity to be removed is non-zero, it may still result in amount0 and amount1 being zero
    //which will make the collect call fail as well
    function isZeroLiquidityDecreased(uint256 tokenId, uint256 unwrapAmount, bool isV3) internal view returns (bool) {
        if (!isV3) return false;

        // in NonFungiblePositionManager, decrease liquidity fails if liquidity being removed is zero
        if (unwrapAmount == 0) {
            return true;
        }

        (,,,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) = nonFungiblePositionManager.positions(tokenId);
        uint128 liquidityToRemove =
            uint128(uniswapWrapper.proportionalShare(liquidity, unwrapAmount, uniswapWrapper.totalSupply(tokenId)));

        if (liquidityToRemove == 0) {
            return true;
        }

        // also make sure amount0 and amount1 resulting from liquidityToRemove is not zero either
        // call to collect it will fail otherwise
        (uint160 sqrtRatioX96,,,,,,) = uniswapV3Wrapper.pool().slot0();
        (uint256 amount0, uint256 amount1) =
            UniswapPositionValueHelper.principal(sqrtRatioX96, tickLower, tickUpper, liquidityToRemove);

        return (amount0 == 0 && amount1 == 0);
    }

    struct LocalVars {
        uint256[] tokenIds;
        uint256 tokenId;
        uint256 balanceBeforeUnwrap;
        uint256 tokenIdValueBeforeUnwrap;
        uint256 expectTokenIdValueAfterUnwrap;
        uint256 tokenIdValueToTransfer;
        bool shouldUnwrapFail;
        uint256 previewUnwrapAmount0;
        uint256 previewUnwrapAmount1;
        uint256 token0BalanceBeforeOfCurrentActor;
        uint256 token1BalanceBeforeOfCurrentActor;
    }

    function partialUnwrap(uint256 actorIndexSeed, bool isV3, uint256 tokenIdIndexSeed, uint256 unwrapAmount)
        public
        useActor(actorIndexSeed)
        useUniswapWrapper(isV3)
    {
        LocalVars memory local;

        local.tokenIds = getTokenIdsHeldByActor(currentActor, isV3);
        if (local.tokenIds.length == 0) {
            return; //skip if current actor has no tokenIds
        }
        local.tokenId = local.tokenIds[bound(tokenIdIndexSeed, 0, local.tokenIds.length - 1)];

        local.balanceBeforeUnwrap = uniswapWrapper.balanceOf(currentActor, local.tokenId);

        if (local.balanceBeforeUnwrap == 0) {
            return; //skip if current actor has no balance
        }

        unwrapAmount = bound(unwrapAmount, 0, local.balanceBeforeUnwrap);

        (local.previewUnwrapAmount0, local.previewUnwrapAmount1) =
            uniswapWrapper.previewUnwrap(local.tokenId, getCurrentPriceX96(isV3), unwrapAmount);

        local.token0BalanceBeforeOfCurrentActor = token0.balanceOf(currentActor);
        local.token1BalanceBeforeOfCurrentActor = token1.balanceOf(currentActor);

        local.tokenIdValueBeforeUnwrap =
            uniswapWrapper.calculateValueOfTokenId(local.tokenId, local.balanceBeforeUnwrap);

        local.expectTokenIdValueAfterUnwrap = uniswapWrapper.calculateExactedValueOfTokenIdAfterUnwrap(
            local.tokenId, unwrapAmount, local.balanceBeforeUnwrap
        );

        //get the value of the tokenId
        local.tokenIdValueToTransfer = local.tokenIdValueBeforeUnwrap - local.expectTokenIdValueAfterUnwrap; //We are not calculating the amount directly to avoid miscalculation due to rounding error

        //if this tokenId is not enabled as collateral then the value being transferred is 0
        if (!tokenIdInfo[local.tokenId][isV3].isEnabled[currentActor]) {
            local.tokenIdValueToTransfer = 0;
        }

        local.shouldUnwrapFail = shouldNextActionFail(
            currentActor, local.tokenIdValueToTransfer, address(uniswapWrapper)
        ) || isZeroLiquidityDecreased(local.tokenId, unwrapAmount, isV3);

        if (local.shouldUnwrapFail && FAIL_ON_REVERT) {
            vm.expectRevert();
        }

        uniswapWrapper.unwrap(currentActor, local.tokenId, currentActor, unwrapAmount, "");

        if (local.shouldUnwrapFail) return; //if the unwrap should fail, we can skip the rest of the assertions

        assertEq(
            token0.balanceOf(currentActor),
            local.token0BalanceBeforeOfCurrentActor + local.previewUnwrapAmount0,
            "uniswapWrapper: unwrap should increase token0 balance of currentActor"
        );
        assertEq(
            token1.balanceOf(currentActor),
            local.token1BalanceBeforeOfCurrentActor + local.previewUnwrapAmount1,
            "uniswapWrapper: unwrap should increase token1 balance of currentActor"
        );

        //We need to independently find out the amount user spent on the tokenId
        if (unwrapAmount == local.balanceBeforeUnwrap) {
            tokenIdsHeldByActor[currentActor][isV3].remove(local.tokenId);
            tokenIdInfo[local.tokenId][isV3].holders.remove(currentActor);
        }

        assertEq(
            uniswapWrapper.balanceOf(currentActor, local.tokenId),
            local.balanceBeforeUnwrap - unwrapAmount,
            "uniswapWrapper: partial unwrap should decrease balance of sender"
        );
    }

    function enableTokenIdAsCollateral(uint256 actorIndexSeed, bool isV3, uint256 tokenIdIndexSeed)
        public
        useActor(actorIndexSeed)
        useUniswapWrapper(isV3)
    {
        uint256[] memory tokenIds = getTokenIdsHeldByActor(currentActor, isV3);
        if (tokenIds.length == 0) {
            return; //skip if current actor has no tokenIds
        }
        uint256 tokenId = tokenIds[bound(tokenIdIndexSeed, 0, tokenIds.length - 1)];

        //if the tokenId is already enabled, we can skip
        if (tokenIdInfo[tokenId][isV3].isEnabled[currentActor]) {
            return;
        }

        tokenIdInfo[tokenId][isV3].isEnabled[currentActor] = true;

        uint256 enabledTokenIdsLengthBefore = uniswapWrapper.totalTokenIdsEnabledBy(currentActor);

        if (enabledTokenIdsLengthBefore == 7 && FAIL_ON_REVERT) vm.expectRevert(); //we know it is not allowed to enable more than 7 tokenIds

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
        useUniswapWrapper(isV3)
    {
        uint256[] memory tokenIds = getTokenIdsHeldByActor(currentActor, isV3);
        if (tokenIds.length == 0) {
            return; //skip if current actor has no tokenIds
        }
        uint256 tokenId = tokenIds[bound(tokenIdIndexSeed, 0, tokenIds.length - 1)];

        //if the tokenId is not enabled, we can skip
        if (!tokenIdInfo[tokenId][isV3].isEnabled[currentActor]) {
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

            if (shouldDisableTokenIdFail && FAIL_ON_REVERT) {
                vm.expectRevert();
            }
        }

        uniswapWrapper.disableTokenIdAsCollateral(tokenId);

        if (shouldDisableTokenIdFail) return; //if the disable should fail, we can skip the rest of the assertions

        tokenIdInfo[tokenId][isV3].isEnabled[currentActor] = false;

        assertEq(
            uniswapWrapper.totalTokenIdsEnabledBy(currentActor),
            enabledTokenIdsLengthBefore - 1,
            "uniswapWrapper: disableTokenIdAsCollateral should decrease total enabled tokenIds"
        );
    }

    struct LocalPrams {
        uint256[] tokenIds;
        uint256[] fromTokenIdBalancesBefore;
        uint256[] toTokenIdBalancesBefore;
        uint256[] transferAmounts;
    }

    function transferWithoutActiveLiquidation(
        uint256 actorIndexSeed,
        bool isV3,
        uint256 toIndexSeed,
        uint256 transferAmount
    ) public useActor(actorIndexSeed) useUniswapWrapper(isV3) {
        address to = actors[bound(toIndexSeed, 0, actors.length - 1)];

        uint256 fromBalanceBeforeTransfer = uniswapWrapper.balanceOf(currentActor);

        if (fromBalanceBeforeTransfer == 0) {
            return; //skip if current actor has no balance
        }

        transferAmount = bound(transferAmount, 0, fromBalanceBeforeTransfer);

        //we get all of the enabled tokenIds of the current actor
        LocalPrams memory localParams;
        localParams.tokenIds = getTokenIdsHeldByActor(currentActor, isV3);
        localParams.fromTokenIdBalancesBefore = new uint256[](localParams.tokenIds.length);
        localParams.toTokenIdBalancesBefore = new uint256[](localParams.tokenIds.length);
        localParams.transferAmounts = new uint256[](localParams.tokenIds.length);
        for (uint256 i = 0; i < localParams.tokenIds.length; i++) {
            localParams.fromTokenIdBalancesBefore[i] = uniswapWrapper.balanceOf(currentActor, localParams.tokenIds[i]);
            localParams.toTokenIdBalancesBefore[i] = uniswapWrapper.balanceOf(to, localParams.tokenIds[i]);

            if (tokenIdInfo[localParams.tokenIds[i]][isV3].isEnabled[currentActor] && currentActor != to) {
                //if the tokenId is enabled, we should proportionally reduce the balance
                localParams.transferAmounts[i] = Math.mulDiv(
                    localParams.fromTokenIdBalancesBefore[i],
                    transferAmount,
                    fromBalanceBeforeTransfer,
                    Math.Rounding.Ceil
                );
                vm.stopPrank();
                //we also enable this tokenId for the receiver as well to make sure transfer in terms of unit of account is the same as well
                vm.prank(to);
                uniswapWrapper.enableTokenIdAsCollateral(localParams.tokenIds[i]);

                vm.startPrank(currentActor);
            } else {
                //if the tokenId is not enabled, that tokenId transfer amount is 0
                localParams.transferAmounts[i] = 0;
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

                for (uint256 i = 0; i < localParams.tokenIds.length; i++) {
                    assertEq(
                        uniswapWrapper.balanceOf(currentActor, localParams.tokenIds[i]),
                        localParams.fromTokenIdBalancesBefore[i] - localParams.transferAmounts[i],
                        "uniswapWrapper: transferWithoutActiveLiquidation should proportionally reduce tokenId balances"
                    );
                    assertEq(
                        uniswapWrapper.balanceOf(to, localParams.tokenIds[i]),
                        localParams.toTokenIdBalancesBefore[i] + localParams.transferAmounts[i],
                        "uniswapWrapper: transferWithoutActiveLiquidation should proportionally increase tokenId balances"
                    );

                    if (localParams.transferAmounts[i] > 0 && currentActor != to) {
                        tokenIdsHeldByActor[to][isV3].add(localParams.tokenIds[i]);
                        tokenIdInfo[localParams.tokenIds[i]][isV3].holders.add(to);
                    }
                }
            }
        } catch {
            // If revert, do nothing (expected for some cases)
        }

        for (uint256 i = 0; i < localParams.tokenIds.length; i++) {
            //we make the enabled tokenIds for the receiver to disabled to make sure no change really happened in the state
            //we only did this earlier to make sure the transfer in terms of unit of account is the same
            if (!tokenIdInfo[localParams.tokenIds[i]][isV3].isEnabled[to]) {
                vm.stopPrank();
                vm.prank(to);
                uniswapWrapper.disableTokenIdAsCollateral(localParams.tokenIds[i]);

                vm.startPrank(currentActor);
            }
        }
    }

    function borrowUpToMax(address account, IEVault vault, uint256 borrowAmount) internal returns (uint256) {
        uint256 maxBorrowAmount = getMaxBorrowAmount(account, vault);

        if (maxBorrowAmount < 10) return 0; //skip if max borrow amount is too small

        maxBorrowAmount = bound(maxBorrowAmount, 0, type(uint104).max); //avoid amount too large to encode error in euler vaults

        borrowAmount = bound(borrowAmount, 0, maxBorrowAmount);

        //mint borrowAmount + 1 to the vault to make sure currentAccount have enough liquidity to borrow
        TestERC20(vault.asset()).mint(address(vault), borrowAmount + 1);
        vault.skim(type(uint256).max, account);

        address[] memory enabledControllers = evc.getControllers(account);

        //If there are no enabled controllers, we enable the vault and collaterals first and then borrow
        if (enabledControllers.length == 0) {
            evc.enableController(account, address(vault));
            evc.enableCollateral(account, address(uniswapV3Wrapper));
            evc.enableCollateral(account, address(uniswapV4Wrapper));
            vault.borrow(borrowAmount, account);
            return borrowAmount;
        }
        // borrow only if the vault is already enabled as controller
        // if not, we skip the borrow to avoid revert
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

    function borrowTokenA(uint256 actorIndexSeed, uint256 borrowAmount) public useActor(actorIndexSeed) {
        borrowUpToMax(currentActor, eTokenAVault, borrowAmount);
    }

    function borrowTokenB(uint256 actorIndexSeed, uint256 borrowAmount) public useActor(actorIndexSeed) {
        borrowUpToMax(currentActor, eTokenBVault, borrowAmount);
    }
}
