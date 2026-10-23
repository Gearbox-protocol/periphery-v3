// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2026.
pragma solidity ^0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {ICreditFacadeV3, MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {ReentrancyGuardTrait} from "@gearbox-protocol/core-v3/contracts/traits/ReentrancyGuardTrait.sol";

import {IAaveV3FlashLoanReceiver} from "../interfaces/external/aave/IAaveV3FlashLoanReceiver.sol";
import {IAaveV3Pool} from "../interfaces/external/aave/IAaveV3Pool.sol";
import {IRwaATokenManager} from "../interfaces/external/aave/IRwaATokenManager.sol";
import {IHorizonGearboxBridge} from "../interfaces/IHorizonGearboxBridge.sol";
import {HorizonBridgeCalls} from "../libraries/HorizonBridgeCalls.sol";

/// @title  Horizon Gearbox Bridge
/// @author Gearbox Foundation
/// @notice Intermediary that opens / closes Aave Horizon RWA borrow positions by minting or redeeming
///         collateral through Gearbox Credit Accounts.
/// @dev    Open uses `flashLoan` with `interestRateModes = 2` so debt settles on the user after aTokens
///         are moved via `RwaATokenManager`. Close uses mode `0` and repays `amount + premium` from
///         Gearbox-borrowed funds. See `docs/horizon-gearbox-bridge.md`.
contract HorizonGearboxBridge is Ownable, ReentrancyGuardTrait, IAaveV3FlashLoanReceiver, IHorizonGearboxBridge {
    using SafeERC20 for IERC20;

    /// @notice Aave variable-rate mode (sole supported debt mode on V3)
    uint256 internal constant _VARIABLE_RATE_MODE = 2;

    /// @notice Flash-loan mode that must be repaid in the same tx
    uint256 internal constant _FLASHLOAN_NO_DEBT_MODE = 0;

    bytes32 public constant contractType = "HORIZON::GEARBOX_BRIDGE";
    uint256 public constant version = 3_10;

    address public immutable override horizonPool;
    address public immutable override rwaATokenManager;

    /// @dev Reusable mint / immediate-close Credit Accounts per Credit Manager
    mapping(address creditManager => address creditAccount) public override mintCreditAccount;

    /// @dev One delayed Credit Account per user per Credit Manager
    mapping(address user => mapping(address creditManager => address creditAccount)) public override userCreditAccount;

    /// @dev Reverse lookup for `multicall` authorization
    mapping(address creditAccount => address user) public override creditAccountUser;

    /// @dev Transient flash-loan context (set only for the duration of `executeOperation`)
    Action internal _activeAction;
    address internal _activeUser;
    address internal _activeCreditManager;
    address internal _activeRwaToken;
    address internal _activeAToken;
    address internal _activeStableAsset;
    uint256 internal _activeMarginAmount;
    uint256 internal _activeMinRwaOut;
    uint256 internal _activeATokenAmount;
    bytes internal _activeCalls;

    modifier onlyHorizonPool() {
        if (msg.sender != horizonPool) revert CallerNotHorizonPoolException();
        _;
    }

    constructor(address owner_, address horizonPool_, address rwaATokenManager_) {
        if (owner_ == address(0) || horizonPool_ == address(0) || rwaATokenManager_ == address(0)) {
            revert ZeroAddressException();
        }
        horizonPool = horizonPool_;
        rwaATokenManager = rwaATokenManager_;
        _transferOwnership(owner_);
    }

    // ----------------- //
    // OWNER / LIFECYCLE //
    // ----------------- //

    /// @inheritdoc IHorizonGearboxBridge
    function registerMintCreditManager(address creditManager) external onlyOwner nonReentrant {
        if (creditManager == address(0)) revert ZeroAddressException();

        address facade = ICreditManagerV3(creditManager).creditFacade();
        address creditAccount = ICreditFacadeV3(facade).openCreditAccount(address(this), new MultiCall[](0), 0);
        mintCreditAccount[creditManager] = creditAccount;

        address underlying = ICreditManagerV3(creditManager).underlying();
        IERC20(underlying).forceApprove(creditManager, type(uint256).max);

        emit RegisteredMintCreditManager(creditManager, creditAccount);
    }

    /// @inheritdoc IHorizonGearboxBridge
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddressException();
        IERC20(token).safeTransfer(to, amount);
    }

    // ------ //
    // OPEN //
    // ------ //

    /// @inheritdoc IHorizonGearboxBridge
    function openPosition(OpenParams calldata params) external nonReentrant {
        if (params.flashAmount == 0) revert ZeroAmountException();
        if (
            params.creditManager == address(0) || params.rwaToken == address(0) || params.aToken == address(0)
                || params.stableAsset == address(0)
        ) {
            revert ZeroAddressException();
        }
        if (mintCreditAccount[params.creditManager] == address(0)) {
            revert MintCreditManagerNotRegisteredException(params.creditManager);
        }

        HorizonBridgeCalls.validateOpenCalls(params.creditManager, params.calls);

        if (params.marginAmount != 0) {
            IERC20(params.stableAsset).safeTransferFrom(msg.sender, address(this), params.marginAmount);
        }

        _storeOpenContext(params);
        _takeFlashLoan({
            asset: params.stableAsset,
            amount: params.flashAmount,
            interestRateMode: _VARIABLE_RATE_MODE,
            onBehalfOf: msg.sender
        });

        // Mode-2 leaves no repay dust; refund any unexpected stable leftovers to the user
        _refundToken(params.stableAsset, msg.sender);
    }

    // ------- //
    // CLOSE //
    // ------- //

    /// @inheritdoc IHorizonGearboxBridge
    function closeImmediate(CloseParams calldata params) external nonReentrant {
        _close(params, Action.CloseImmediate);
        _refundToken(params.stableAsset, msg.sender);
    }

    /// @inheritdoc IHorizonGearboxBridge
    function closeDelayed(CloseParams calldata params) external nonReentrant returns (address creditAccount) {
        _close(params, Action.CloseDelayed);
        creditAccount = userCreditAccount[msg.sender][params.creditManager];
        _refundToken(params.stableAsset, msg.sender);
    }

    /// @inheritdoc IHorizonGearboxBridge
    function multicall(address creditAccount, MultiCall[] calldata calls) external nonReentrant {
        address user = creditAccountUser[creditAccount];
        if (user == address(0)) revert CreditAccountNotFoundException(msg.sender, address(0));
        if (msg.sender != user) revert CallerNotAccountUserException(msg.sender, user);

        address creditManager = ICreditAccountV3(creditAccount).creditManager();
        address facade = ICreditManagerV3(creditManager).creditFacade();
        ICreditFacadeV3(facade).multicall(creditAccount, calls);

        emit Multicall(user, creditAccount);
    }

    // -------------------- //
    // AAVE FLASH CALLBACK //
    // -------------------- //

    /// @inheritdoc IAaveV3FlashLoanReceiver
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata
    )
        external
        override
        onlyHorizonPool
        returns (bool)
    {
        if (initiator != address(this)) revert InvalidFlashLoanInitiatorException();
        if (assets.length != 1 || amounts.length != 1 || premiums.length != 1) {
            revert InvalidFlashLoanAssetException();
        }
        if (assets[0] != _activeStableAsset) revert InvalidFlashLoanAssetException();

        Action action = _activeAction;
        if (action == Action.Open) {
            _executeOpen(assets[0], amounts[0]);
        } else if (action == Action.CloseImmediate) {
            _executeClose(assets[0], amounts[0], premiums[0], true);
        } else if (action == Action.CloseDelayed) {
            _executeClose(assets[0], amounts[0], premiums[0], false);
        } else {
            revert UnknownActionException();
        }

        _clearContext();
        return true;
    }

    // --------- //
    // INTERNALS //
    // --------- //

    function _close(CloseParams calldata params, Action action) internal {
        if (
            params.creditManager == address(0) || params.rwaToken == address(0) || params.aToken == address(0)
                || params.stableAsset == address(0) || params.variableDebtToken == address(0)
        ) {
            revert ZeroAddressException();
        }

        HorizonBridgeCalls.validateCloseCalls(params.creditManager, params.calls, address(this));

        uint256 debtAmount = params.debtAmount;
        if (debtAmount == type(uint256).max) {
            debtAmount = IERC20(params.variableDebtToken).balanceOf(msg.sender);
        }
        if (debtAmount == 0) revert ZeroAmountException();

        if (action == Action.CloseImmediate) {
            if (mintCreditAccount[params.creditManager] == address(0)) {
                revert MintCreditManagerNotRegisteredException(params.creditManager);
            }
        } else {
            _ensureUserCreditAccount(params.creditManager);
        }

        _storeCloseContext(params, action);
        _takeFlashLoan({
            asset: params.stableAsset,
            amount: debtAmount,
            interestRateMode: _FLASHLOAN_NO_DEBT_MODE,
            onBehalfOf: address(this)
        });
    }

    function _executeOpen(address stableAsset, uint256 flashAmount) internal {
        address creditManager = _activeCreditManager;
        address creditAccount = mintCreditAccount[creditManager];
        address facade = ICreditManagerV3(creditManager).creditFacade();
        address rwaToken = _activeRwaToken;
        address user = _activeUser;

        uint256 totalIn = flashAmount + _activeMarginAmount;
        IERC20(stableAsset).forceApprove(creditManager, totalIn);

        MultiCall[] memory userCalls = abi.decode(_activeCalls, (MultiCall[]));
        MultiCall[] memory calls = new MultiCall[](userCalls.length + 2);
        calls[0] = MultiCall({
            target: facade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (stableAsset, totalIn))
        });
        for (uint256 i; i < userCalls.length; ++i) {
            calls[i + 1] = userCalls[i];
        }
        calls[userCalls.length + 1] = MultiCall({
            target: facade,
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.withdrawCollateral, (rwaToken, type(uint256).max, address(this))
            )
        });

        ICreditFacadeV3(facade).multicall(creditAccount, calls);

        uint256 rwaBal = IERC20(rwaToken).balanceOf(address(this));
        if (rwaBal < _activeMinRwaOut) revert InsufficientRwaOutException(rwaBal, _activeMinRwaOut);

        IERC20(rwaToken).forceApprove(horizonPool, rwaBal);
        IAaveV3Pool(horizonPool).supply(rwaToken, rwaBal, address(this), 0);

        uint256 aTokenBal = IERC20(_activeAToken).balanceOf(address(this));
        IRwaATokenManager(rwaATokenManager).transferRwaAToken(_activeAToken, address(this), user, aTokenBal);

        _assertNoDust(rwaToken);
        _assertNoDust(_activeAToken);
        _assertSingletonClean(creditManager, creditAccount);

        emit OpenPosition(user, stableAsset, rwaToken, flashAmount, _activeMarginAmount);
    }

    function _executeClose(address stableAsset, uint256 flashAmount, uint256 premium, bool immediate) internal {
        address user = _activeUser;
        address rwaToken = _activeRwaToken;
        address aToken = _activeAToken;
        uint256 owed = flashAmount + premium;

        IERC20(stableAsset).forceApprove(horizonPool, flashAmount);
        IAaveV3Pool(horizonPool).repay(stableAsset, flashAmount, _VARIABLE_RATE_MODE, user);

        uint256 aTokenAmount = _activeATokenAmount;
        if (aTokenAmount == type(uint256).max) {
            aTokenAmount = IERC20(aToken).balanceOf(user);
        }
        IRwaATokenManager(rwaATokenManager).transferRwaAToken(aToken, user, address(this), aTokenAmount);
        IAaveV3Pool(horizonPool).withdraw(rwaToken, type(uint256).max, address(this));

        address creditAccount = _runCloseConversion(rwaToken, immediate);
        _pullRepayFunds(creditAccount, stableAsset, owed);
        // Pool pulls `owed` after this callback returns
        IERC20(stableAsset).forceApprove(horizonPool, owed);

        if (immediate) {
            _assertSingletonClean(_activeCreditManager, creditAccount);
        }

        _assertNoDust(aToken);
        _assertNoDust(rwaToken);

        if (immediate) {
            emit CloseImmediate(user, stableAsset, rwaToken, flashAmount, premium);
        } else {
            emit CloseDelayed(user, creditAccount, stableAsset, rwaToken, flashAmount, premium);
        }
    }

    function _runCloseConversion(address rwaToken, bool immediate) internal returns (address creditAccount) {
        address creditManager = _activeCreditManager;
        address facade = ICreditManagerV3(creditManager).creditFacade();
        address user = _activeUser;

        creditAccount = immediate ? mintCreditAccount[creditManager] : userCreditAccount[user][creditManager];

        uint256 rwaBal = IERC20(rwaToken).balanceOf(address(this));
        IERC20(rwaToken).forceApprove(creditManager, rwaBal);

        MultiCall[] memory userCalls = abi.decode(_activeCalls, (MultiCall[]));
        MultiCall[] memory calls = new MultiCall[](userCalls.length + 1);
        calls[0] = MultiCall({
            target: facade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (rwaToken, rwaBal))
        });
        for (uint256 i; i < userCalls.length; ++i) {
            calls[i + 1] = userCalls[i];
        }

        ICreditFacadeV3(facade).multicall(creditAccount, calls);
    }

    function _pullRepayFunds(address creditAccount, address stableAsset, uint256 owed) internal {
        uint256 bal = IERC20(stableAsset).balanceOf(address(this));
        if (bal >= owed) return;

        address creditManager = ICreditAccountV3(creditAccount).creditManager();
        address underlying = ICreditManagerV3(creditManager).underlying();
        if (underlying != stableAsset) revert InsufficientRepayFundsException(bal, owed);

        address facade = ICreditManagerV3(creditManager).creditFacade();
        MultiCall[] memory withdrawCalls = new MultiCall[](1);
        withdrawCalls[0] = MultiCall({
            target: facade,
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.withdrawCollateral, (stableAsset, type(uint256).max, address(this))
            )
        });
        ICreditFacadeV3(facade).multicall(creditAccount, withdrawCalls);

        bal = IERC20(stableAsset).balanceOf(address(this));
        if (bal < owed) revert InsufficientRepayFundsException(bal, owed);
    }

    function _ensureUserCreditAccount(address creditManager) internal {
        address existing = userCreditAccount[msg.sender][creditManager];
        if (existing != address(0)) return;

        address facade = ICreditManagerV3(creditManager).creditFacade();
        address creditAccount = ICreditFacadeV3(facade).openCreditAccount(address(this), new MultiCall[](0), 0);

        userCreditAccount[msg.sender][creditManager] = creditAccount;
        creditAccountUser[creditAccount] = msg.sender;

        address underlying = ICreditManagerV3(creditManager).underlying();
        IERC20(underlying).forceApprove(creditManager, type(uint256).max);
    }

    function _takeFlashLoan(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) internal {
        address[] memory assets = new address[](1);
        assets[0] = asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256[] memory modes = new uint256[](1);
        modes[0] = interestRateMode;

        IAaveV3Pool(horizonPool).flashLoan(address(this), assets, amounts, modes, onBehalfOf, "", 0);
    }

    function _storeOpenContext(OpenParams calldata params) internal {
        _activeAction = Action.Open;
        _activeUser = msg.sender;
        _activeCreditManager = params.creditManager;
        _activeRwaToken = params.rwaToken;
        _activeAToken = params.aToken;
        _activeStableAsset = params.stableAsset;
        _activeMarginAmount = params.marginAmount;
        _activeMinRwaOut = params.minRwaOut;
        _activeATokenAmount = 0;
        _activeCalls = abi.encode(params.calls);
    }

    function _storeCloseContext(CloseParams calldata params, Action action) internal {
        _activeAction = action;
        _activeUser = msg.sender;
        _activeCreditManager = params.creditManager;
        _activeRwaToken = params.rwaToken;
        _activeAToken = params.aToken;
        _activeStableAsset = params.stableAsset;
        _activeMarginAmount = 0;
        _activeMinRwaOut = 0;
        _activeATokenAmount = params.aTokenAmount;
        _activeCalls = abi.encode(params.calls);
    }

    function _clearContext() internal {
        delete _activeAction;
        delete _activeUser;
        delete _activeCreditManager;
        delete _activeRwaToken;
        delete _activeAToken;
        delete _activeStableAsset;
        delete _activeMarginAmount;
        delete _activeMinRwaOut;
        delete _activeATokenAmount;
        delete _activeCalls;
    }

    function _assertNoDust(address token) internal view {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal != 0) revert UnexpectedTokenBalanceException(token, bal);
    }

    function _assertSingletonClean(address creditManager, address creditAccount) internal view {
        (uint256 debt,,,,,,,) = ICreditManagerV3(creditManager).creditAccountInfo(creditAccount);
        if (debt != 0) revert UnexpectedSingletonDebtException(debt);
    }

    function _refundToken(address token, address to) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal != 0) IERC20(token).safeTransfer(to, bal);
    }
}
