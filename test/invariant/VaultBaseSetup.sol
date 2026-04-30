// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

// V4 core / periphery
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "lib/v4-periphery/lib/v4-core/test/utils/Constants.sol";
import {
    PositionManager,
    IAllowanceTransfer,
    IPositionDescriptor,
    IWETH9
} from "lib/v4-periphery/src/PositionManager.sol";

// V3 core / periphery
import {IUniswapV3Factory} from "lib/v4-periphery/lib/v4-core/test/utils/V3Helper.sol";
import {IUniswapV3Pool} from "lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "lib/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

// Euler infra
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
// IEVaultKit is used for local EVault configuration (setLTV, setIRM, etc.)
import {IEVault as IEVaultKit} from "lib/euler-vault-kit/src/EVault/IEVault.sol";
// IEVaultEuler is the type expected by vault constructors (euler-interfaces)
import {IEVault as IEVaultEuler} from "lib/euler-interfaces/interfaces/IEVault.sol";
import {MockPriceOracle} from "lib/euler-vault-kit/test/mocks/MockPriceOracle.sol";
import {MockBalanceTracker} from "lib/euler-vault-kit/test/mocks/MockBalanceTracker.sol";
import {TestERC20} from "lib/euler-vault-kit/test/mocks/TestERC20.sol";
import {IRMTestDefault} from "lib/euler-vault-kit/test/mocks/IRMTestDefault.sol";

// Tokens — use lib/openzeppelin-contracts directly (same copy as vault source)
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {WETH} from "lib/euler-price-oracle/lib/solady/src/tokens/WETH.sol";

// Our contracts
import {MockUniswapV4Wrapper} from "test/helpers/MockUniswapV4Wrapper.sol";
import {MockUniswapV3Wrapper} from "test/helpers/MockUniswapV3Wrapper.sol";
import {MockPermit2} from "test/helpers/MockPermit2.sol";
import {UniswapV3Vault} from "src/uniswap/vault/UniswapV3Vault.sol";
import {UniswapV4Vault} from "src/uniswap/vault/UniswapV4Vault.sol";
import {ERC721WrapperBase} from "src/ERC721WrapperBase.sol";
import {BaseVault} from "src/uniswap/vault/BaseVault.sol";

