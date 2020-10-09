// SPDX-License-Identifier: MIT
pragma solidity 0.7.3;

import { Proxiable } from "../upgradability/Proxiable.sol";
import { Ownable } from "../access/Ownable.sol";

import {
    ISuperfluid,
    ISuperfluidGovernance,
    ISuperToken,
    ISuperAgreement,
    IERC20,
    IERC777,
    TokenInfo
} from "../interfaces/superfluid/ISuperfluid.sol";
import { ISuperfluidToken, SuperfluidToken } from "./SuperfluidToken.sol";

import { ERC777Operators } from "../utils/ERC777Operators.sol";

import { SignedSafeMath } from "@openzeppelin/contracts/math/SignedSafeMath.sol";
import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { IERC1820Registry } from "@openzeppelin/contracts/introspection/IERC1820Registry.sol";
import { IERC777Recipient } from "@openzeppelin/contracts/token/ERC777/IERC777Recipient.sol";
import { IERC777Sender } from "@openzeppelin/contracts/token/ERC777/IERC777Sender.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";


/**
 * @title Superfluid's token implementation
 * @author Superfluid
 */
contract SuperToken is
    Proxiable,
    Ownable,
    SuperfluidToken,
    ISuperToken
{

    using SignedSafeMath for int256;
    using SafeMath for uint256;
    using Address for address;
    using ERC777Operators for ERC777Operators.Object;

    uint8 constant private _STANDARD_DECIMALS = 18;

    string constant private _ERR_TRANSFER_FROM_ZERO_ADDRESS = "SuperToken: transfer from zero address";
    string constant private _ERR_TRANSFER_TO_ZERO_ADDRESS = "SuperToken: transfer to zero address";
    string constant private _ERR_TRANSFER_EXCEED_ALLOWANCE = "SuperToken: transfer amount exceeds allowance";
    string constant private _ERR_TRANSFER_EXCEED_BALANCE = "SuperToken: transfer amount exceeds balance";
    string constant private _ERR_APPROVE_FROM_ZERO_ADDRESS = "SuperToken: approve from zero address";
    string constant private _ERR_APPROVE_TO_ZERO_ADDRESS = "SuperToken: approve to zero address";
    string constant private _ERR_DOWNGRADE_EXCEED_BALANCE = "SuperToken: downgrade amount exceeds balance";
    string constant private _ERR_CALLER_NOT_AN_OPERATOR = "SuperToken: caller is not an operator for holder";
    string constant private _ERR_NOT_ERC777RECIPIENT = "SuperToken: not an ERC777TokensRecipient";
    string constant private _ERR_MINT_TO_ZERO_ADDRESS = "SuperToken: mint to zero address";
    string constant private _ERR_BURN_FROM_ZERO_ADDRESS = "SuperToken: burn from zero address";
    string constant private _ERR_BURN_EXCEED_BALANCE = "SuperToken: burn amount exceeds balance";

    IERC1820Registry constant internal _ERC1820_REGISTRY = IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);
    bytes32 constant private _TOKENS_SENDER_INTERFACE_HASH = keccak256("ERC777TokensSender");
    bytes32 constant private _TOKENS_RECIPIENT_INTERFACE_HASH = keccak256("ERC777TokensRecipient");

    /* WARNING: NEVER RE-ORDER VARIABLES! Including the base contracts.
       Always double-check that new
       variables are added APPEND-ONLY. Re-ordering variables can
       permanently BREAK the deployed proxy contract. */

    /// @dev The underlaying ERC20 token
    IERC20 internal _underlyingToken;

    /// @dev Decimals of the underlying token
    uint8 internal _underlyingDecimals;

    /// @dev TokenInfo Name property
    string internal _name;

    /// @dev TokenInfo Symbol property
    string internal _symbol;

    /// @dev ERC20 Allowances Storage
    mapping(address => mapping (address => uint256)) internal _allowances;

    /// @dev ERC777 operators support data
    ERC777Operators.Object internal _operators;

    function initialize(
        IERC20 underlyingToken,
        uint8 underlyingDecimals,
        string calldata name,
        string calldata symbol,
        ISuperfluid host
    )
        external
    {
        Proxiable._initialize();

        _owner = msg.sender;

        _host = host;

        _underlyingToken = underlyingToken;
        _underlyingDecimals = underlyingDecimals;

        _name = name;
        _symbol = symbol;
    }

    function proxiableUUID() public pure override returns (bytes32) {
        return keccak256("org.superfluid-finance.contracts.SuperToken.implementation");
    }

    function updateCode(address newAddress) external onlyOwner {
        return _updateCodeAddress(newAddress);
    }

    /**************************************************************************
     * ERC20 Token Info
     *************************************************************************/

    function name() external view override returns (string memory) {
        return _name;
    }

    function symbol() external view override returns (string memory) {
        return _symbol;
    }

    function decimals() external pure override returns (uint8) {
        return _STANDARD_DECIMALS;
    }

    /**************************************************************************
     * (private) Token Logics
     *************************************************************************/

    function _transferFrom(address spender, address holder, address recipient, uint amount)
        private returns (bool)
    {
        require(holder != address(0), _ERR_TRANSFER_FROM_ZERO_ADDRESS);
        require(recipient != address(0), _ERR_TRANSFER_TO_ZERO_ADDRESS);

        address operator = msg.sender;

        _callTokensToSend(operator, holder, recipient, amount, "", "");

        _move(operator, holder, recipient, amount, "", "");

        if (spender != holder) {
            _approve(
                holder,
                spender,
                _allowances[holder][spender].sub(amount, _ERR_TRANSFER_EXCEED_ALLOWANCE));
        }

        _callTokensReceived(operator, holder, recipient, amount, "", "", false);

        return true;
    }

    /**
     * @dev Send tokens
     * @param operator address operator address
     * @param from address token holder address
     * @param to address recipient address
     * @param amount uint256 amount of tokens to transfer
     * @param userData bytes extra information provided by the token holder (if any)
     * @param operatorData bytes extra information provided by the operator (if any)
     * @param requireReceptionAck if true, contract recipients are required to implement ERC777TokensRecipient
     */
    function _send(
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes memory userData,
        bytes memory operatorData,
        bool requireReceptionAck
    )
        private
    {
        require(from != address(0), _ERR_TRANSFER_FROM_ZERO_ADDRESS);
        require(to != address(0), _ERR_TRANSFER_TO_ZERO_ADDRESS);

        _callTokensToSend(operator, from, to, amount, userData, operatorData);

        _move(operator, from, to, amount, userData, operatorData);

        _callTokensReceived(operator, from, to, amount, userData, operatorData, requireReceptionAck);
    }

    function _move(
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes memory userData,
        bytes memory operatorData
    )
        private
    {
        require(balanceOf(from) >= amount, _ERR_TRANSFER_EXCEED_BALANCE);

        _settleBalance(from, -int256(amount));
        _settleBalance(to, int256(amount));

        emit Sent(operator, from, to, amount, userData, operatorData);
        emit Transfer(from, to, amount);
    }

    /**
     * @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * If a send hook is registered for `account`, the corresponding function
     * will be called with `operator`, `data` and `operatorData`.
     *
     * See {IERC777Sender} and {IERC777Recipient}.
     *
     * Emits {Minted} and {IERC20-Transfer} events.
     *
     * Requirements
     *
     * - `account` cannot be the zero address.
     * - if `account` is a contract, it must implement the {IERC777Recipient}
     * interface.
     */
    function _mint(
        address operator,
        address account,
        uint256 amount,
        bytes memory userData,
        bytes memory operatorData
    )
        internal
    {
        require(account != address(0), _ERR_MINT_TO_ZERO_ADDRESS);

        _settleBalance(account, int256(amount));

        _callTokensReceived(operator, address(0), account, amount, userData, operatorData, true);

        emit Minted(operator, account, amount, userData, operatorData);
        emit Transfer(address(0), account, amount);
    }

    /**
     * @dev Burn tokens
     * @param from address token holder address
     * @param amount uint256 amount of tokens to burn
     * @param data bytes extra information provided by the token holder
     * @param operatorData bytes extra information provided by the operator (if any)
     */
    function _burn(
        address operator,
        address from,
        uint256 amount,
        bytes memory data,
        bytes memory operatorData
    )
        internal
    {
        require(from != address(0), _ERR_BURN_FROM_ZERO_ADDRESS);

        _callTokensToSend(operator, from, address(0), amount, data, operatorData);

        // NB! Check balance after the _callTokensToSend is called
        require(balanceOf(from) >= amount, _ERR_BURN_EXCEED_BALANCE);

        // Update state variables
        _settleBalance(from, -int256(amount));

        emit Burned(operator, from, amount, data, operatorData);
        emit Transfer(from, address(0), amount);
    }

    /**
     * @notice Sets `amount` as the allowance of `spender` over the `account`s tokens.
     *
     * This is internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(address account, address spender, uint256 amount)
        private
    {
        require(account != address(0), _ERR_APPROVE_FROM_ZERO_ADDRESS);
        require(spender != address(0), _ERR_APPROVE_TO_ZERO_ADDRESS);

        _allowances[account][spender] = amount;
        emit Approval(account, spender, amount);
    }

    /**
     * @dev Call from.tokensToSend() if the interface is registered
     * @param operator address operator requesting the transfer
     * @param from address token holder address
     * @param to address recipient address
     * @param amount uint256 amount of tokens to transfer
     * @param userData bytes extra information provided by the token holder (if any)
     * @param operatorData bytes extra information provided by the operator (if any)
     */
    function _callTokensToSend(
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes memory userData,
        bytes memory operatorData
    )
        private
    {
        address implementer = _ERC1820_REGISTRY.getInterfaceImplementer(from, _TOKENS_SENDER_INTERFACE_HASH);
        if (implementer != address(0)) {
            IERC777Sender(implementer).tokensToSend(operator, from, to, amount, userData, operatorData);
        }
    }

    /**
     * @dev Call to.tokensReceived() if the interface is registered. Reverts if the recipient is a contract but
     * tokensReceived() was not registered for the recipient
     * @param operator address operator requesting the transfer
     * @param from address token holder address
     * @param to address recipient address
     * @param amount uint256 amount of tokens to transfer
     * @param userData bytes extra information provided by the token holder (if any)
     * @param operatorData bytes extra information provided by the operator (if any)
     * @param requireReceptionAck if true, contract recipients are required to implement ERC777TokensRecipient
     */
    function _callTokensReceived(
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes memory userData,
        bytes memory operatorData,
        bool requireReceptionAck
    )
        private
    {
        address implementer = _ERC1820_REGISTRY.getInterfaceImplementer(to, _TOKENS_RECIPIENT_INTERFACE_HASH);
        if (implementer != address(0)) {
            IERC777Recipient(implementer).tokensReceived(operator, from, to, amount, userData, operatorData);
        } else if (requireReceptionAck) {
            require(
                !to.isContract(),
                _ERR_NOT_ERC777RECIPIENT);
        }
    }

    /**************************************************************************
     * ERC20 Implementations
     *************************************************************************/

    function totalSupply()
        public view override returns (uint256)
    {
        return _underlyingToken.balanceOf(address(this));
    }

    function balanceOf(
        address account
    )
        public
        view
        override
        returns(uint256 balance)
    {
        // solhint-disable-next-line not-rely-on-time
        (int256 availableBalance, , ) = super.realtimeBalanceOf(account, block.timestamp);
        return availableBalance < 0 ? 0 : uint256(availableBalance);
    }

    function transfer(address recipient, uint256 amount)
        public override returns (bool)
    {
        return _transferFrom(msg.sender, msg.sender, recipient, amount);
    }

    function allowance(address account, address spender)
        public view override returns (uint256)
    {
        return _allowances[account][spender];
    }

    function approve(address spender, uint256 amount)
        public override
        returns (bool)
    {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address holder, address recipient, uint256 amount)
        public override returns (bool)
    {
        return _transferFrom(msg.sender, holder, recipient, amount);
    }

    /**************************************************************************
     * ERC-777 functions
     *************************************************************************/

    function granularity() external pure override returns (uint256) { return 1; }

    function send(address recipient, uint256 amount, bytes calldata data) external override {
        _send(msg.sender, msg.sender, recipient, amount, data, new bytes(0), true);
    }

    function burn(uint256 amount, bytes calldata data) external override {
        _downgrade(msg.sender, msg.sender, amount, data, new bytes(0));
    }

    function isOperatorFor(address operator, address tokenHolder) external override view returns (bool) {
        return _operators.isOperatorFor(operator, tokenHolder);
    }

    function authorizeOperator(address operator) external override {
        address holder = msg.sender;
        _operators.authorize(holder, operator);
        emit AuthorizedOperator(operator, holder);
    }

    function revokeOperator(address operator) external override {
        address holder = msg.sender;
        _operators.revoke(holder, operator);
        emit RevokedOperator(operator, holder);
    }

    function defaultOperators() external override view returns (address[] memory) {
        return _operators.defaultList();
    }

    function operatorSend(
        address sender,
        address recipient,
        uint256 amount,
        bytes calldata data,
        bytes calldata operatorData
    ) external override {
        address operator = msg.sender;
        require(_operators.isOperatorFor(operator, sender), _ERR_CALLER_NOT_AN_OPERATOR);
        _send(operator, sender, recipient, amount, data, operatorData, true);
    }

    function operatorBurn(
        address account,
        uint256 amount,
        bytes calldata data,
        bytes calldata operatorData
    ) external override {
        address operator = msg.sender;
        require(_operators.isOperatorFor(operator, account), _ERR_CALLER_NOT_AN_OPERATOR);
        _downgrade(operator, account, amount, data, operatorData);
    }

    /**************************************************************************
     * SuperToken extra functions
     *************************************************************************/

    function getHost()
        external view
        override(ISuperfluidToken)
        returns(address host)
    {
        return address(_host);
    }

    function transferAll(address recipient)
        external
        override
    {
        _transferFrom(msg.sender, msg.sender, recipient, balanceOf(msg.sender));
    }

    /**************************************************************************
     * ERC20 wrapping
     *************************************************************************/

    /// @dev ISuperfluidGovernance.getUnderlayingToken implementation
    function getUnderlayingToken() external view override returns(address) {
        return address(_underlyingToken);
    }

    /// @dev ISuperToken.upgrade implementation
    function upgrade(uint256 amount) external override {
        _upgrade(msg.sender, msg.sender, amount);
    }

    /// @dev ISuperToken.downgrade implementation
    function downgrade(uint256 amount) external override {
        _downgrade(msg.sender, msg.sender, amount, "", "");
    }

    function _upgrade(
        address operator,
        address account,
        uint256 amount
    ) private {
        uint256 underlyingAmount;
        (underlyingAmount, amount) = _toUnderlyingAmount(amount);
        _underlyingToken.transferFrom(account, address(this), underlyingAmount);
        _mint(operator, account, amount, "", "");
        emit TokenUpgraded(account, amount);
    }

    function _downgrade(
        address operator,
        address account,
        uint256 amount,
        bytes memory data,
        bytes memory operatorData) private {
        // - even though _burn will check the (actual) amount availability again
        // we need to first check it here
        // - in case of downcasting of decimals, actual amount can be smaller than
        // requested amount
        require(balanceOf(account) >= amount, _ERR_DOWNGRADE_EXCEED_BALANCE);
        uint256 underlyingAmount;
        (underlyingAmount, amount) = _toUnderlyingAmount(amount);
        _burn(operator, account, amount, data, operatorData);
        _underlyingToken.transfer(account, underlyingAmount);
        emit TokenDowngraded(account, amount);
    }

    function _toUnderlyingAmount(uint256 amount)
        private view
        returns (uint256 underlyingAmount, uint256 actualAmount)
    {
        uint256 factor;
        if (_underlyingDecimals < _STANDARD_DECIMALS) {
            factor = 10 ** (_STANDARD_DECIMALS - _underlyingDecimals);
            underlyingAmount = amount / factor;
            // remove precision errors
            actualAmount = underlyingAmount * factor;
        } else if (_underlyingDecimals > _STANDARD_DECIMALS) {
            factor = 10 ** (_underlyingDecimals - _STANDARD_DECIMALS);
            underlyingAmount = amount * factor;
            actualAmount = amount;
        } else {
            underlyingAmount = actualAmount = amount;
        }
    }

    /**************************************************************************
     * Superfluid Batch Operations
     *************************************************************************/

    function operationApprove(
        address account,
        address spender,
        uint256 amount
    )
        external override
        onlyHost
    {
        // FIXME correct operator
        _approve(account, spender, amount);
    }

    function operationTransferFrom(
        address account,
        address sender,
        address recipient,
        uint256 amount
    )
        external override
        onlyHost
    {
        // FIXME correct operator
        _transferFrom(account, sender, recipient, amount);
    }

    function operationUpgrade(address account, uint256 amount)
        external override
        onlyHost
    {
        // FIXME correct operator
        _upgrade(msg.sender, account, amount);
    }

    function operationDowngrade(address account, uint256 amount)
        external override
        onlyHost
    {
        // FIXME correct operator
        _downgrade(msg.sender, account, amount, new bytes(0), new bytes(0));
    }

}
