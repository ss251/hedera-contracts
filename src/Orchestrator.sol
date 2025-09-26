// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IHederaTokenService} from
    "hedera-smart-contracts/contracts/system-contracts/hedera-token-service/IHederaTokenService.sol";
import {IHederaAccountService} from
    "hedera-smart-contracts/contracts/system-contracts/hedera-account-service/IHederaAccountService.sol";
import {HederaResponseCodes} from "hedera-smart-contracts/contracts/system-contracts/HederaResponseCodes.sol";
import {IHederaScheduleService} from
    "hedera-smart-contracts/contracts/system-contracts/hedera-schedule-service/IHederaScheduleService.sol";

/**
 * @title Orchestrator
 * @notice Revenue splits with HTS transfers, HSS scheduled transactions, and Walrus agreements.
 */
contract Orchestrator {
    /// @dev HTS precompile address
    address constant HTS_PRECOMPILE = address(0x167);

    /// @dev HSS precompile address
    address constant HSS_PRECOMPILE = address(0x16b);

    /// @dev HAS precompile address
    address constant HAS_PRECOMPILE = address(0x16a);

    /// @dev Sentinel used to represent native HBAR within mappings
    address constant NATIVE_TOKEN = address(0);

    /// @dev Max positive value expressible as int64
    uint64 constant MAX_INT64 = uint64(type(int64).max);

    struct Split {
        address[] recipients;
        uint32[] percentages; // must sum to 100
        address owner;
        bool exists;
        bool hbarAllowanceEnabled;
    }

    mapping(bytes32 => Split) public splits;
    mapping(bytes32 => bytes32) public agreements;
    mapping(bytes32 => mapping(address => uint256)) private splitTokenBalances;
    mapping(bytes32 => mapping(address => uint256)) private reservedBalances;

    struct ScheduledReservation {
        bytes32 splitId;
        address token;
        uint256 amount;
        bool active;
    }

    mapping(address => ScheduledReservation) public scheduledReservations;

    uint256 private nextSplitId = 1;

    enum ScheduleStatus {
        Unknown,
        Pending,
        Executed,
        Deleted,
        Invalid
    }

    event SplitCreated(bytes32 indexed splitId, address indexed owner, address[] recipients, uint32[] percentages);
    event DistributionExecuted(bytes32 indexed splitId, address indexed token, uint256 amount);
    event DistributionScheduled(
        bytes32 indexed splitId, address indexed token, uint256 amount, address scheduleAddress
    );
    event AgreementRecorded(bytes32 indexed splitId, bytes32 blobId);
    event Deposit(bytes32 indexed splitId, address indexed token, uint256 amount, address indexed sender);
    event HbarAllowanceConfigured(bytes32 indexed splitId, bool enabled);
    event ScheduleReserved(bytes32 indexed splitId, address indexed token, uint256 amount, address scheduleAddress);
    event ScheduleReleased(bytes32 indexed splitId, address indexed token, uint256 amount, address scheduleAddress);
    event ScheduleFinalized(bytes32 indexed splitId, address indexed token, uint256 amount, address scheduleAddress);

    function balanceOf(bytes32 splitId, address token) external view returns (uint256) {
        return splitTokenBalances[splitId][token];
    }

    function reservedOf(bytes32 splitId, address token) external view returns (uint256) {
        return reservedBalances[splitId][token];
    }

    function availableBalance(bytes32 splitId, address token) public view returns (uint256) {
        uint256 total = splitTokenBalances[splitId][token];
        uint256 reserved = reservedBalances[splitId][token];
        require(reserved <= total, "Reserved exceeds balance");
        return total - reserved;
    }

    function createSplit(address[] calldata recipients, uint32[] calldata percentages) external returns (bytes32) {
        require(recipients.length == percentages.length, "Mismatched inputs");
        require(recipients.length > 0, "No recipients");

        uint32 total;
        for (uint256 i = 0; i < percentages.length; i++) {
            total += percentages[i];
        }
        require(total == 100, "Percentages must sum to 100");

        bytes32 splitId = keccak256(abi.encodePacked(msg.sender, nextSplitId));
        nextSplitId++;

        require(!splits[splitId].exists, "Split already exists");

        splits[splitId] = Split({
            recipients: recipients,
            percentages: percentages,
            owner: msg.sender,
            exists: true,
            hbarAllowanceEnabled: false
        });
        emit SplitCreated(splitId, msg.sender, recipients, percentages);
        return splitId;
    }

    function depositToken(bytes32 splitId, address token, uint256 amount) external {
        require(token != NATIVE_TOKEN, "Invalid token");
        require(amount > 0, "Amount required");

        Split storage split = splits[splitId];
        require(split.exists, "Split not found");

        int64 amount64 = _toInt64(amount);
        int64 responseCode =
            IHederaTokenService(HTS_PRECOMPILE).transferToken(token, msg.sender, address(this), amount64);
        require(responseCode == HederaResponseCodes.SUCCESS, "HTS deposit failed");

        splitTokenBalances[splitId][token] += amount;
        emit Deposit(splitId, token, amount, msg.sender);
    }

    function depositNative(bytes32 splitId) external payable {
        require(msg.value > 0, "Amount required");

        Split storage split = splits[splitId];
        require(split.exists, "Split not found");

        splitTokenBalances[splitId][NATIVE_TOKEN] += msg.value;
        emit Deposit(splitId, NATIVE_TOKEN, msg.value, msg.sender);
    }

    function configureHbarAllowance(bytes32 splitId, bool enabled) external {
        Split storage split = splits[splitId];
        require(split.exists, "Split not found");
        require(split.owner == msg.sender, "Not split owner");

        split.hbarAllowanceEnabled = enabled;
        emit HbarAllowanceConfigured(splitId, enabled);
    }

    function distributeFromHbarAllowance(bytes32 splitId, uint256 amount) external {
        Split storage split = splits[splitId];
        require(split.exists, "Split not found");
        require(split.hbarAllowanceEnabled, "Allowance disabled");
        require(amount > 0, "Amount required");

        int64 amount64 = _toInt64(amount);

        (int64 queryCode, int256 allowance) =
            IHederaAccountService(HAS_PRECOMPILE).hbarAllowance(split.owner, address(this));
        require(queryCode == HederaResponseCodes.SUCCESS, "HAS query failed");
        require(allowance >= int256(amount64), "Insufficient allowance");

        (
            IHederaTokenService.TransferList memory transferList,
            IHederaTokenService.TokenTransferList[] memory tokenTransfers
        ) = _buildTransferLists(split, split.owner, NATIVE_TOKEN, amount, true);

        int64 responseCode = IHederaTokenService(HTS_PRECOMPILE).cryptoTransfer(transferList, tokenTransfers);
        require(responseCode == HederaResponseCodes.SUCCESS, "HTS transfer failed");

        emit DistributionExecuted(splitId, NATIVE_TOKEN, amount);
    }

    function distribute(bytes32 splitId, address token, uint256 amount) external {
        Split storage split = splits[splitId];
        require(split.exists, "Split not found");
        require(amount > 0, "Amount required");

        address tokenKey = token == NATIVE_TOKEN ? NATIVE_TOKEN : token;
        require(availableBalance(splitId, tokenKey) >= amount, "Insufficient balance");

        (
            IHederaTokenService.TransferList memory transferList,
            IHederaTokenService.TokenTransferList[] memory tokenTransfers
        ) = _buildTransferLists(split, address(this), tokenKey, amount, false);

        int64 responseCode = IHederaTokenService(HTS_PRECOMPILE).cryptoTransfer(transferList, tokenTransfers);
        require(responseCode == HederaResponseCodes.SUCCESS, "HTS transfer failed");

        splitTokenBalances[splitId][tokenKey] -= amount;

        emit DistributionExecuted(splitId, tokenKey, amount);
    }

    /**
     * @notice Schedule a full distribution using Hedera Schedule Service (HSS).
     * @dev Builds transfer calldata for all recipients and submits to scheduleNative.
     */
    function scheduleDistribute(bytes32 splitId, address token, uint256 amount)
        external
        returns (address scheduleAddress)
    {
        Split storage split = splits[splitId];
        require(split.exists, "Split not found");
        require(amount > 0, "Amount required");

        address tokenKey = token == NATIVE_TOKEN ? NATIVE_TOKEN : token;
        require(!(tokenKey == NATIVE_TOKEN && split.hbarAllowanceEnabled), "Use allowance distribution");
        require(availableBalance(splitId, tokenKey) >= amount, "Insufficient balance");

        (
            IHederaTokenService.TransferList memory transferList,
            IHederaTokenService.TokenTransferList[] memory tokenTransfers
        ) = _buildTransferLists(split, address(this), tokenKey, amount, false);

        bytes memory callData =
            abi.encodeWithSelector(IHederaTokenService.cryptoTransfer.selector, transferList, tokenTransfers);

        (int64 responseCode, address scheduledAddress) =
            IHederaScheduleService(HSS_PRECOMPILE).scheduleNative(HTS_PRECOMPILE, callData, msg.sender);
        require(responseCode == HederaResponseCodes.SUCCESS, "HSS schedule creation failed");

        responseCode = IHederaScheduleService(HSS_PRECOMPILE).authorizeSchedule(scheduledAddress);
        require(responseCode == HederaResponseCodes.SUCCESS, "HSS authorize failed");

        ScheduledReservation storage reservation = scheduledReservations[scheduledAddress];
        require(!reservation.active, "Schedule already tracked");

        reservation.splitId = splitId;
        reservation.token = tokenKey;
        reservation.amount = amount;
        reservation.active = true;

        reservedBalances[splitId][tokenKey] += amount;

        emit DistributionScheduled(splitId, tokenKey, amount, scheduledAddress);
        emit ScheduleReserved(splitId, tokenKey, amount, scheduledAddress);
        return scheduledAddress;
    }

    function finalizeScheduledDistribution(address schedule) external {
        ScheduledReservation storage reservation = scheduledReservations[schedule];
        require(reservation.active, "Schedule not active");

        Split storage split = splits[reservation.splitId];
        require(split.exists, "Split not found");
        require(split.owner == msg.sender, "Not split owner");

        (ScheduleStatus status, bool statusKnown) = _getScheduleStatus(schedule);
        require(!statusKnown || status == ScheduleStatus.Executed, "Schedule not executed yet");

        address token = reservation.token;
        uint256 amount = reservation.amount;

        uint256 currentReserved = reservedBalances[reservation.splitId][token];
        require(currentReserved >= amount, "Reservation mismatch");
        reservedBalances[reservation.splitId][token] = currentReserved - amount;

        uint256 currentBalance = splitTokenBalances[reservation.splitId][token];
        require(currentBalance >= amount, "Balance underflow");
        splitTokenBalances[reservation.splitId][token] = currentBalance - amount;

        reservation.active = false;
        emit ScheduleFinalized(reservation.splitId, token, amount, schedule);
        delete scheduledReservations[schedule];
    }

    function releaseScheduledDistribution(address schedule) external {
        ScheduledReservation storage reservation = scheduledReservations[schedule];
        require(reservation.active, "Schedule not active");

        Split storage split = splits[reservation.splitId];
        require(split.exists, "Split not found");
        require(split.owner == msg.sender, "Not split owner");

        (ScheduleStatus status, bool statusKnown) = _getScheduleStatus(schedule);
        require(
            !statusKnown || status == ScheduleStatus.Deleted || status == ScheduleStatus.Invalid,
            "Schedule still active"
        );

        address token = reservation.token;
        uint256 amount = reservation.amount;

        uint256 currentReserved = reservedBalances[reservation.splitId][token];
        require(currentReserved >= amount, "Reservation mismatch");
        reservedBalances[reservation.splitId][token] = currentReserved - amount;

        reservation.active = false;
        emit ScheduleReleased(reservation.splitId, token, amount, schedule);
        delete scheduledReservations[schedule];
    }

    function recordAgreement(bytes32 splitId, bytes32 blobId) external {
        require(splits[splitId].exists, "Split not found");
        require(splits[splitId].owner == msg.sender, "Not split owner");

        agreements[splitId] = blobId;
        emit AgreementRecorded(splitId, blobId);
    }

    function _buildTransferLists(
        Split storage split,
        address payer,
        address token,
        uint256 amount,
        bool markAsAllowance
    )
        internal
        view
        returns (
            IHederaTokenService.TransferList memory transferList,
            IHederaTokenService.TokenTransferList[] memory tokenTransfers
        )
    {
        int64[] memory shares = _calculateShares(split.percentages, amount);
        int64 debit = _toInt64(amount);

        if (token == NATIVE_TOKEN) {
            IHederaTokenService.AccountAmount[] memory adjustments =
                new IHederaTokenService.AccountAmount[](split.recipients.length + 1);

            adjustments[0] =
                IHederaTokenService.AccountAmount({accountID: payer, amount: -debit, isApproval: markAsAllowance});

            for (uint256 i = 0; i < split.recipients.length; i++) {
                adjustments[i + 1] = IHederaTokenService.AccountAmount({
                    accountID: split.recipients[i],
                    amount: shares[i],
                    isApproval: false
                });
            }

            transferList = IHederaTokenService.TransferList({transfers: adjustments});
            tokenTransfers = new IHederaTokenService.TokenTransferList[](0);
        } else {
            IHederaTokenService.AccountAmount[] memory tokenAdjustments =
                new IHederaTokenService.AccountAmount[](split.recipients.length + 1);

            tokenAdjustments[0] =
                IHederaTokenService.AccountAmount({accountID: payer, amount: -debit, isApproval: markAsAllowance});

            for (uint256 i = 0; i < split.recipients.length; i++) {
                tokenAdjustments[i + 1] = IHederaTokenService.AccountAmount({
                    accountID: split.recipients[i],
                    amount: shares[i],
                    isApproval: false
                });
            }

            IHederaTokenService.TokenTransferList[] memory transfersArray =
                new IHederaTokenService.TokenTransferList[](1);

            transfersArray[0] = IHederaTokenService.TokenTransferList({
                token: token,
                transfers: tokenAdjustments,
                nftTransfers: new IHederaTokenService.NftTransfer[](0)
            });

            transferList = IHederaTokenService.TransferList({transfers: new IHederaTokenService.AccountAmount[](0)});
            tokenTransfers = transfersArray;
        }
    }

    function _calculateShares(uint32[] storage percentages, uint256 amount)
        internal
        view
        returns (int64[] memory shares)
    {
        require(amount <= MAX_INT64, "Amount too large");

        shares = new int64[](percentages.length);
        uint256 runningTotal;

        for (uint256 i = 0; i < percentages.length; i++) {
            uint256 share;
            if (i == percentages.length - 1) {
                share = amount - runningTotal;
            } else {
                share = (amount * percentages[i]) / 100;
                runningTotal += share;
            }

            shares[i] = _toInt64(share);
        }
    }

    function _toInt64(uint256 amount) internal pure returns (int64) {
        require(amount <= MAX_INT64, "Amount too large");
        return int64(int256(amount));
    }

    function _getScheduleStatus(address schedule) internal view returns (ScheduleStatus status, bool known) {
        bytes memory callData = abi.encodeWithSelector(IHederaScheduleService.authorizeSchedule.selector, schedule);
        (bool success, bytes memory result) = HSS_PRECOMPILE.staticcall(callData);
        if (!success || result.length < 32) {
            return (ScheduleStatus.Unknown, false);
        }

        int64 responseCode = abi.decode(result, (int64));

        if (
            responseCode == int64(HederaResponseCodes.SUCCESS)
                || responseCode == int64(HederaResponseCodes.SCHEDULE_PENDING_EXPIRATION)
        ) {
            return (ScheduleStatus.Pending, true);
        }

        if (responseCode == int64(HederaResponseCodes.SCHEDULE_ALREADY_EXECUTED)) {
            return (ScheduleStatus.Executed, true);
        }

        if (responseCode == int64(HederaResponseCodes.SCHEDULE_ALREADY_DELETED)) {
            return (ScheduleStatus.Deleted, true);
        }

        if (responseCode == int64(HederaResponseCodes.INVALID_SCHEDULE_ID)) {
            return (ScheduleStatus.Invalid, true);
        }

        return (ScheduleStatus.Unknown, false);
    }
}
