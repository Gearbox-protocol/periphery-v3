// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";

/// @title Horizon ↔ Gearbox bridge interface
interface IHorizonGearboxBridge {
    // ----- //
    // TYPES //
    // ----- //

    enum Action {
        Open,
        CloseImmediate,
        CloseDelayed
    }

    struct OpenParams {
        /// @notice Credit manager used for the reusable mint account
        address creditManager;
        /// @notice Underlying RWA token minted via adapters
        address rwaToken;
        /// @notice Horizon RwaAToken for `rwaToken`
        address aToken;
        /// @notice Stablecoin borrowed on Horizon / flash-loaned
        address stableAsset;
        /// @notice Flash-loan / resulting Horizon debt amount
        uint256 flashAmount;
        /// @notice Extra margin pulled from `msg.sender` via `transferFrom`
        uint256 marginAmount;
        /// @notice Minimum RWA expected on the mint account before withdrawal
        uint256 minRwaOut;
        /// @notice Allowlisted mint multicalls (external + slippage only)
        MultiCall[] calls;
    }

    struct CloseParams {
        /// @notice Credit manager for conversion / delayed redemption account
        address creditManager;
        /// @notice Underlying RWA withdrawn from Horizon
        address rwaToken;
        /// @notice Horizon RwaAToken to pull from the user
        address aToken;
        /// @notice Stablecoin debt asset flash-loaned / repaid on Horizon
        address stableAsset;
        /// @notice Horizon variable-debt token used when `debtAmount == type(uint256).max`
        address variableDebtToken;
        /// @notice Amount of Horizon debt to repay (`type(uint256).max` = full balance)
        uint256 debtAmount;
        /// @notice Amount of aTokens to pull (`type(uint256).max` = full balance)
        uint256 aTokenAmount;
        /// @notice Allowlisted conversion / redemption multicalls
        MultiCall[] calls;
    }

    // ------- //
    // EVENTS //
    // ------- //

    event OpenPosition(
        address indexed user, address indexed stableAsset, address indexed rwaToken, uint256 flashAmount, uint256 marginAmount
    );
    event CloseImmediate(
        address indexed user, address indexed stableAsset, address indexed rwaToken, uint256 debtRepaid, uint256 premium
    );
    event CloseDelayed(
        address indexed user,
        address indexed creditAccount,
        address indexed stableAsset,
        address rwaToken,
        uint256 debtRepaid,
        uint256 premium
    );
    event RegisteredMintCreditManager(address indexed creditManager, address indexed creditAccount);
    event Multicall(address indexed user, address indexed creditAccount);

    // ------- //
    // ERRORS //
    // ------- //

    error CallerNotHorizonPoolException();
    error InvalidFlashLoanInitiatorException();
    error InvalidFlashLoanAssetException();
    error UnknownActionException();
    error ForbiddenFacadeSelectorException(bytes4 selector);
    error ForbiddenWithdrawRecipientException(address to);
    error UnknownAdapterException(address target);
    error MintCreditManagerNotRegisteredException(address creditManager);
    error InsufficientRwaOutException(uint256 actual, uint256 minimum);
    error InsufficientRepayFundsException(uint256 actual, uint256 required);
    error UnexpectedSingletonDebtException(uint256 debt);
    error UnexpectedTokenBalanceException(address token, uint256 balance);
    error CreditAccountAlreadyExistsException(address user, address creditManager, address creditAccount);
    error CreditAccountNotFoundException(address user, address creditManager);
    error CallerNotAccountUserException(address caller, address user);
    error ZeroAddressException();
    error ZeroAmountException();

    // --------- //
    // FUNCTIONS //
    // --------- //

    function horizonPool() external view returns (address);
    function rwaATokenManager() external view returns (address);

    function mintCreditAccount(address creditManager) external view returns (address);
    function userCreditAccount(address user, address creditManager) external view returns (address);
    function creditAccountUser(address creditAccount) external view returns (address);

    /// @notice Registers (or re-opens) the reusable mint Credit Account for `creditManager`
    function registerMintCreditManager(address creditManager) external;

    /// @notice Opens a Horizon RWA-collateralized borrow via mode-2 flash loan + Gearbox mint rail
    function openPosition(OpenParams calldata params) external;

    /// @notice Atomically closes a Horizon position; conversion CA must end with zero debt
    function closeImmediate(CloseParams calldata params) external;

    /// @notice Closes a Horizon position into a user-mapped Gearbox CA borrowing against pending redemption
    /// @return creditAccount The delayed Credit Account controlled by the user via `multicall`
    function closeDelayed(CloseParams calldata params) external returns (address creditAccount);

    /// @notice Full CreditFacade proxy for a delayed CA owned by the bridge and mapped to `msg.sender`
    function multicall(address creditAccount, MultiCall[] calldata calls) external;

    /// @notice Owner sweep for stuck tokens
    function rescueToken(address token, address to, uint256 amount) external;
}
