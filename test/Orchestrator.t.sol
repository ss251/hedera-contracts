// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {Orchestrator} from "../src/Orchestrator.sol";
import {HederaResponseCodes} from "hedera-smart-contracts/contracts/system-contracts/HederaResponseCodes.sol";
import {IHederaTokenService} from
    "hedera-smart-contracts/contracts/system-contracts/hedera-token-service/IHederaTokenService.sol";

contract MockHTS {
    struct TransferTokenCall {
        address token;
        address sender;
        address receiver;
        int64 amount;
        bool called;
    }

    struct CryptoTransferCall {
        address payer;
        int256 totalNegative;
        int256 totalPositive;
        bool called;
    }

    int64 public transferResponseCode;
    int64 public cryptoTransferResponseCode;
    TransferTokenCall public lastTransferToken;
    CryptoTransferCall public lastCryptoTransfer;

    constructor() {
        reset();
    }

    function reset() public {
        transferResponseCode = int64(HederaResponseCodes.SUCCESS);
        cryptoTransferResponseCode = int64(HederaResponseCodes.SUCCESS);
        delete lastTransferToken;
        delete lastCryptoTransfer;
    }

    function setTransferResponse(int64 code) external {
        transferResponseCode = code;
    }

    function setCryptoTransferResponse(int64 code) external {
        cryptoTransferResponseCode = code;
    }

    function transferToken(address token, address sender, address receiver, int64 amount)
        external
        returns (int64 responseCode)
    {
        lastTransferToken =
            TransferTokenCall({token: token, sender: sender, receiver: receiver, amount: amount, called: true});
        return transferResponseCode;
    }

    function cryptoTransfer(
        IHederaTokenService.TransferList calldata transferList,
        IHederaTokenService.TokenTransferList[] calldata
    ) external returns (int64 responseCode) {
        int256 negatives;
        int256 positives;
        for (uint256 i = 0; i < transferList.transfers.length; i++) {
            int64 amt = transferList.transfers[i].amount;
            if (amt < 0) {
                negatives += int256(-amt);
            } else {
                positives += int256(amt);
            }
        }

        lastCryptoTransfer = CryptoTransferCall({
            payer: transferList.transfers.length > 0 ? transferList.transfers[0].accountID : address(0),
            totalNegative: negatives,
            totalPositive: positives,
            called: true
        });
        return cryptoTransferResponseCode;
    }
}

contract MockHSS {
    int64 public scheduleResponseCode;
    uint256 private counter;
    address public lastSystemContract;
    bytes public lastCallData;

    mapping(address => int64) public scheduleStatus;

    constructor() {
        reset();
    }

    function reset() public {
        scheduleResponseCode = int64(HederaResponseCodes.SUCCESS);
        counter = 0;
    }

    function setScheduleResponse(int64 code) external {
        scheduleResponseCode = code;
    }

    function setScheduleStatus(address schedule, int64 code) external {
        scheduleStatus[schedule] = code;
    }

    function scheduleNative(address systemContractAddress, bytes calldata callData, address)
        external
        returns (int64 responseCode, address scheduleAddress)
    {
        lastSystemContract = systemContractAddress;
        lastCallData = callData;

        address schedule = address(uint160(0x1000 + ++counter));
        scheduleStatus[schedule] = int64(HederaResponseCodes.SUCCESS);
        return (scheduleResponseCode, schedule);
    }

    function authorizeSchedule(address schedule) external returns (int64 responseCode) {
        int64 status = scheduleStatus[schedule];
        if (status == 0) {
            return int64(HederaResponseCodes.INVALID_SCHEDULE_ID);
        }
        return status;
    }

    function signSchedule(address, bytes calldata) external pure returns (int64) {
        return int64(HederaResponseCodes.SUCCESS);
    }
}

contract MockHAS {
    struct Allowance {
        int256 amount;
        int64 responseCode;
    }

    mapping(address owner => mapping(address spender => Allowance)) internal allowances;

    constructor() {
        reset();
    }

    function reset() public {
        // nothing additional required; mappings default to zero
    }

    function setAllowance(address owner, address spender, int256 amount, int64 responseCode) external {
        allowances[owner][spender] = Allowance({amount: amount, responseCode: responseCode});
    }

    function hbarAllowance(address owner, address spender) external returns (int64 responseCode, int256 amount) {
        Allowance memory info = allowances[owner][spender];
        int64 resp = info.responseCode;
        if (resp == 0) {
            resp = int64(HederaResponseCodes.SUCCESS);
        }
        return (resp, info.amount);
    }

    function hbarApprove(address owner, address spender, int256 amount) external returns (int64) {
        allowances[owner][spender] = Allowance({amount: amount, responseCode: int64(HederaResponseCodes.SUCCESS)});
        return int64(HederaResponseCodes.SUCCESS);
    }
}