/// @dev Fully-local (no mainnet fork) setup for vault invariant tests.
///      Mirrors the pattern used by BaseSetup.sol for the wrapper invariants.
contract VaultBaseSetup is Test {
    // ─── Pool constants ───────────────────────────────────────────────────────
    // fee=500 → tickSpacing=10, which matches TickMath.minUsableTick(10) initial ticks
    uint24 constant FEE = 500;
    int24 constant TICK_SPACING = 10;

    // ─── V4 infra ─────────────────────────────────────────────────────────────
    PoolManager public poolManager;
    PositionManager public positionManager;
    PoolKey public poolKey;
    PoolId public poolId;

    // ─── V3 infra ─────────────────────────────────────────────────────────────
    IUniswapV3Factory public v3Factory;
    INonfungiblePositionManager public nonFungiblePositionManager;
    IUniswapV3Pool public v3Pool;

    // ─── Euler infra ─────────────────────────────────────────────────────────
    EthereumVaultConnector public evc;
    GenericFactory public genericFactory;
    MockPriceOracle public oracle;
    address public unitOfAccount = address(1);
    IEVaultKit public eBorrowVault; // lends borrow-token to the vault (local type for config calls)

    // ─── Tokens ───────────────────────────────────────────────────────────────
    WETH public weth;
    TestERC20 public tokenA;
    TestERC20 public tokenB;
    IERC20 public token0; // lower address
    IERC20 public token1; // higher address

    // ─── Wrappers ─────────────────────────────────────────────────────────────
    MockUniswapV3Wrapper public v3Wrapper;
    MockUniswapV4Wrapper public v4Wrapper;

    // ─── Vaults ───────────────────────────────────────────────────────────────
    UniswapV3Vault public v3Vault;
    UniswapV4Vault public v4Vault;

    // ─── Convenience aliases (matches names used by invariant assertions) ─────
    BaseVault public vault; // points to v3Vault
    ERC721WrapperBase public wrapper; // points to v3Wrapper

    // ─── Test config ──────────────────────────────────────────────────────────
    uint256 public initialAmount = 1e18;
    address public vaultKeeper = makeAddr("keeper");
    address public initializer = makeAddr("initializer");
    address public liquiditySeedFunder = makeAddr("funder");

    address public genericFactoryAdmin = makeAddr("genericFactoryAdmin");
    address public protocolAdmin = makeAddr("protocolAdmin");
    address public protocolFeeReceiver = makeAddr("protocolFeeReceiver");

    // ─── Setup ────────────────────────────────────────────────────────────────

    function setUp() public virtual {
        // 1. WETH
        weth = new WETH();

        // 2. V4 PoolManager + PositionManager
        poolManager = new PoolManager(makeAddr("poolManagerOwner"));
        positionManager = new PositionManager(
            poolManager, IAllowanceTransfer(address(0)), 0, IPositionDescriptor(address(0)), IWETH9(address(weth))
        );

        // 3. V3 Factory from binary (same bytecode used by wrapper invariant tests)
        address deployedAddr;
        bytes memory bytecode = vm.readFileBinary("lib/v4-periphery/lib/v4-core/test/bin/v3Factory.bytecode");
        assembly {
            deployedAddr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        v3Factory = IUniswapV3Factory(deployedAddr);

        // 4. NonFungiblePositionManager from binary
        bytecode = vm.readFileBinary("test/bin/nonFungiblePositionManager.bytecode");
        bytecode = abi.encodePacked(bytecode, abi.encode(address(v3Factory), address(weth), address(0)));
        assembly {
            deployedAddr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        nonFungiblePositionManager = INonfungiblePositionManager(deployedAddr);

        // 5. EVC
        evc = new EthereumVaultConnector();

        // 6. MockPermit2 (needed by vault constructor: permit2.approve(...))
        MockPermit2 mockPermit2 = new MockPermit2();

        // 7. Euler vault infrastructure
        Base.Integrations memory integrations = Base.Integrations({
            evc: address(evc),
            protocolConfig: address(new ProtocolConfig(protocolAdmin, protocolFeeReceiver)),
            sequenceRegistry: address(new SequenceRegistry()),
            balanceTracker: address(new MockBalanceTracker()),
            permit2: address(mockPermit2)
        });

        Dispatch.DeployedModules memory modules = Dispatch.DeployedModules({
            initialize: address(new Initialize(integrations)),
            token: address(new Token(integrations)),
            vault: address(new Vault(integrations)),
            borrowing: address(new Borrowing(integrations)),
            liquidation: address(new Liquidation(integrations)),
            riskManager: address(new RiskManager(integrations)),
            balanceForwarder: address(new BalanceForwarder(integrations)),
            governance: address(new Governance(integrations))
        });

        EVault eulerVaultImpl = new EVault(integrations, modules);
        genericFactory = new GenericFactory(genericFactoryAdmin);
        vm.prank(genericFactoryAdmin);
        genericFactory.setImplementation(address(eulerVaultImpl));

        // 8. Test tokens (18 decimals, sorted as token0/token1)
        tokenA = new TestERC20("Token A", "TKA", 18, false);
        tokenB = new TestERC20("Token B", "TKB", 18, false);

        (token0, token1) = address(tokenA) < address(tokenB)
            ? (IERC20(address(tokenA)), IERC20(address(tokenB)))
            : (IERC20(address(tokenB)), IERC20(address(tokenA)));

        // 9. Oracle — 1:1 prices for all token pairs and wrappers
        oracle = new MockPriceOracle();
        oracle.setPrice(address(token0), unitOfAccount, 1e18);
        oracle.setPrice(address(token1), unitOfAccount, 1e18);
        // Cross-pair needed for vault's oracle.getQuote(assets, asset, borrowToken)
        oracle.setPrice(address(token0), address(token1), 1e18);
        oracle.setPrice(address(token1), address(token0), 1e18);

        // 10. Borrow EVault — vault asset is token0, borrow token is token1
        eBorrowVault = IEVaultKit(
            genericFactory.createProxy(
                address(0), true, abi.encodePacked(address(token1), address(oracle), unitOfAccount)
            )
        );
        eBorrowVault.setHookConfig(address(0), 0);
        eBorrowVault.setInterestRateModel(address(new IRMTestDefault()));
        eBorrowVault.setMaxLiquidationDiscount(0.2e4);

        // 11. V4 pool + wrapper
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
        poolId = poolKey.toId();

        v4Wrapper = new MockUniswapV4Wrapper(
            address(evc), address(positionManager), address(oracle), unitOfAccount, poolKey, address(weth)
        );

        // 12. V3 pool + wrapper
        v3Pool = IUniswapV3Pool(v3Factory.createPool(address(tokenA), address(tokenB), FEE));
        v3Pool.initialize(Constants.SQRT_PRICE_1_1);
        v3Wrapper = new MockUniswapV3Wrapper(
            address(evc), address(nonFungiblePositionManager), address(oracle), unitOfAccount, address(v3Pool)
        );

        // 13. Oracle prices for wrappers (used by EVault health checks)
        oracle.setPrice(address(v3Wrapper), unitOfAccount, 1e18);
        oracle.setPrice(address(v4Wrapper), unitOfAccount, 1e18);

        // 14. Accept both wrappers as collateral in the borrow vault (90% LTV)
        eBorrowVault.setLTV(address(v3Wrapper), 0.9e4, 0.9e4, 0);
        eBorrowVault.setLTV(address(v4Wrapper), 0.9e4, 0.9e4, 0);

        // 15. Seed borrow vault with token1 so the vault can borrow
        //     Funder approves the EVault directly; SafeERC20Lib falls back to
        //     direct transferFrom when Permit2 call fails (insufficient P2 allowance).
        deal(address(token1), liquiditySeedFunder, 100_000 * initialAmount);
        vm.startPrank(liquiditySeedFunder);
        IERC20(address(token1)).approve(address(eBorrowVault), type(uint256).max);
        eBorrowVault.deposit(100_000 * initialAmount, liquiditySeedFunder);
        vm.stopPrank();

        // 16. Deploy vaults (asset = token0, borrow = token1, 2x leverage)
        //     Cast through address to bridge the euler-vault-kit / euler-interfaces IEVault split.
        v3Vault = new UniswapV3Vault(v3Wrapper, IERC20(address(token0)), IEVaultEuler(address(eBorrowVault)), 2e18);
        v4Vault = new UniswapV4Vault(v4Wrapper, IERC20(address(token0)), IEVaultEuler(address(eBorrowVault)), 2e18);

        // 17. Set keeper via storage slot 7 (after 5 ERC20 slots + tokenId slot)
        vm.store(address(v3Vault), bytes32(uint256(7)), bytes32(uint256(uint160(vaultKeeper))));
        vm.store(address(v4Vault), bytes32(uint256(7)), bytes32(uint256(uint160(vaultKeeper))));

        // 18. Initialize both vaults
        deal(address(token0), initializer, initialAmount * 2);
        vm.startPrank(initializer);
        IERC20(address(token0)).approve(address(v3Vault), type(uint256).max);
        v3Vault.initializeVault(initialAmount);
        IERC20(address(token0)).approve(address(v4Vault), type(uint256).max);
        v4Vault.initializeVault(initialAmount);
        vm.stopPrank();

        // 19. Convenience aliases for the invariant test
        vault = v3Vault;
        wrapper = v3Wrapper;
    }
}
