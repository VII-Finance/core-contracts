// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {FixedRateOracle} from "lib/euler-price-oracle/src/adapter/fixed/FixedRateOracle.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721WrapperBase} from "src/interfaces/IERC721WrapperBase.sol";

abstract contract BaseUniswapWrapperFactory {
    address public immutable evc;

    constructor(address _evc) {
        evc = _evc;
    }

    function _getDecimals(address token) internal view returns (uint8) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        return success && data.length == 32 ? abi.decode(data, (uint8)) : 18;
    }

    function _getFixedRateOracleSalt(address uniswapWrapper, address unitOfAccount) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(uniswapWrapper, unitOfAccount));
    }

    function _computeCreate2Address(bytes32 salt, bytes memory bytecode) internal view returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode)));
        return address(uint160(uint256(hash)));
    }

    function getFixedRateOracleBytecode(address uniswapWrapper, address unitOfAccount)
        public
        view
        returns (bytes memory)
    {
        uint256 unit = 10 ** _getDecimals(unitOfAccount); // {unit} = 10**decimals of unitOfAccount; 1:1 oracle scale factor
        bytes memory bytecode = type(FixedRateOracle).creationCode;
        return abi.encodePacked(bytecode, abi.encode(uniswapWrapper, unitOfAccount, unit));
    }

    function getFixedRateOracleAddress(address uniswapWrapper, address unitOfAccount) public view returns (address) {
        bytes32 fixedRateOracleSalt = _getFixedRateOracleSalt(uniswapWrapper, unitOfAccount);
        bytes memory bytecode = getFixedRateOracleBytecode(uniswapWrapper, unitOfAccount);
        return _computeCreate2Address(fixedRateOracleSalt, bytecode);
    }

    function getFixedRateOracleAddress(address uniswapWrapper) public view returns (address) {
        address unitOfAccount = IERC721WrapperBase(uniswapWrapper).unitOfAccount();
        return getFixedRateOracleAddress(uniswapWrapper, unitOfAccount);
    }

    function isFixedRateOracleValid(address fixedRateOracleToCheck) external view returns (bool) {
        address expectedAddress = getFixedRateOracleAddress(FixedRateOracle(fixedRateOracleToCheck).base());
        return expectedAddress == fixedRateOracleToCheck;
    }

    function _createFixedRateOracle(address uniswapWrapper, address unitOfAccount) internal returns (address) {
        uint256 unit = 10 ** _getDecimals(unitOfAccount); // {unit} = 10**decimals of unitOfAccount; 1:1 oracle scale factor
        bytes32 fixedRateOracleSalt = _getFixedRateOracleSalt(uniswapWrapper, unitOfAccount);
        return address(new FixedRateOracle{salt: fixedRateOracleSalt}(uniswapWrapper, unitOfAccount, unit));
    }
}
