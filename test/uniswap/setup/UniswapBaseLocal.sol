// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

// forge-std
import {Test} from "forge-std/Test.sol";

// V4 infra
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {
    PositionManager,
    IAllowanceTransfer,
    IPositionDescriptor,
    IWETH9
} from "lib/v4-periphery/src/PositionManager.sol";
import {Constants} from "lib/v4-periphery/lib/v4-core/test/utils/Constants.sol";

// V3 infra
import {IUniswapV3Factory} from "lib/v4-periphery/lib/v4-core/test/utils/V3Helper.sol";
import {INonfungiblePositionManager} from "lib/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

// Euler infra
import {IPriceOracle} from "lib/euler-price-oracle/src/interfaces/IPriceOracle.sol";
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
import {IEVault as IEVaultKit} from "lib/euler-vault-kit/src/EVault/IEVault.sol";
import {IEVault} from "lib/euler-interfaces/interfaces/IEVault.sol";
import {MockPriceOracle} from "lib/euler-vault-kit/test/mocks/MockPriceOracle.sol";
import {MockBalanceTracker} from "lib/euler-vault-kit/test/mocks/MockBalanceTracker.sol";
import {TestERC20} from "lib/euler-vault-kit/test/mocks/TestERC20.sol";
import {IRMTestDefault} from "lib/euler-vault-kit/test/mocks/IRMTestDefault.sol";

// Tokens
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import {WETH} from "lib/euler-price-oracle/lib/solady/src/tokens/WETH.sol";

// Our base
import {UniswapBaseTest} from "test/uniswap/UniswapBase.t.sol";
import {MockPermit2} from "test/helpers/MockPermit2.sol";

/// @dev Abstract local setUp provider for wrapper and vault fuzz tests.
///      Mirrors the deployment pattern from test/invariant/BaseSetup.sol and
///      VaultBaseSetup.sol. Concrete test classes inherit this alongside
///      their test-body abstract (e.g. UniswapV3WrapperTestBase).
abstract contract UniswapBaseTestLocal is UniswapBaseTest {
    // ─── Local infrastructure ─────────────────────────────────────────────────
    WETH public localWeth;
    PoolManager public localPoolManager;
    PositionManager public localPositionManager;
    IUniswapV3Factory public localV3Factory;
    INonfungiblePositionManager public localNFPM;
    GenericFactory public localGenericFactory;
    MockPriceOracle public mockOracle;

    // Seeder for the borrow vault
    address public liquiditySeedFunder = makeAddr("localFunder");
    address public localGenericFactoryAdmin = makeAddr("localFactoryAdmin");
    address public localProtocolAdmin = makeAddr("localProtocolAdmin");
    address public localProtocolFeeReceiver = makeAddr("localProtocolFeeReceiver");

    uint256 public constant LOCAL_SEED = 100_000 * 1e18;
    uint256 public constant LOCAL_UNIT = 1e18; // 18-decimal tokens

    function setUp() public virtual override {
        // 1. WETH
        localWeth = new WETH();

        // 2. V4 PoolManager + PositionManager
        localPoolManager = new PoolManager(makeAddr("pmOwner"));
        localPositionManager = new PositionManager(
            localPoolManager,
            IAllowanceTransfer(address(0)),
            300_000, // unsubscribeGasLimit: must be non-zero so notifyUnsubscribe callbacks execute
            IPositionDescriptor(address(0)),
            IWETH9(address(localWeth))
        );

        // 3. V3 Factory from binary
        address deployedAddr;
        bytes memory bytecode = vm.readFileBinary("lib/v4-periphery/lib/v4-core/test/bin/v3Factory.bytecode");
        assembly {
            deployedAddr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        localV3Factory = IUniswapV3Factory(deployedAddr);

        // 4. NonFungiblePositionManager from binary
        bytecode = vm.readFileBinary("test/bin/nonFungiblePositionManager.bytecode");
        bytecode = abi.encodePacked(bytecode, abi.encode(address(localV3Factory), address(localWeth), address(0)));
        assembly {
            deployedAddr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        localNFPM = INonfungiblePositionManager(deployedAddr);

        // 5. EVC
        EthereumVaultConnector localEvc = new EthereumVaultConnector();
        evc = localEvc;

        // 6. MockPermit2
        MockPermit2 mockPermit2 = new MockPermit2();

        // 7. Euler vault infrastructure
        Base.Integrations memory integrations = Base.Integrations({
            evc: address(evc),
            protocolConfig: address(new ProtocolConfig(localProtocolAdmin, localProtocolFeeReceiver)),
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
        localGenericFactory = new GenericFactory(localGenericFactoryAdmin);
        vm.prank(localGenericFactoryAdmin);
        localGenericFactory.setImplementation(address(eulerVaultImpl));

        // 8. Test tokens — 18 decimals, sorted as token0/token1
        TestERC20 tokenA = new TestERC20("Token A", "TKA", 18, false);
        TestERC20 tokenB = new TestERC20("Token B", "TKB", 18, false);

        (token0, token1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));

        unit0 = 1e18;
        unit1 = 1e18;

        // 9. MockPriceOracle — 1:1 prices
        mockOracle = new MockPriceOracle();
        oracle = IPriceOracle(address(mockOracle));
        unitOfAccount = address(1);

        mockOracle.setPrice(token0, unitOfAccount, 1e18);
        mockOracle.setPrice(token1, unitOfAccount, 1e18);
        mockOracle.setPrice(token0, token1, 1e18);
        mockOracle.setPrice(token1, token0, 1e18);

        // 10. Borrow EVault (asset = token1, lends to wrapper holders)
        IEVaultKit borrowVaultKit = IEVaultKit(
            localGenericFactory.createProxy(address(0), true, abi.encodePacked(token1, address(oracle), unitOfAccount))
        );
        borrowVaultKit.setHookConfig(address(0), 0);
        borrowVaultKit.setInterestRateModel(address(new IRMTestDefault()));
        borrowVaultKit.setMaxLiquidationDiscount(0.2e4);
        eVault = IEVault(address(borrowVaultKit));
        asset = IERC20(eVault.asset()); // token1

        // 11. Seed borrow vault with token1
        deal(token1, liquiditySeedFunder, LOCAL_SEED);
        vm.startPrank(liquiditySeedFunder);
        IERC20(token1).approve(address(eVault), type(uint256).max);
        borrowVaultKit.deposit(LOCAL_SEED, liquiditySeedFunder);
        vm.stopPrank();

        // 12. Deal tokens to borrower/liquidator
        deal(token0, borrower, 100 * unit0);
        deal(token1, borrower, 100 * unit1);

        // 13. Deploy wrapper (implemented by each concrete test class)
        wrapper = deployWrapper();

        // 14. Set wrapper oracle price (1:1 initially)
        mockOracle.setPrice(address(wrapper), unitOfAccount, 1e18);

        // 15. Accept wrapper as collateral in the borrow vault
        borrowVaultKit.setLTV(address(wrapper), 0.9e4, 0.9e4, 0);
    }

    function _setWrapperUOAPrice(uint256 price) internal override {
        mockOracle.setPrice(address(wrapper), unitOfAccount, price);
    }
}
