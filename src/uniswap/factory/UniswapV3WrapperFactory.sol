// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {UniswapV3Wrapper} from "src/uniswap/UniswapV3Wrapper.sol";
import {BaseUniswapWrapperFactory} from "src/uniswap/factory/BaseUniswapWrapperFactory.sol";

/// @title Factory for creating Uniswap V3 wrappers
/// @author VII Finance
/// @notice For now, we won't support Uniswap V3 because it requires non trivial work to fix the bug found in the last audit
contract UniswapV3WrapperFactory is BaseUniswapWrapperFactory {
    address public immutable nonFungiblePositionManager;

    event UniswapV3WrapperCreated(
        address indexed uniswapV3Wrapper,
        address indexed fixedRateOracle,
        address indexed poolAddress,
        address oracle,
        address unitOfAccount
    );

    constructor(address _evc, address _nonFungiblePositionManager) BaseUniswapWrapperFactory(_evc) {
        nonFungiblePositionManager = _nonFungiblePositionManager;
    }

    function createUniswapV3Wrapper(address oracle, address unitOfAccount, address poolAddress)
        external
        returns (address uniswapV3Wrapper, address fixedRateOracle)
    {
        bytes32 wrapperSalt = _getWrapperSalt(oracle, unitOfAccount, poolAddress);

        uniswapV3Wrapper = address(
            new UniswapV3Wrapper{salt: wrapperSalt}(evc, nonFungiblePositionManager, oracle, unitOfAccount, poolAddress)
        );
        fixedRateOracle = _createFixedRateOracle(uniswapV3Wrapper, unitOfAccount);

        emit UniswapV3WrapperCreated(uniswapV3Wrapper, fixedRateOracle, poolAddress, oracle, unitOfAccount);
    }

    function _getWrapperSalt(address oracle, address unitOfAccount, address poolAddress)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(evc, nonFungiblePositionManager, oracle, unitOfAccount, poolAddress));
    }

    function getUniswapV3WrapperBytecode(address oracle, address unitOfAccount, address poolAddress)
        public
        view
        returns (bytes memory)
    {
        return abi.encodePacked(
            type(UniswapV3Wrapper).creationCode,
            abi.encode(evc, nonFungiblePositionManager, oracle, unitOfAccount, poolAddress)
        );
    }

    function getUniswapV3WrapperAddress(address oracle, address unitOfAccount, address poolAddress)
        public
        view
        returns (address)
    {
        return _computeCreate2Address(
            _getWrapperSalt(oracle, unitOfAccount, poolAddress),
            getUniswapV3WrapperBytecode(oracle, unitOfAccount, poolAddress)
        );
    }

    //check if uniswapV3Wrapper was created by this factory
    function isUniswapV3WrapperValid(UniswapV3Wrapper uniswapV3WrapperToCheck) external view returns (bool) {
        address expectedAddress = getUniswapV3WrapperAddress(
            address(uniswapV3WrapperToCheck.oracle()),
            uniswapV3WrapperToCheck.unitOfAccount(),
            address(uniswapV3WrapperToCheck.pool())
        );

        return expectedAddress == address(uniswapV3WrapperToCheck);
    }
}