contract OrchestratorTest is Test {
    Orchestrator internal orchestrator;

    address internal constant HTS = address(0x167);
    address internal constant HSS = address(0x16b);
    address internal constant HAS = address(0x16a);

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal token = address(0x1234);

    function setUp() public {
        MockHTS htsImpl = new MockHTS();
        MockHSS hssImpl = new MockHSS();
        MockHAS hasImpl = new MockHAS();

        vm.etch(HTS, address(htsImpl).code);
        vm.etch(HSS, address(hssImpl).code);
        vm.etch(HAS, address(hasImpl).code);

        MockHTS(HTS).reset();
        MockHSS(HSS).reset();
        MockHAS(HAS).reset();

        orchestrator = new Orchestrator();
    }

    /*//////////////////////////////////////////////////////////////
                               Helpers
    //////////////////////////////////////////////////////////////*/

    function _defaultRecipients() internal view returns (address[] memory recips, uint32[] memory shares) {
        recips = new address[](2);
        recips[0] = alice;
        recips[1] = bob;

        shares = new uint32[](2);
        shares[0] = 60;
        shares[1] = 40;
    }

    function _createSplit() internal returns (bytes32 splitId) {
        (address[] memory recips, uint32[] memory shares) = _defaultRecipients();
        splitId = orchestrator.createSplit(recips, shares);
    }

    function _primeTokenDeposit(bytes32 splitId, uint256 amount) internal {
        MockHTS(HTS).setTransferResponse(int64(HederaResponseCodes.SUCCESS));
        orchestrator.depositToken(splitId, token, amount);
    }

    function _primeNativeDeposit(bytes32 splitId, uint256 amount) internal {
        orchestrator.depositNative{value: amount}(splitId);
    }

    /*//////////////////////////////////////////////////////////////
                              Unit Tests
    //////////////////////////////////////////////////////////////*/

    function testCreateSplitStoresRecipients() public {
        (address[] memory recips, uint32[] memory shares) = _defaultRecipients();
        bytes32 expectedId = keccak256(abi.encodePacked(address(this), uint256(1)));

        vm.expectEmit(true, true, true, true, address(orchestrator));
        emit Orchestrator.SplitCreated(expectedId, address(this), recips, shares);

        bytes32 splitId = orchestrator.createSplit(recips, shares);

        (address owner, bool exists, bool hbarMode) = orchestrator.splits(splitId);
        assertTrue(exists, "split not stored");
        assertEq(owner, address(this), "owner mismatch");
        assertFalse(hbarMode, "allowance flag default");
    }

    function testCreateSplitRevertsWhenSharesNotHundred() public {
        address[] memory recips = new address[](2);
        recips[0] = alice;
        recips[1] = bob;

        uint32[] memory shares = new uint32[](2);
        shares[0] = 50;
        shares[1] = 30;

        vm.expectRevert("Percentages must sum to 100");
        orchestrator.createSplit(recips, shares);
    }

    function testDepositTokenUpdatesBalance() public {
        bytes32 splitId = _createSplit();

        _primeTokenDeposit(splitId, 1_000);

        assertEq(orchestrator.balanceOf(splitId, token), 1_000, "custodial balance");
    }

    function testDepositTokenRevertsOnPrecompileFailure() public {
        bytes32 splitId = _createSplit();
        MockHTS(HTS).setTransferResponse(int64(HederaResponseCodes.INVALID_ACCOUNT_ID));

        vm.expectRevert("HTS deposit failed");
        orchestrator.depositToken(splitId, token, 10);
    }

    function testDepositTokenRevertsIfAmountTooLarge() public {
        bytes32 splitId = _createSplit();

        uint256 tooLarge = uint256(uint64(type(int64).max)) + 1;
        vm.expectRevert("Amount too large");
        orchestrator.depositToken(splitId, token, tooLarge);
    }

    function testDepositNativeUpdatesBalance() public {
        bytes32 splitId = _createSplit();

        _primeNativeDeposit(splitId, 5 ether);

        assertEq(orchestrator.balanceOf(splitId, address(0)), 5 ether, "native balance");
    }

    function testConfigureHbarAllowanceTogglesFlag() public {
        bytes32 splitId = _createSplit();

        orchestrator.configureHbarAllowance(splitId, true);
        (, bool exists, bool enabled) = orchestrator.splits(splitId);
        assertTrue(exists, "split missing");
        assertTrue(enabled, "flag not set");

        orchestrator.configureHbarAllowance(splitId, false);
        (,, enabled) = orchestrator.splits(splitId);
        assertFalse(enabled, "flag not reset");
    }

    function testConfigureHbarAllowanceRequiresOwner() public {
        bytes32 splitId = _createSplit();

        vm.prank(address(0xBEEF));
        vm.expectRevert("Not split owner");
        orchestrator.configureHbarAllowance(splitId, true);
    }

    function testDistributeConsumesCustodialBalance() public {
        bytes32 splitId = _createSplit();

        _primeTokenDeposit(splitId, 1_000);
        MockHTS(HTS).setCryptoTransferResponse(int64(HederaResponseCodes.SUCCESS));

        orchestrator.distribute(splitId, token, 400);

        assertEq(orchestrator.balanceOf(splitId, token), 600, "remaining balance");
    }

    function testDistributeRevertsWhenInsufficientAvailable() public {
        bytes32 splitId = _createSplit();

        _primeTokenDeposit(splitId, 500);
        MockHTS(HTS).setCryptoTransferResponse(int64(HederaResponseCodes.SUCCESS));

        orchestrator.distribute(splitId, token, 500);

        vm.expectRevert("Insufficient balance");
        orchestrator.distribute(splitId, token, 1);
    }

    function testScheduleDistributeReservesBalance() public {
        bytes32 splitId = _createSplit();

        _primeTokenDeposit(splitId, 1_000);
        MockHTS(HTS).setCryptoTransferResponse(int64(HederaResponseCodes.SUCCESS));
        MockHSS(HSS).setScheduleResponse(int64(HederaResponseCodes.SUCCESS));

        address schedule = orchestrator.scheduleDistribute(splitId, token, 300);

        assertEq(orchestrator.balanceOf(splitId, token), 1_000, "custodial untouched");
        assertEq(orchestrator.reservedOf(splitId, token), 300, "reserved amount");

        (bytes32 recordedSplit,, uint256 reservedAmount, bool active) = orchestrator.scheduledReservations(schedule);
        assertEq(recordedSplit, splitId, "reservation split id");
        assertEq(reservedAmount, 300, "reservation amount");
        assertTrue(active, "reservation active");
    }

    function testScheduleDistributeRevertsWhenAllowanceModeWithHBAR() public {
        bytes32 splitId = _createSplit();
        orchestrator.configureHbarAllowance(splitId, true);
        _primeNativeDeposit(splitId, 100);

        vm.expectRevert("Use allowance distribution");
        orchestrator.scheduleDistribute(splitId, address(0), 50);
    }

    function testFinalizeScheduledDistributionBurnsReservation() public {
        bytes32 splitId = _createSplit();

        _primeTokenDeposit(splitId, 1_000);
        MockHTS(HTS).setCryptoTransferResponse(int64(HederaResponseCodes.SUCCESS));
        address schedule = orchestrator.scheduleDistribute(splitId, token, 400);

        MockHSS(HSS).setScheduleStatus(schedule, int64(HederaResponseCodes.SCHEDULE_ALREADY_EXECUTED));

        orchestrator.finalizeScheduledDistribution(schedule);

        assertEq(orchestrator.reservedOf(splitId, token), 0, "reservation cleared");
        assertEq(orchestrator.balanceOf(splitId, token), 600, "balance reduced");

        (,, uint256 reservedAmount, bool active) = orchestrator.scheduledReservations(schedule);
        assertEq(reservedAmount, 0, "reservation amount cleared");
        assertFalse(active, "reservation inactive");
    }

    function testReleaseScheduledDistributionRestoresFunds() public {
        bytes32 splitId = _createSplit();

        _primeTokenDeposit(splitId, 1_000);
        MockHTS(HTS).setCryptoTransferResponse(int64(HederaResponseCodes.SUCCESS));
        address schedule = orchestrator.scheduleDistribute(splitId, token, 250);

        MockHSS(HSS).setScheduleStatus(schedule, int64(HederaResponseCodes.SCHEDULE_ALREADY_DELETED));

        orchestrator.releaseScheduledDistribution(schedule);

        assertEq(orchestrator.reservedOf(splitId, token), 0, "reservation cleared");
        assertEq(orchestrator.balanceOf(splitId, token), 1_000, "balance restored");

        (,, uint256 reservedAmount, bool active) = orchestrator.scheduledReservations(schedule);
        assertEq(reservedAmount, 0, "reservation amount cleared");
        assertFalse(active, "reservation inactive");
    }

    function testDistributeFromHbarAllowanceSpendsViaHAS() public {
        bytes32 splitId = _createSplit();
        orchestrator.configureHbarAllowance(splitId, true);

        MockHAS(HAS).setAllowance(address(this), address(orchestrator), 1_000, int64(HederaResponseCodes.SUCCESS));
        MockHTS(HTS).setCryptoTransferResponse(int64(HederaResponseCodes.SUCCESS));

        orchestrator.distributeFromHbarAllowance(splitId, 600);
    }

    function testDistributeFromHbarAllowanceRevertsWhenInsufficientAllowance() public {
        bytes32 splitId = _createSplit();
        orchestrator.configureHbarAllowance(splitId, true);

        MockHAS(HAS).setAllowance(address(this), address(orchestrator), 200, int64(HederaResponseCodes.SUCCESS));

        vm.expectRevert("Insufficient allowance");
        orchestrator.distributeFromHbarAllowance(splitId, 400);
    }

    function testRecordAgreementOwnerOnly() public {
        bytes32 splitId = _createSplit();

        orchestrator.recordAgreement(splitId, bytes32(uint256(0xABC)));
        assertEq(orchestrator.agreements(splitId), bytes32(uint256(0xABC)), "agreement stored");

        vm.prank(address(0xBEEF));
        vm.expectRevert("Not split owner");
        orchestrator.recordAgreement(splitId, bytes32(uint256(0xDEF)));
    }
}
