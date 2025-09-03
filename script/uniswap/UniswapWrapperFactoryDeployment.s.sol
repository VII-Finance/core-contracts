// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {UniswapV3WrapperFactory} from "src/uniswap/factory/UniswapV3WrapperFactory.sol";
import {UniswapV4WrapperFactory} from "src/uniswap/factory/UniswapV4WrapperFactory.sol";

contract UniswapWrapperFactoryDeploymentScript is Script {
    function computeAddress(address deployer, uint256 salt, bytes memory creationCodeWithArgs)
        internal
        pure
        returns (address hookAddress)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, keccak256(creationCodeWithArgs)))))
        );
    }

    function findVanitySalt(address deployer, bytes memory creationCode, bytes memory constructorArgs)
        internal
        pure
        returns (uint256 salt)
    {
        bytes memory creationCodeWithArgs = abi.encodePacked(creationCode, constructorArgs);
        // console.log("deployer", deployer);
        // console.logBytes32(keccak256(creationCodeWithArgs));

        for (uint256 i = 0; i < type(uint256).max; i++) {
            address computed = computeAddress(deployer, i, creationCodeWithArgs);
            bytes20 addrBytes = bytes20(computed);
            // Check for '7777' at start and '777' at end
            if (addrBytes[0] == 0x77) {
                // &&
                // addrBytes[1] == 0x77 &&
                // addrBytes[2] == 0x77 &&
                // addrBytes[3] == 0x77 &&
                // addrBytes[17] == 0x77 &&
                // addrBytes[18] == 0x77 &&
                // addrBytes[19] == 0x77

                return i;
            }
        }
        revert("No vanity salt found");
    }

    function run() external {
        address evc = vm.envAddress("EVC_ADDRESS");
        address nonFungiblePositionManager = vm.envAddress("UNISWAP_V3_POSITION_MANAGER");
        address v4PositionManager = vm.envAddress("UNISWAP_V4_POSITION_MANAGER");
        address weth = vm.envAddress("WETH_ADDRESS");

        // Find salts for vanity addresses
        uint256 v3Salt = findVanitySalt(
            CREATE2_FACTORY, type(UniswapV3WrapperFactory).creationCode, abi.encode(evc, nonFungiblePositionManager)
        );
        //@dev found it after running the same process separately. It doesn't work with foundry script because of out of gas errors
        v3Salt = 3575942761187587;

        uint256 v4Salt = findVanitySalt(
            CREATE2_FACTORY, type(UniswapV4WrapperFactory).creationCode, abi.encode(evc, v4PositionManager, weth)
        );
        v4Salt = 89803064614613559128942510503412517851878641377354393196606698967848670379431;

        vm.startBroadcast();

        new UniswapV3WrapperFactory{salt: bytes32(v3Salt)}(evc, nonFungiblePositionManager);

        new UniswapV4WrapperFactory{salt: bytes32(v4Salt)}(evc, v4PositionManager, weth);

        vm.stopBroadcast();
    }
}
