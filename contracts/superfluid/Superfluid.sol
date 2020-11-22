// SPDX-License-Identifier: MIT
pragma solidity 0.7.4;
pragma experimental ABIEncoderV2;

import { Ownable } from "../access/Ownable.sol";
import { Proxiable } from "../upgradability/Proxiable.sol";
import { Proxy } from "../upgradability/Proxy.sol";

import {
    ISuperfluid,
    ISuperfluidGovernance,
    ISuperAgreement,
    ISuperApp,
    SuperAppDefinitions,
    ContextDefinitions,
    ISuperfluidToken,
    ISuperToken,
    IERC20
} from "../interfaces/superfluid/ISuperfluid.sol";

import { SuperToken } from "./SuperToken.sol";
import { AgreementBase } from "../agreements/AgreementBase.sol";

import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { SignedSafeMath } from "@openzeppelin/contracts/math/SignedSafeMath.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/SafeCast.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";


contract Superfluid is
    Proxiable,
    Ownable,
    ISuperfluid
{

    using SafeMath for uint256;
    using SafeCast for uint256;
    using SignedSafeMath for int256;

    enum Info {
        A_1_MANIFEST,
        A_2_DOWNSTREAM_WHITELIST,
        A_3_IMMUTABLE_CALLBACK,
        B_1_READONLY_CONTEXT,
        B_2_UPSTREAM_CONTEXT,
        B_3_CALL_JAIL_APP,
        C_2_TERMINATION_CALLBACK,
        C_3_REVERT_NO_REASON,
        C_4_GAS_LIMIT,
        E_2_GAS_REFUND,
        J_1_UPSTREAM_RESPONSABILITY
    }

    // ????? TODO
    uint64 constant private _GAS_RESERVATION = 5000;


    //
    // the context that only needed for the next external call
    //
    struct ExtCallContext {
        // callback stack level
        uint8 cbLevel;
        // type of call
        uint8 callType;
        // the system timestsamp
        uint256 timestamp;
        // The intended message sender for the call
        address msgSender;
        // For callbacks it is used to know which agreement function selector is called
        bytes4 agreementSelector;
    }

    //
    // the context that needed by the app
    //
    struct AppContext {
        // app allowance granted
        uint256 allowanceGranted;
        // app allowance wanted by the app callback
        uint256 allowanceWanted;
        // app allowance used, allowing negative values over a callback session
        int256 allowanceUsed;
    }

    struct FullContext {
        ExtCallContext extCall;
        AppContext app;
    }

    struct AppManifest {
        uint256 configWord;
    }

    /* WARNING: NEVER RE-ORDER VARIABLES! Always double-check that new
       variables are added APPEND-ONLY. Re-ordering variables can
       permanently BREAK the deployed proxy contract. */

    /// @dev Governance contract
    ISuperfluidGovernance internal _gov;

    /// @dev Agreement list indexed by agreement index minus one
    ISuperAgreement[] internal _agreementClasses;
    /// @dev Mapping between agreement type to agreement index (starting from 1)
    mapping (bytes32 => uint) internal _agreementClassIndices;

    /// @dev Super token logic contract
    ISuperToken internal _superTokenLogic;

    /// @dev App manifests
    mapping(ISuperApp => AppManifest) internal _appManifests;
    /// @dev Composite app white-listing: source app => (target app => isAllowed)
    mapping(ISuperApp => mapping(ISuperApp => bool)) internal _compositeApps;
    /// @dev Ctx stamp of the current transaction, it should always be cleared to
    ///      zero before transaction finishes
    bytes32 internal _ctxStamp;

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Proxiable
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    function initialize() external {
        Proxiable._initialize();
        _owner = msg.sender;
    }

    function proxiableUUID() public pure override returns (bytes32) {
        return keccak256("org.superfluid-finance.contracts.Superfluid.implementation");
    }

    function updateCode(address newAddress) external onlyOwner {
        return _updateCodeAddress(newAddress);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Governance
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    function getGovernance() external view override returns (ISuperfluidGovernance) {
        return _gov;
    }

    function setGovernance(ISuperfluidGovernance gov) external onlyOwner {
        _gov = gov;
    }

    /**************************************************************************
     * Agreement Whitelisting
     *************************************************************************/

    function registerAgreementClass(ISuperAgreement agreementClass) external onlyGovernance override {
        bytes32 agreementType = agreementClass.agreementType();
        require(_agreementClassIndices[agreementType] == 0,
            "SF: Agreement class already registered");
        require(_agreementClasses.length < 256,
            "SF: Support up to 256 agreement classes");
        // initialize the proxy
        Proxy proxy = new Proxy();
        proxy.initializeProxy(address(agreementClass));
        AgreementBase(address(proxy)).initialize();
        // register the agreement proxy
        _agreementClasses.push(ISuperAgreement(address(proxy)));
        _agreementClassIndices[agreementType] = _agreementClasses.length;
    }

    function updateAgreementClass(ISuperAgreement agreementClass) external onlyGovernance override {
        bytes32 agreementType = agreementClass.agreementType();
        uint idx = _agreementClassIndices[agreementType];
        require(idx != 0, "SF: Agreement class not registered");
        AgreementBase(address(_agreementClasses[idx - 1])).updateCode(address(agreementClass));
    }

    function isAgreementTypeListed(bytes32 agreementType)
        external view override
        returns (bool yes)
    {
        uint idx = _agreementClassIndices[agreementType];
        return idx != 0;
    }

    function isAgreementClassListed(ISuperAgreement agreementClass)
        public view override
        returns (bool yes)
    {
        bytes32 agreementType = agreementClass.agreementType();
        uint idx = _agreementClassIndices[agreementType];
        // it should also be the same agreement class proxy address
        return idx != 0 && _agreementClasses[idx - 1] == agreementClass;
    }

    function getAgreementClass(bytes32 agreementType)
        external view override
        returns(ISuperAgreement agreementClass)
    {
        uint idx = _agreementClassIndices[agreementType];
        require(idx != 0, "SF: Agreement class not registered");
        return ISuperAgreement(_agreementClasses[idx - 1]);
    }

    function mapAgreementClasses(uint256 bitmap)
        external view override
        returns (ISuperAgreement[] memory agreementClasses) {
        uint i;
        uint n;
        // create memory output using the counted size
        agreementClasses = new ISuperAgreement[](_agreementClasses.length);
        // add to the output
        n = 0;
        for (i = 0; i < _agreementClasses.length; ++i) {
            if ((bitmap & (1 << i)) > 0) {
                agreementClasses[n++] = _agreementClasses[i];
            }
        }
        // resize memory arrays
        assembly { mstore(agreementClasses, n) }
    }

    function addToAgreementClassesBitmap(uint256 bitmap, bytes32 agreementType)
        external view override
        returns (uint256 newBitmap)
    {
        uint idx = _agreementClassIndices[agreementType];
        require(idx != 0, "SF: Agreement class not registered");
        return bitmap | (1 << (idx - 1));
    }

    function removeFromAgreementClassesBitmap(uint256 bitmap, bytes32 agreementType)
        external view override
        returns (uint256 newBitmap)
    {
        uint idx = _agreementClassIndices[agreementType];
        require(idx != 0, "SF: Agreement class not registered");
        return bitmap & ~(1 << (idx - 1));
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // ERC20 Token Registry
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    function setSuperTokenLogic(ISuperToken logic) external onlyOwner {
        _superTokenLogic = logic;
    }

    function getSuperTokenLogic() external view override returns (ISuperToken) {
        return _superTokenLogic;
    }

    function getERC20Wrapper(
        IERC20 underlyingToken,
        string calldata symbol
    )
        external view override
        returns (address wrapperAddress, bool created)
    {
        bytes32 salt = _genereateERC20WrapperSalt(underlyingToken, symbol);
        wrapperAddress = Create2.computeAddress(salt, keccak256(type(Proxy).creationCode));
        created = Address.isContract(wrapperAddress);
    }

    function createERC20Wrapper(
        IERC20 underlyingToken,
        uint8 underlyingDecimals,
        string calldata name,
        string calldata symbol
    )
        external override
    {
        require(address(underlyingToken) != address(0), "SF: createERC20Wrapper zero address");
        bytes32 salt = _genereateERC20WrapperSalt(underlyingToken, symbol);
        address wrapperAddress = Create2.computeAddress(salt, keccak256(type(Proxy).creationCode));
        require(!Address.isContract(wrapperAddress), "SF: createERC20Wrapper wrapper exist");
        Proxy proxy = new Proxy{salt: salt}();
        proxy.initializeProxy(address(_superTokenLogic));
        require(wrapperAddress == address(proxy), "SF: createERC20Wrapper unexpected address");
        // initialize the token
        SuperToken superToken = SuperToken(address(proxy));
        superToken.initialize(
            underlyingToken,
            underlyingDecimals,
            name,
            symbol,
            this
        );
    }

    function _genereateERC20WrapperSalt(
        IERC20 underlyingToken,
        string calldata symbol
    )
        private pure
        returns (bytes32 salt)
    {
        return keccak256(abi.encodePacked(
            underlyingToken,
            symbol
        ));
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // App Registry
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Message sender declares it as a super app.
     * @param configWord The super app manifest configuration
     */
    function registerApp(
        uint256 configWord
    )
        external override
    {
        require(configWord > 0, "SF: invalid config word");
        require(_appManifests[ISuperApp(msg.sender)].configWord == 0 , "SF: app already registered");
        _appManifests[ISuperApp(msg.sender)] = AppManifest(configWord);
    }

    function isApp(ISuperApp app) public view override returns(bool) {
        return _appManifests[app].configWord > 0;
    }

    function getAppLevel(ISuperApp appAddr) public override view returns(uint8) {
        if (_appManifests[appAddr].configWord & SuperAppDefinitions.TYPE_APP_FINAL > 0) {
            return 1;
        } else if (_appManifests[appAddr].configWord & SuperAppDefinitions.TYPE_APP_SECOND > 0) {
            return 2;
        }
        return 0;
    }

    function getAppManifest(
        ISuperApp app
    )
        external view override
    returns (
        bool isSuperApp,
        bool isJailed,
        uint256 noopMask
    )
    {
        AppManifest memory manifest = _appManifests[app];
        isSuperApp = (manifest.configWord > 0);
        if (isSuperApp) {
            isJailed = manifest.configWord & SuperAppDefinitions.JAIL > 0;
            noopMask = manifest.configWord & SuperAppDefinitions.AGREEMENT_CALLBACK_NOOP_BITMASKS;
        }
    }

    function isAppJailed(
        ISuperApp app
    )
        public view override
        returns(bool)
    {
        return (_appManifests[app].configWord & SuperAppDefinitions.JAIL) > 0;
    }

    /**
     * @notice White-list the target app for app composition for the source app `msg.sender`
     * @param targetApp The taget super app address
     */
    function allowCompositeApp(
        ISuperApp targetApp
    )
        external override
    {
        require(isApp(ISuperApp(msg.sender)), "SF: msg.sender is not an app");
        require(isApp(targetApp), "SF: target is not an app");
        _compositeApps[ISuperApp(msg.sender)][targetApp] = true;
    }

    function isCompositeAppAllowed(
        ISuperApp app,
        ISuperApp targetApp
    )
        external view override
        returns (bool)
    {
        return _compositeApps[app][targetApp];
    }


    /**************************************************************************
     * Agreement Callback System
     *************************************************************************/

    //Split the callback in the two functions so they can have different rules and returns data formats
    //TODO : msg.sender should be only SuperAgreement
    function callAppBeforeCallback(
        ISuperApp app,
        bytes calldata data,
        bool isTermination,
        bytes calldata /* ctx */
    )
        external override
        onlyAgreement
        isAppActive(app) // although agreement library should make sure it is an app, but we decide to double check it
        returns(bytes memory cbdata, bytes memory /*newCtx*/)
    {
        (bool success, bytes memory returnedData) = _callCallback(app, data, true);
        if (success) {
            cbdata = abi.decode(returnedData, (bytes));
        } else {
            if (!isTermination) {
                revert("SF: before callback failed");
            } else {
                emit Jail(app, uint256(Info.C_2_TERMINATION_CALLBACK));
            }
        }
    }

    function callAppAfterCallback(
        ISuperApp app,
        bytes calldata data,
        bool isTermination,
        bytes calldata /* ctx */
    )
        external override
        onlyAgreement
        isAppActive(app) // although agreement library should make sure it is an app, but we decide to double check it
        returns(bytes memory newCtx)
    {
        (bool success, bytes memory returnedData) = _callCallback(app, data, false);
        if (success) {
            newCtx = abi.decode(returnedData, (bytes));
            if(!_isCtxValid(newCtx)) {
                // TODO: JAIL if callback changes ctx and Change return context
                if (!isTermination) {
                    revert("SF: B_1_READONLY_CONTEXT");
                } else {
                    emit Jail(app, uint256(Info.B_1_READONLY_CONTEXT));
                }
            }
        } else {
            if (!isTermination) {
                revert("SF: after callback failed");
            } else {
                emit Jail(app, uint256(Info.C_2_TERMINATION_CALLBACK));
            }
        }
    }

    function appCallbackPush(
        bytes calldata ctx,
        uint256 allowanceGranted,
        int256 allowanceUsed
    )
        external override
        onlyAgreement
        returns (bytes memory appCtx)
    {
        FullContext memory appContext = _decodeFullContext(ctx);
        appContext.extCall.cbLevel++;
        appContext.extCall.callType = ContextDefinitions.CALL_INFO_CALL_TYPE_APP_CALLBACK;
        appContext.app.allowanceGranted = allowanceGranted;
        appContext.app.allowanceWanted = 0;
        appContext.app.allowanceUsed = allowanceUsed;
        appCtx = _updateContext(appContext);
    }

    function appCallbackPop(
        bytes calldata ctx,
        int256 allowanceUsedDelta
    )
        external override
        onlyAgreement
        returns (bytes memory newCtx)
    {
        FullContext memory context = _decodeFullContext(ctx);
        context.app.allowanceUsed = context.app.allowanceUsed.add(allowanceUsedDelta);
        newCtx = _updateContext(context);
    }

    function ctxUseAllowance(
        bytes calldata ctx,
        uint256 allowanceWantedMore,
        int256 allowanceUsedDelta
    )
        external override
        onlyAgreement
        returns (bytes memory newCtx)
    {
        FullContext memory context = _decodeFullContext(ctx);

        context.app.allowanceWanted = context.app.allowanceWanted.add(allowanceWantedMore);
        context.app.allowanceUsed = context.app.allowanceUsed.add(allowanceUsedDelta);

        newCtx = _updateContext(context);
    }

    /**************************************************************************
    * Non-app Call Proxies
    *************************************************************************/

    function callAgreement(
        ISuperAgreement agreementClass,
        bytes memory data
    )
        public override
        cleanCtx
        isAgreement(agreementClass)
        returns(bytes memory returnedData)
    {
        //Build context data
        bytes memory ctx;
        // beaware of the endiness
        bytes4 agreementSelector = bytes4(
            uint32(uint8(data[3])) |
            (uint32(uint8(data[2])) << 8) |
            (uint32(uint8(data[1])) << 16) |
            (uint32(uint8(data[0])) << 24));
        ctx = _updateContext(FullContext({
            extCall: ExtCallContext({
                cbLevel: 0,
                callType: ContextDefinitions.CALL_INFO_CALL_TYPE_AGREEMENT,
                /* solhint-disable-next-line not-rely-on-time */
                timestamp: block.timestamp,
                msgSender: msg.sender,
                agreementSelector: agreementSelector
            }),
            app: AppContext({
                allowanceGranted: 0,
                allowanceWanted: 0,
                allowanceUsed: 0
            })
        }));
        bool success;
        (success, returnedData) = _callExternal(address(agreementClass), data, ctx);
        if (success) {
            _ctxStamp = 0;
        } else {
            revert(_getRevertMsg(returnedData));
        }
    }

    function callAppAction(
        ISuperApp app,
        bytes memory data
    )
        public override
        cleanCtx
        isAppActive(app)
        returns(bytes memory returnedData)
    {
        require(!isAppJailed(app), "SF: App already jailed");

        //Build context data
        //TODO: Where we get the gas reservation?
        bool success;

        bytes memory ctx;
        ctx = _updateContext(FullContext({
            extCall: ExtCallContext({
                cbLevel: 0,
                callType: ContextDefinitions.CALL_INFO_CALL_TYPE_APP_ACTION,
                /* solhint-disable-next-line not-rely-on-time */
                timestamp: block.timestamp,
                msgSender: msg.sender,
                agreementSelector: 0
            }),
            app: AppContext({
                allowanceGranted: 0,
                allowanceWanted: 0,
                allowanceUsed: 0
            })
        }));
        (success, returnedData) = _callExternal(address(app), data, ctx);
        if(!success) {
            revert(_getRevertMsg(returnedData));
        }
        _ctxStamp = 0;
    }

    function batchCall(
       Operation[] memory operations
    )
       external override
    {
        require(operations.length > 1, "SF: Use the single method");
        for(uint256 i = 0; i < operations.length; i++) {
            OperationType opType = operations[i].opType;
            /*  */ if (opType == OperationType.Approve) {
                (address spender, uint256 amount) =
                    abi.decode(operations[i].data, (address, uint256));
                ISuperToken(operations[i].target).operationApprove(
                    msg.sender,
                    spender,
                    amount);
            } else if (opType == OperationType.TransferFrom) {
                (address sender, address receiver, uint256 amount) =
                    abi.decode(operations[i].data, (address, address, uint256));
                ISuperToken(operations[i].target).operationTransferFrom(
                    msg.sender,
                    sender,
                    receiver,
                    amount);
            } else if (opType == OperationType.Upgrade) {
                ISuperToken(operations[i].target).operationUpgrade(
                    msg.sender,
                    abi.decode(operations[i].data, (uint256)));
            } else if (opType == OperationType.Downgrade) {
                ISuperToken(operations[i].target).operationDowngrade(
                    msg.sender,
                    abi.decode(operations[i].data, (uint256)));
            } else if (opType == OperationType.CallAgreement) {
               callAgreement(
                   ISuperAgreement(operations[i].target),
                   operations[i].data);
            } else if (opType == OperationType.CallApp) {
               callAppAction(
                   ISuperApp(operations[i].target),
                   operations[i].data);
            } else {
               revert("SF: unknown operation type");
            }
        }
    }

    /**************************************************************************
     * Contextual Call Proxy and Context Utilities
     *************************************************************************/
    function callAgreementWithContext(
        ISuperAgreement agreementClass,
        bytes calldata data,
        bytes calldata ctx
    )
        external override
        isAgreement(agreementClass)
        validCtx(ctx)
        returns(bytes memory newCtx, bytes memory returnedData)
    {
        FullContext memory context = _decodeFullContext(ctx);
        address oldSender = context.extCall.msgSender;

        context.extCall.msgSender = msg.sender;
        newCtx = _updateContext(context);

        bool success;
        (success, returnedData) = _callExternal(address(agreementClass), data, newCtx);
        if (success) {
            (newCtx) = abi.decode(returnedData, (bytes));
            assert(_isCtxValid(newCtx));
            // back to old msg.sender
            context = _decodeFullContext(newCtx);
            context.extCall.msgSender = oldSender;
            newCtx = _updateContext(context);
        } else {
            revert(_getRevertMsg(returnedData));
        }
    }

    function callAppActionWithContext(
        ISuperApp app,
        bytes calldata data,
        bytes calldata ctx
    )
        external override
        validCtx(ctx)
        returns(bytes memory newCtx)
    {
        FullContext memory context = _decodeFullContext(ctx);
        address oldSender = context.extCall.msgSender;

        // FIXME max app level check
        context.extCall.msgSender = msg.sender;
        newCtx = _updateContext(context);

        (bool success, bytes memory returnedData) = _callExternal(address(app), data, newCtx);
        if (success) {
            (newCtx) = abi.decode(returnedData, (bytes));
            require(_isCtxValid(newCtx), "SF: app altering the ctx");
            // back to old msg.sender
            context = _decodeFullContext(newCtx);
            context.extCall.msgSender = oldSender;
            newCtx = _updateContext(context);
        } else {
            revert(_getRevertMsg(returnedData));
        }
    }

    function chargeGasFee(
        bytes calldata ctx,
        uint fee
    )
        external override
        validCtx(ctx)
        returns (bytes memory newCtx)
    {
        // FIXME do some non-sense with the fee for now
       // solhint-disable-next-line no-empty-blocks
        for (uint i = 0; i < fee; ++i) { }
        newCtx = ctx;
    }

    function decodeCtx(bytes calldata ctx)
        external pure override
        returns (
            uint256 callInfo,
            uint256 timestamp,
            address msgSender,
            bytes4 agreementSelector,
            uint256 appAllowanceGranted,
            uint256 appAllowanceWanted,
            int256 appAllowanceUsed
        )
    {
        FullContext memory context = _decodeFullContext(ctx);
        callInfo = ContextDefinitions.encodeCallInfo(context.extCall.cbLevel, context.extCall.callType);
        timestamp = context.extCall.timestamp;
        msgSender = context.extCall.msgSender;
        agreementSelector = context.extCall.agreementSelector;
        appAllowanceGranted = context.app.allowanceGranted;
        appAllowanceWanted = context.app.allowanceWanted;
        appAllowanceUsed = context.app.allowanceUsed;
    }

    function _decodeFullContext(bytes memory ctx)
        private pure
        returns (FullContext memory context)
    {
        uint256 callInfo;
        uint256 allowanceIO;
        (
            callInfo,
            context.extCall.timestamp,
            context.extCall.msgSender,
            context.extCall.agreementSelector,
            allowanceIO,
            context.app.allowanceUsed
        ) = abi.decode(ctx, (uint256, uint256, address, bytes4, uint256, int256));
        (context.extCall.cbLevel, context.extCall.callType) = ContextDefinitions.decodeCallInfo(callInfo);
        context.app.allowanceGranted = allowanceIO & type(uint128).max;
        context.app.allowanceWanted = allowanceIO >> 128;
    }

    function _updateContext(FullContext memory context)
        private
        returns (bytes memory ctx)
    {
        uint256 callInfo = ContextDefinitions.encodeCallInfo(context.extCall.cbLevel, context.extCall.callType);
        uint256 allowanceIO =
            context.app.allowanceGranted.toUint128() |
            (uint256(context.app.allowanceWanted.toUint128()) << 128);
        ctx = abi.encode(
            callInfo,
            context.extCall.timestamp,
            context.extCall.msgSender,
            context.extCall.agreementSelector,
            allowanceIO,
            context.app.allowanceUsed
        );
        _ctxStamp = keccak256(ctx);
    }

    function _isCtxValid(bytes memory ctx) private view returns (bool) {
        return ctx.length != 0 && keccak256(ctx) == _ctxStamp;
    }

    function _callExternal(
        address target,
        bytes memory data,
        bytes memory ctx
    )
        private
        returns(bool success, bytes memory returnedData)
    {
        // STEP 1 : replace placeholder ctx with actual ctx
        // ctx needs to be padded to align with 32 bytes bouondary
        uint256 paddedLength = (ctx.length / 32 + 1) * 32;
        // ctx length has to be stored in the length word of placehoolder ctx
        // we support up to 2^16 length of the data
        data[data.length - 2] = byte(uint8(ctx.length >> 8));
        data[data.length - 1] = byte(uint8(ctx.length));
        // pack data with the replacement ctx
        ctx = abi.encodePacked(
            data,
            ctx, new bytes(paddedLength - ctx.length) // ctx padding
        );

        // STEP 2: Call external with replaced context
        // FIXME make sure existence of target due to EVM rule
        /* solhint-disable-next-line avoid-low-level-calls */
        (success, returnedData) = target.call(ctx);
    }

    function _callCallback(
        ISuperApp app,
        bytes memory data,
        bool isStaticall
    )
        private
        returns(bool success, bytes memory returnedData)
    {
        //uint256 gasBudget = gasleft() - _GAS_RESERVATION;
        (success, returnedData) = isStaticall ?
            /* solhint-disable-next-line avoid-low-level-calls*/
            address(app).staticcall(data) : address(app).call(data);

         if (!success) {
             if (gasleft() < _GAS_RESERVATION) {
                 // this is out of gas, but the call may still fail if m_callCallbackore gas is provied
                 // and this is okay, because there can be incentive to jail the app by providing
                 // more gas
                 revert("SF: try with more gas");
             } else {
                revert(_getRevertMsg(returnedData));
                 //_appManifests[app].configWord |= SuperAppDefinitions.JAIL;
             }
         }
    }

    /// @dev Get the revert message from a call
    /// @notice This is needed in order to get the human-readable revert message from a call
    /// @param res Response of the call
    /// @return Revert message string
    function _getRevertMsg(bytes memory res) internal pure returns (string memory) {
        // If the _res length is less than 68, then the transaction failed silently (without a revert message)
        if (res.length < 68) return "SF: target reverted";
        assembly {
            // Slice the sighash.
            res := add(res, 0x04)
        }
        return abi.decode(res, (string)); // All that remains is the revert string
    }

    modifier cleanCtx() {
        require(_ctxStamp == 0, "SF: Ctx is not clean");
        _;
    }

    modifier validCtx(bytes memory ctx) {
        if(!_isCtxValid(ctx)) {
            _appManifests[ISuperApp(msg.sender)].configWord |= SuperAppDefinitions.JAIL;
            emit Jail(ISuperApp(msg.sender), uint256(Info.B_1_READONLY_CONTEXT));
        } else {
            _;
        }
    }

    modifier isAgreement(ISuperAgreement agreementClass) {
        require(isAgreementClassListed(agreementClass), "SF: Only listed agreeement allowed");
        _;
    }

    modifier onlyGovernance() {
        require(msg.sender == address(_gov), "SF: Only governance allowed");
        _;
    }

    modifier onlyAgreement() {
        require(isAgreementClassListed(ISuperAgreement(msg.sender)), "SF: Sender is not listed agreeement");
        _;
    }

    modifier isAppActive(ISuperApp app) {
        uint256 w = _appManifests[app].configWord;
        require( w > 0 && (w & SuperAppDefinitions.JAIL) == 0, "SF: not an active app");
        _;
    }
}
