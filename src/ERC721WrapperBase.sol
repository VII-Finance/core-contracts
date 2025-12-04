// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC6909, ERC6909} from "lib/openzeppelin-contracts/contracts/token/ERC6909/ERC6909.sol";
import {
    ERC6909TokenSupply
} from "lib/openzeppelin-contracts/contracts/token/ERC6909/extensions/ERC6909TokenSupply.sol";
import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {Context} from "lib/openzeppelin-contracts/contracts/utils/Context.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {EVCUtil} from "ethereum-vault-connector/utils/EVCUtil.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {IERC721WrapperBase} from "src/interfaces/IERC721WrapperBase.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "lib/v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";

abstract contract ERC721WrapperBase is ERC6909TokenSupply, EVCUtil, IERC721WrapperBase {
    uint256 public constant FULL_AMOUNT = 1e36;
    uint256 public constant MAX_TOKENIDS_ALLOWED = 7;

    IERC721 public immutable override underlying;
    IPriceOracle public immutable override oracle;
    address public immutable override unitOfAccount;

    using EnumerableSet for EnumerableSet.UintSet;

    mapping(address owner => EnumerableSet.UintSet) private _enabledTokenIds;

    error MaximumAllowedTokenIdsReached();
    error TokenIdNotOwnedByThisContract();
    error TokenIdIsAlreadyWrapped();

    event TokenIdEnabled(address indexed owner, uint256 indexed tokenId, bool enabled);

    /// @notice Constructor for the ERC721WrapperBase contract.
    /// @dev Initializes the contract with the provided addresses for EVC, underlying ERC721 token, price oracle, and unit of account.
    /// @param _evc The address of the EVC contract
    /// @param _underlying The address of the underlying ERC721 token contract to be wrapped (NonFungiblePositionManager for Uniswap V3, PositionManager for Uniswap V4 etc)
    /// @param _oracle The address of the price oracle contract (https://docs.euler.finance/concepts/core/price-oracles/)
    /// @param _unitOfAccount The address representing the unit of account (https://docs.euler.finance/concepts/advanced/unit-of-account/)
    constructor(address _evc, address _underlying, address _oracle, address _unitOfAccount) EVCUtil(_evc) {
        underlying = IERC721(_underlying);
        oracle = IPriceOracle(_oracle);
        unitOfAccount = _unitOfAccount;
    }

    function enableTokenIdAsCollateral(uint256 tokenId) public returns (bool enabled) {
        address sender = _msgSender();
        enabled = _enabledTokenIds[sender].add(tokenId);
        if (totalTokenIdsEnabledBy(sender) > MAX_TOKENIDS_ALLOWED) revert MaximumAllowedTokenIdsReached();
        if (enabled) emit TokenIdEnabled(sender, tokenId, true);
    }

    ///@dev returns true if it was enabled. if it was never enabled, it will return false
    function disableTokenIdAsCollateral(uint256 tokenId) external callThroughEVC returns (bool disabled) {
        address sender = _msgSender();
        disabled = _enabledTokenIds[sender].remove(tokenId);
        evc.requireAccountStatusCheck(sender);
        if (disabled) emit TokenIdEnabled(sender, tokenId, false);
    }

    function wrap(uint256 tokenId, address to) external {
        underlying.transferFrom(_msgSender(), address(this), tokenId);
        _wrap(tokenId, to);
    }

    ///@dev to get the entire tokenId, use this function
    function unwrap(address from, uint256 tokenId, address to) external callThroughEVC {
        _burnFrom(from, tokenId, totalSupply(tokenId));
        underlying.transferFrom(address(this), to, tokenId);
        _settleFullUnwrap(tokenId, to);
    }

    function unwrap(address from, uint256 tokenId, address to, uint256 amount, bytes calldata extraData)
        external
        callThroughEVC
    {
        uint256 totalSupplyOfTokenId = totalSupply(tokenId);
        _burnFrom(from, tokenId, amount);
        _unwrap(to, tokenId, totalSupplyOfTokenId, amount, extraData);
    }

    /// @notice For regular EVK vaults, it transfers the specified amount of vault shares from the sender to the receiver
    /// @dev For ERC721WrapperBase, transfers a proportional amount of ERC6909 tokens (calculated as totalSupply(tokenId) * amount / balanceOf(sender)) for each enabled tokenId from the sender to the receiver.
    /// @dev no need to check if sender is being liquidated, sender can choose to do this at any time
    /// @dev When calculating how many ERC6909 tokens to transfer, rounding is performed in favor of the receiver (typically the liquidator).
    function transfer(address to, uint256 amount) external callThroughEVC returns (bool) {
        address sender = _msgSender();
        uint256 currentBalance = balanceOf(sender);

        uint256 totalTokenIds = totalTokenIdsEnabledBy(sender);

        for (uint256 i = 0; i < totalTokenIds; ++i) {
            uint256 tokenId = tokenIdOfOwnerByIndex(sender, i);
            uint256 balanceOfTokenId = balanceOf(sender, tokenId);
            if (balanceOfTokenId == 0) continue; //if the tokenId balance of sender is zero, we skip it to avoid 0 transfers

            _transfer(sender, to, tokenId, normalizedToFull(balanceOfTokenId, amount, currentBalance)); //this concludes the liquidation. The liquidator can come back to do whatever they want with the ERC6909 tokens
        }
        return true;
    }

    /// @notice For regular EVK vaults, it returns the balance of the user in vault share terms, which is then converted into unitOfAccount terms by the price oracle.
    /// @dev For ERC721WrapperBase, this returns the sum value of each tokenId in unitOfAccount terms. When the vault calls the price oracle, it returns the value 1:1 because the price oracle for this collateral-only vault is configured to return 1:1.
    function balanceOf(address owner) public view returns (uint256 totalValue) {
        uint256 totalTokenIds = totalTokenIdsEnabledBy(owner);

        for (uint256 i = 0; i < totalTokenIds; ++i) {
            uint256 tokenId = tokenIdOfOwnerByIndex(owner, i);
            uint256 balanceOfTokenId = balanceOf(owner, tokenId);
            if (balanceOfTokenId == 0) continue; //if the tokenId balance of sender is zero, we skip it

            totalValue += calculateValueOfTokenId(tokenId, balanceOfTokenId);
        }
    }

    /// @dev https://github.com/euler-xyz/euler-price-oracle/#bidask-pricing for more information about the bid/ask pricing
    function getQuote(uint256 inAmount, address base) public view returns (uint256 outAmount) {
        if (evc.isControlCollateralInProgress()) {
            // mid-point price
            outAmount = oracle.getQuote(inAmount, base, unitOfAccount);
        } else {
            // bid price for collateral
            (outAmount,) = oracle.getQuotes(inAmount, base, unitOfAccount);
        }
    }

    function getSqrtRatioX96(address token0, address token1, uint256 unit0, uint256 unit1)
        public
        view
        virtual
        returns (uint160 sqrtRatioX96)
    {
        uint256 token0UnitValue = oracle.getQuote(unit0, token0, unitOfAccount);
        uint256 token1UnitValue = oracle.getQuote(unit1, token1, unitOfAccount);

        sqrtRatioX96 = SafeCast.toUint160(Math.sqrt(token0UnitValue * (1 << 96) / token1UnitValue) << 48);
    }

    function getEnabledTokenIds(address owner) external view returns (uint256[] memory) {
        return _enabledTokenIds[owner].values();
    }

    function totalTokenIdsEnabledBy(address owner) public view returns (uint256) {
        return _enabledTokenIds[owner].length();
    }

    function tokenIdOfOwnerByIndex(address owner, uint256 index) public view returns (uint256) {
        return _enabledTokenIds[owner].at(index);
    }

    function validatePosition(uint256 tokenId) public view virtual;

    /// @dev assumes that the tokenId is already owned by this address
    function _wrap(uint256 tokenId, address to) private {
        validatePosition(tokenId);
        _mint(to, tokenId, FULL_AMOUNT);
    }

    function _unwrap(
        address to,
        uint256 tokenId,
        uint256 totalSupplyOfTokenId,
        uint256 amount,
        bytes calldata extraData
    ) internal virtual;

    function _settleFullUnwrap(uint256 tokenId, address to) internal virtual;

    function _burnFrom(address from, uint256 tokenId, uint256 amount) internal {
        address sender = _msgSender();
        if (from != sender && !isOperator(from, sender)) {
            _spendAllowance(from, sender, tokenId, amount);
        }
        _burn(from, tokenId, amount);
    }

    function calculateValueOfTokenId(uint256 tokenId, uint256 amount) public view virtual returns (uint256);

    function _update(address from, address to, uint256 id, uint256 amount) internal virtual override {
        super._update(from, to, id, amount);
        if (from != address(0)) evc.requireAccountStatusCheck(from);
    }

    function proportionalShare(uint256 amount, uint256 part, uint256 totalSupplyOfTokenId)
        public
        pure
        returns (uint256)
    {
        return Math.mulDiv(amount, part, totalSupplyOfTokenId);
    }

    ///@dev rounding is done in favor of the receiver (liquidator in case of liquidation)
    function normalizedToFull(uint256 balanceOfTokenId, uint256 amount, uint256 currentBalance)
        public
        pure
        returns (uint256)
    {
        return Math.mulDiv(amount, balanceOfTokenId, currentBalance, Math.Rounding.Ceil);
    }

    function _getDecimals(address token) internal view returns (uint8) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        return success && data.length == 32 ? abi.decode(data, (uint8)) : 18;
    }

    ///@dev specific to the implementation, it should return the tokenId that needs to be skimmed
    function getTokenIdToSkim() public view virtual returns (uint256);

    function _msgSender() internal view virtual override(Context, EVCUtil) returns (address) {
        return EVCUtil._msgSender();
    }

    function transfer(address receiver, uint256 id, uint256 amount)
        public
        virtual
        override(IERC6909, ERC6909)
        callThroughEVC
        returns (bool)
    {
        return super.transfer(receiver, id, amount);
    }

    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        public
        virtual
        override(IERC6909, ERC6909)
        callThroughEVC
        returns (bool)
    {
        return super.transferFrom(sender, receiver, id, amount);
    }

    function skim(address to) external {
        uint256 tokenId = getTokenIdToSkim();
        //in case the tokenId is not owned by this contract already, it will revert
        if (underlying.ownerOf(tokenId) != address(this)) {
            revert TokenIdNotOwnedByThisContract();
        }
        //in case someone tries to skim already wrapped tokenId, it will revert
        if (totalSupply(tokenId) > 0) {
            revert TokenIdIsAlreadyWrapped();
        }
        _wrap(tokenId, to);
    }

    function enableCurrentSkimCandidateAsCollateral() external returns (bool) {
        uint256 tokenId = getTokenIdToSkim();
        return enableTokenIdAsCollateral(tokenId);
    }
}
