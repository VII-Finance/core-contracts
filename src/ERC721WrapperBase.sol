// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC6909, ERC6909} from "lib/openzeppelin-contracts/contracts/token/ERC6909/ERC6909.sol";
import {ERC6909TokenSupply} from "lib/openzeppelin-contracts/contracts/token/ERC6909/extensions/ERC6909TokenSupply.sol";
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
    uint256 public constant FULL_AMOUNT = 1e36 - MINIMUM_AMOUNT; // D36{share} freely-transferable share supply per tokenId
    uint256 public constant MINIMUM_AMOUNT = 1e3; // D36{share} permanently locked to address(1) on wrap
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

    /// @notice Returns the decimals of the unit of account token; D{unitOfAccountDecimals}
    function decimals() public view returns (uint8) {
        return _getDecimals(unitOfAccount);
    }

    function enableTokenIdAsCollateral(uint256 tokenId) public returns (bool enabled) {
        address sender = _msgSender();
        enabled = _enabledTokenIds[sender].add(tokenId);
        if (totalTokenIdsEnabledBy(sender) > MAX_TOKENIDS_ALLOWED) revert MaximumAllowedTokenIdsReached();
        if (enabled) emit TokenIdEnabled(sender, tokenId, true);
    }

    /// @dev Returns true if it was enabled. If it was never enabled, it will return false.
    /// @dev The callThroughEVC modifier is only needed in actions that request account status check mid-execution when it's really needed
    ///      at the end of the action. For this action, it is acceptable if the account status check happens before the event is emitted.
    function disableTokenIdAsCollateral(uint256 tokenId) external returns (bool disabled) {
        address sender = _msgSender();
        disabled = _enabledTokenIds[sender].remove(tokenId);
        evc.requireAccountStatusCheck(sender);
        if (disabled) emit TokenIdEnabled(sender, tokenId, false);
    }

    function wrap(uint256 tokenId, address to) external {
        underlying.transferFrom(_msgSender(), address(this), tokenId);
        _wrap(tokenId, to);
    }

    /// @dev To get the entire tokenId, use this function.
    /// @dev The callThroughEVC modifier is not really needed here. Even though the account status check technically happens mid-execution
    ///      (in the overridden _update function triggered by _burnFrom), the totalSupply of tokenId is already burned before the
    ///      account status check happens. The actual NFT transfer doesn't really matter in Uniswap wrappers case. We have still kept it so that account status checks
    ///      only happen at the end of the action for future wrappers where it might be needed.
    function unwrap(address from, uint256 tokenId, address to) external callThroughEVC {
        // if you have the FULL_AMOUNT then and only then you will be able to do full unwrap
        // otherwise, you will have to do the partial unwrap
        _burnFrom(from, tokenId, FULL_AMOUNT);
        // no need to check for allowance. This is just to zero out the total supply
        _burn(address(1), tokenId, MINIMUM_AMOUNT);
        underlying.transferFrom(address(this), to, tokenId);
        // We want this to happen at the end; otherwise, using the token transfers (especially native ETH transfers) that happen in Uniswap wrappers,
        // a user can reenter and could cause issues.
        _settleFullUnwrap(tokenId, to);
    }

    /// @dev Partial unwrap.
    /// @dev The callThroughEVC modifier is needed because we need the actual unwrap to happen before the burning of ERC6909 tokens
    ///      to avoid reentrancy through token transfers (especially native ETH transfers).
    ///      In unwrap, for Uniswap wrappers, proportional liquidity is removed and because it happens after the _burnFrom,
    ///      where the account status check happens, we definitely need it to happen at the end of the action to make sure
    ///      proportional liquidity is removed before balanceOf considers the current liquidity to determine the value of the collateral.
    /// @param amount    {share} D36 ERC6909 share amount to burn and redeem proportionally
    function unwrap(address from, uint256 tokenId, address to, uint256 amount, bytes calldata extraData)
        external
        callThroughEVC
    {
        uint256 totalSupplyOfTokenId = totalSupply(tokenId); // {share} D36 total supply for tokenId
        _burnFrom(from, tokenId, amount);
        // We want unwrap to happen at the end; otherwise, using the token transfers (especially native ETH transfers) that happen in Uniswap wrappers,
        // a user can reenter and could cause issues.
        _unwrap(to, tokenId, totalSupplyOfTokenId, amount, extraData);
    }

    /// @notice For regular EVK vaults, it transfers the specified amount of vault shares from the sender to the receiver.
    /// @dev For ERC721WrapperBase, transfers a proportional amount of ERC6909 tokens (calculated as totalSupply(tokenId) * amount / balanceOf(sender))
    ///      for each enabled tokenId from the sender to the receiver.
    /// @dev No need to check if sender is being liquidated; sender can choose to do this at any time.
    /// @dev When calculating how many ERC6909 tokens to transfer, rounding is performed in favor of the receiver (typically the liquidator).
    /// @dev The callThroughEVC modifier is needed here to make sure account status checks do not happen every time there is a ERC6909 transfer.
    ///      We save gas by doing the account status check only at the end of this action.
    function transfer(address to, uint256 amount) external callThroughEVC returns (bool) {
        address sender = _msgSender();
        uint256 currentBalance = balanceOf(sender); // {UoA} total position value of sender across all enabled tokenIds

        uint256 totalTokenIds = totalTokenIdsEnabledBy(sender); // dimensionless count

        for (uint256 i = 0; i < totalTokenIds; ++i) {
            uint256 tokenId = tokenIdOfOwnerByIndex(sender, i);
            uint256 balanceOfTokenId = balanceOf(sender, tokenId); // {share} D36 ERC6909 balance for this tokenId
            if (balanceOfTokenId == 0) continue; // If the tokenId balance of sender is zero, we skip it to avoid 0 transfers.

            // {share} = normalizedToFull({share}, {UoA}, {UoA}) → {share} D36 tokens to transfer for this tokenId
            _transfer(sender, to, tokenId, normalizedToFull(balanceOfTokenId, amount, currentBalance)); // This concludes the liquidation. The liquidator can come back to do whatever they want with the ERC6909 tokens.
        }
        return true;
    }

    /// @notice For regular EVK vaults, it returns the balance of the user in vault share terms, which is then converted into unitOfAccount terms by the price oracle.
    /// @dev For ERC721WrapperBase, this returns the sum value of each tokenId in unitOfAccount terms. When the vault calls the price oracle, it returns the value 1:1 because the price oracle for this collateral-only vault is configured to return 1:1.
    /// @return totalValue {UoA} sum of all enabled tokenId values in unit-of-account terms
    function balanceOf(address owner) public view returns (uint256 totalValue) {
        // {UoA}
        uint256 totalTokenIds = totalTokenIdsEnabledBy(owner); // dimensionless count

        for (uint256 i = 0; i < totalTokenIds; ++i) {
            uint256 tokenId = tokenIdOfOwnerByIndex(owner, i);
            uint256 balanceOfTokenId = balanceOf(owner, tokenId); // {share} D36 ERC6909 balance for this tokenId
            if (balanceOfTokenId == 0) continue; // If the tokenId balance of sender is zero, we skip it.

            // {UoA} += calculateValueOfTokenId({share}) → {UoA} proportional position value
            totalValue += calculateValueOfTokenId(tokenId, balanceOfTokenId);
        }
    }

    /// @dev https://github.com/euler-xyz/euler-price-oracle/#bidask-pricing for more information about the bid/ask pricing
    /// @param inAmount  {tok} amount of `base` token to price (D{tokenDecimals})
    /// @return outAmount {UoA} value of `inAmount` in unit-of-account terms (D{unitOfAccountDecimals})
    /// Note: For now, oracles that provide different mid, bid and ask prices are not supported
    function getQuote(uint256 inAmount, address base) public view returns (uint256 outAmount) {
        if (evc.isControlCollateralInProgress()) {
            // mid-point price
            outAmount = oracle.getQuote(inAmount, base, unitOfAccount);
        } else {
            // bid price for collateral
            (outAmount,) = oracle.getQuotes(inAmount, base, unitOfAccount);
        }
    }

    /// @param token0      address of token0
    /// @param token1      address of token1
    /// @param unit0       {unit} one canonical unit of token0 (10**decimals0); used as oracle inAmount
    /// @param unit1       {unit} one canonical unit of token1 (10**decimals1); used as oracle inAmount
    /// @return sqrtRatioX96 QX96{sqrt(tok1/tok0)} oracle-derived sqrt price encoded as Q64.96
    function getSqrtRatioX96(address token0, address token1, uint256 unit0, uint256 unit1)
        public
        view
        virtual
        override
        returns (uint160 sqrtRatioX96)
    {
        uint256 token0UnitValue = getQuote(unit0, token0); // {UoA} value of 1 unit of token0
        uint256 token1UnitValue = getQuote(unit1, token1); // {UoA} value of 1 unit of token1

        // QX96{sqrt(tok1/tok0)}:
        //   inner ratio = (token0UnitValue/unit0) / (token1UnitValue/unit1) = {UoA/tok0} / {UoA/tok1} = {tok1/tok0}
        //   sqrt(ratio * 2^96) yields Q48.48; left-shift 48 bits → Q64.96
        // {tok1/tok0} numerator: {UoA} * {unit} * Q96 = token0UnitValue * unit1 * 2^96
        // {tok1/tok0} denominator: {UoA} * {unit} = token1UnitValue * unit0
        // inner sqrt argument: {tok1/tok0} * Q96 (dimensionless ratio scaled by 2^96)
        sqrtRatioX96 =
            SafeCast.toUint160(Math.sqrt(token0UnitValue * unit1 * (1 << 96) / (token1UnitValue * unit0)) << 48);
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

        // In case someone tries to wrap an already wrapped tokenId, it will revert
        if (totalSupply(tokenId) > 0) {
            // totalSupply(tokenId): {share} D36; > 0 means already wrapped
            revert TokenIdIsAlreadyWrapped();
        }
        _mint(to, tokenId, FULL_AMOUNT); // FULL_AMOUNT: D36{share}
        _mint(address(1), tokenId, MINIMUM_AMOUNT); // MINIMUM_AMOUNT: D36{share} permanently locked
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

    /// @param amount  {share} D36 ERC6909 share balance of the caller for this tokenId
    /// @return        {UoA} proportional value of the position in unit-of-account terms
    function calculateValueOfTokenId(uint256 tokenId, uint256 amount) public view virtual returns (uint256);

    function _update(address from, address to, uint256 id, uint256 amount) internal virtual override {
        super._update(from, to, id, amount);
        // there is no need for account status when ERC6909 tokens are minted (wrap action) as it only increases the value of collateral
        if (from != address(0)) evc.requireAccountStatusCheck(from);
    }

    /// @param amount              the quantity whose proportional slice is computed (e.g. {tok0}, {tok1}, or {liq})
    /// @param part                {share} caller's ERC6909 share balance for the tokenId
    /// @param totalSupplyOfTokenId {share} total ERC6909 supply for the tokenId (D36)
    /// @return                    same dimension as `amount`; {share/share} fraction applied via mulDiv
    function proportionalShare(uint256 amount, uint256 part, uint256 totalSupplyOfTokenId)
        public
        pure
        returns (uint256)
    {
        // result_dim = amount_dim * {share} / {share}  →  same dimension as `amount`
        return Math.mulDiv(amount, part, totalSupplyOfTokenId);
    }

    /// @dev Rounding is done in favor of the receiver (receiver = liquidator in case of liquidation).
    /// @param balanceOfTokenId {share} sender's ERC6909 balance for one tokenId (D36)
    /// @param amount           {UoA}  vault-level share amount being transferred
    /// @param currentBalance   {UoA}  sender's total balanceOf() across all enabled tokenIds
    /// @return                 {share} ERC6909 tokens to transfer for this tokenId (rounded up)
    function normalizedToFull(uint256 balanceOfTokenId, uint256 amount, uint256 currentBalance)
        public
        pure
        returns (uint256)
    {
        // {share} = {UoA} * {share} / {UoA}  →  {share}
        return Math.mulDiv(amount, balanceOfTokenId, currentBalance, Math.Rounding.Ceil);
    }

    function _getDecimals(address token) internal view returns (uint8) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        return success && data.length == 32 ? abi.decode(data, (uint8)) : 18;
    }

    /// @dev Specific to the implementation, it should return the tokenId that needs to be skimmed.
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
        // In case the tokenId is not owned by this contract already, it will revert.
        if (underlying.ownerOf(tokenId) != address(this)) {
            revert TokenIdNotOwnedByThisContract();
        }
        _wrap(tokenId, to);
    }

    function enableCurrentSkimCandidateAsCollateral() external returns (bool) {
        uint256 tokenId = getTokenIdToSkim();
        return enableTokenIdAsCollateral(tokenId);
    }
}
