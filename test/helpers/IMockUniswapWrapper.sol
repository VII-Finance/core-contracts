// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IERC721WrapperBase} from "src/interfaces/IERC721WrapperBase.sol";
import {IERC6909TokenSupply} from "lib/openzeppelin-contracts/contracts/interfaces/draft-IERC6909.sol";

interface IMockUniswapWrapper is IERC721WrapperBase, IERC6909TokenSupply {
    function syncFeesOwned(uint256 tokenId) external returns (uint256 actualFees0, uint256 actualFees1);

    function pendingFees(uint256 tokenId) external view returns (uint256 fees0Owed, uint256 fees1Owed);

    function total(uint256 tokenId) external view returns (uint256 amount0Total, uint256 amount1Total);

    function calculateExactedValueOfTokenIdAfterUnwrap(
        uint256 tokenId,
        uint256 unwrapAmount,
        uint256 balanceBeforeUnwrap
    ) external view returns (uint256);

    function getSqrtRatioX96(address, address, uint256, uint256) external view returns (uint160 sqrtRatioX96);

    function getSqrtRatioX96FromOracle(address token0, address token1, uint256 unit0, uint256 unit1)
        external
        view
        returns (uint160 sqrtRatioX96);
}
