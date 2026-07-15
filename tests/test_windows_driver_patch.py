import struct
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
DRIVER_DIR = ROOT / "native" / "windows_bluetooth"
SAMPLES_PATCH = DRIVER_DIR / "windows-driver-samples.patch"
DIAGNOSTICS_PATCH = DRIVER_DIR / "windows-driver-diagnostics.patch"
SPECIFIC_PSM_PATCH = DRIVER_DIR / "windows-driver-specific-psm.patch"
RUNTIME_HARDENING_PATCH = (
    DRIVER_DIR / "windows-driver-runtime-hardening.patch"
)


def changed_lines(patch: str, prefix: str) -> str:
    return "\n".join(
        line[1:]
        for line in patch.splitlines()
        if line.startswith(prefix) and not line.startswith(prefix * 3)
    )


def patch_section(patch: str, file_name: str) -> str:
    marker = f"diff --git a/{file_name} b/{file_name}"
    start = patch.index(marker)
    end = patch.find("\ndiff --git ", start + len(marker))
    return patch[start:] if end == -1 else patch[start:end]


def patch_sections(patch: str, file_name: str) -> list[str]:
    marker = f"diff --git a/{file_name} b/{file_name}"
    sections = []
    cursor = 0
    while True:
        start = patch.find(marker, cursor)
        if start == -1:
            return sections
        end = patch.find("\ndiff --git ", start + len(marker))
        if end == -1:
            sections.append(patch[start:])
            return sections
        sections.append(patch[start:end])
        cursor = end + 1


class WindowsDriverSpecificPsmPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.patch = SPECIFIC_PSM_PATCH.read_text(encoding="utf-8")
        cls.added = changed_lines(cls.patch, "+")
        cls.removed = changed_lines(cls.patch, "-")

    def test_removes_forbidden_wildcard_hid_psm_registration(self):
        self.assertIn("BRB_REGISTER_PSM", self.removed)
        self.assertNotIn("BRB_REGISTER_PSM", self.added)
        self.assertNotIn("BRB_UNREGISTER_PSM", self.added)

    def test_registers_two_address_specific_hid_servers(self):
        self.assertIn("L2CAP_SERVER_HANDLE DeviceServerHandles[2]", self.added)
        self.assertIn("brb->BtAddress = BtAddress", self.added)
        self.assertIn("brb->PSM = DevCtx->Psms[index]", self.added)
        self.assertIn("BRB_L2CA_REGISTER_SERVER", self.added)
        self.assertIn("BRB_L2CA_UNREGISTER_SERVER", self.added)

    def test_defers_pairing_work_to_passive_level(self):
        self.assertIn("case IndicationPairDevice", self.added)
        self.assertIn("case IndicationUnpairDevice", self.added)
        self.assertIn("WdfWorkItemEnqueue(DevCtx->PairingWorkItem)", self.added)
        self.assertIn("BthEchoSrvPairingWorkItem", self.added)
        self.assertIn("WdfWaitLockAcquire(devCtx->RegistrationLock", self.added)

    def test_work_item_uses_explicit_locks_not_parent_serialization(self):
        initialize = self.added.index("WDF_WORKITEM_CONFIG_INIT")
        disable_automatic = self.added.index(
            "workItemConfig.AutomaticSerialization = FALSE", initialize
        )
        create = self.added.index("WdfWorkItemCreate", disable_automatic)
        self.assertLess(initialize, disable_automatic)
        self.assertLess(disable_automatic, create)

    def test_remove_path_stops_callbacks_flushes_and_unregisters(self):
        stopping = self.added.index("DevCtx->RegistrationStopping = TRUE")
        unregister_notifications = self.added.index(
            "BthEchoSrvUnregisterL2CAPServer(DevCtx)", stopping
        )
        flush = self.added.index("WdfWorkItemFlush(DevCtx->PairingWorkItem)")
        unregister_devices = self.added.index(
            "BthEchoSrvUnregisterDeviceServersLocked(DevCtx)", flush
        )
        self.assertLess(stopping, unregister_notifications)
        self.assertLess(unregister_notifications, flush)
        self.assertLess(flush, unregister_devices)


class WindowsDriverRuntimeHardeningPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.patch = RUNTIME_HARDENING_PATCH.read_text(encoding="utf-8")
        cls.added = changed_lines(cls.patch, "+")
        cls.bridge_sections = patch_sections(
            cls.patch, "bluetooth/bthecho/bthsrv/sys/bridge.c"
        )
        cls.bridge_section = "\n".join(cls.bridge_sections)
        cls.controller_cleanup_section = cls.bridge_sections[-1]
        cls.device_section = patch_section(
            cls.patch, "bluetooth/bthecho/bthsrv/sys/device.c"
        )
        cls.server_section = patch_section(
            cls.patch, "bluetooth/bthecho/bthsrv/sys/server.c"
        )
        cls.connection_section = patch_section(
            cls.patch, "bluetooth/bthecho/common/lib/connection.c"
        )
        cls.connection_h = changed_lines(
            patch_section(
                cls.patch, "bluetooth/bthecho/common/inc/connection.h"
            ),
            "+",
        )
        cls.bridge_c = changed_lines(cls.bridge_section, "+")
        cls.device_c = changed_lines(cls.device_section, "+")
        cls.device_h = changed_lines(
            patch_section(
                cls.patch, "bluetooth/bthecho/bthsrv/sys/device.h"
            ),
            "+",
        )
        cls.server_c = changed_lines(cls.server_section, "+")
        cls.connection_c = changed_lines(cls.connection_section, "+")
        cls.connection_removed = changed_lines(cls.connection_section, "-")

    def test_fifo_preserves_early_report_order_and_is_bounded(self):
        self.assertIn("#define SPLATPLOST_PACKET_FIFO_CAPACITY 128", self.device_h)
        self.assertIn("#define BTHECHOSAMPLE_NUM_CONTINUOUS_READERS 1", self.connection_h)
        self.assertIn("WdfIoQueueDispatchSequential", self.bridge_c)
        pop = self.bridge_c.index("devCtx->PacketFifoCount != 0")
        forward = self.bridge_c.index("WdfRequestForwardToIoQueue", pop)
        retrieve = self.bridge_c.index("WdfIoQueueRetrieveNextRequest")
        enqueue = self.bridge_c.index(
            "DevCtx->PacketFifoCount < SPLATPLOST_PACKET_FIFO_CAPACITY",
            retrieve,
        )
        self.assertLess(pop, forward)
        self.assertLess(retrieve, enqueue)
        self.assertIn("DevCtx->PacketFifoTail + 1", self.bridge_c)
        self.assertIn("A bounded overflow drops the newest packet", self.bridge_c)
        self.assertIn("DevCtx->PacketFifoDropped++", self.bridge_c)

    def test_bridge_is_attached_before_first_reader_submission(self):
        attach = self.device_section.index(
            "status = SplatplostBridgeConnectionAdded("
        )
        submit = self.device_section.index(
            "status = BthEchoConnectionObjectContinuousReaderSubmitReaders(",
            attach,
        )
        ready = self.device_section.index(
            "status = SplatplostBridgeConnectionReady(", submit
        )
        self.assertLess(attach, submit)
        self.assertLess(submit, ready)
        self.assertIn("Connection->BridgeReaderReady = TRUE", self.bridge_c)
        self.assertIn("BthEchoSrvQueueProvenAddress", self.bridge_c)

    def test_status_handles_coexist_with_one_data_controller(self):
        self.assertIn("WdfDeviceInitSetExclusive(DeviceInit, FALSE)", self.device_c)
        self.assertIn("SecurityContext->DesiredAccess", self.bridge_c)
        self.assertIn("GENERIC_READ | GENERIC_WRITE", self.bridge_c)
        self.assertIn("devCtx->ControllerFileObject = FileObject", self.bridge_c)
        self.assertIn("STATUS_SHARING_VIOLATION", self.bridge_c)
        self.assertGreaterEqual(
            self.bridge_c.count(
                "devCtx->ControllerFileObject == fileObject"
            ),
            2,
        )

    def test_controller_cleanup_cannot_leave_old_reads_for_new_owner(self):
        self.assertIn("queueConfig.PowerManaged = WdfFalse", self.bridge_c)
        self.assertIn("ControllerCleanupInProgress = TRUE", self.bridge_c)
        self.assertIn("WdfIoQueueRetrieveRequestByFileObject", self.bridge_c)
        self.assertIn("WdfRequestComplete(request, STATUS_CANCELLED)", self.bridge_c)
        drain = self.bridge_c.index("WdfIoQueueRetrieveRequestByFileObject")
        admit = self.bridge_c.index(
            "ControllerCleanupInProgress = FALSE", drain
        )
        self.assertLess(drain, admit)

    def test_controller_cleanup_closes_published_and_connecting_l2cap_channels(self):
        cleanup = self.controller_cleanup_section
        self.assertIn("SPLATPLOST_CLEANUP_CONNECTION_CAPACITY 4", cleanup)
        self.assertIn("devCtx->ControlConnection", cleanup)
        self.assertIn("devCtx->InterruptConnection", cleanup)
        self.assertIn("connection->TeardownRequested = TRUE", cleanup)
        self.assertIn("connection->BridgeReaderReady = FALSE", cleanup)

        reference = cleanup.index("WdfObjectReference(ConnectionObject)")
        teardown = cleanup.index("connection->TeardownRequested = TRUE", reference)
        cleanup_lock = cleanup.index(
            "WdfSpinLockAcquire(devCtx->ConnectionListLock)", teardown
        )
        list_scan = cleanup.index(
            "for (entry = devCtx->ConnectionList.Flink", cleanup_lock
        )
        list_snapshot = cleanup.index(
            "SplatplostReferenceConnectionForCleanupLocked(", list_scan
        )
        published_control = cleanup.index(
            "devCtx->ControlConnection,", list_snapshot
        )
        published_interrupt = cleanup.index(
            "devCtx->InterruptConnection,", published_control
        )
        detach_control = cleanup.index(
            "devCtx->ControlConnection = NULL", published_interrupt
        )
        detach_interrupt = cleanup.index(
            "devCtx->InterruptConnection = NULL", detach_control
        )
        detach_address = cleanup.index(
            "devCtx->BridgeRemoteAddress = BTH_ADDR_NULL", detach_interrupt
        )
        unlock = cleanup.index(
            "WdfSpinLockRelease(devCtx->ConnectionListLock)", detach_address
        )
        disconnect = cleanup.index("BthEchoSrvDisconnectConnection(", unlock)
        dereference = cleanup.index(
            "WdfObjectDereference(connectionObject)", disconnect
        )
        admit = cleanup.index(
            "devCtx->ControllerCleanupInProgress = FALSE", dereference
        )

        self.assertLess(reference, teardown)
        self.assertLess(cleanup_lock, list_scan)
        self.assertLess(list_scan, list_snapshot)
        self.assertLess(list_snapshot, published_control)
        self.assertLess(published_control, published_interrupt)
        self.assertLess(published_interrupt, detach_control)
        self.assertLess(detach_control, detach_interrupt)
        self.assertLess(detach_interrupt, detach_address)
        self.assertLess(detach_address, unlock)
        self.assertLess(unlock, disconnect)
        self.assertLess(disconnect, dereference)
        self.assertLess(dereference, admit)

        self.assertIn("ConnectionObject == NULL", cleanup)
        self.assertIn("ConnectionObjects[index] == ConnectionObject", cleanup)
        self.assertIn("connection->DeleteRequested", cleanup)
        self.assertIn("NT_ASSERT(connectionObject != NULL)", cleanup)
        self.assertIn("if (connectionObject == NULL)", cleanup)
        self.assertIn("SplatplostBridgeConnectionAdded/Ready", cleanup)
        self.assertIn("if (existing->Psm == Psm)", self.server_c)
        self.assertIn("CONNECT_RSP_RESULT_NO_RESOURCES", self.server_c)
        self.assertGreaterEqual(
            self.bridge_c.count("Connection->TeardownRequested"), 2
        )

        self.assertIn("BRB_L2CA_CLOSE_CHANNEL", self.connection_section)
        connecting = self.server_c.index(
            "connection->ConnectionState = ConnectionStateConnecting"
        )
        disconnecting = self.server_c.index(
            "connection->ConnectionState == ConnectionStateDisconnecting",
            connecting,
        )
        deferred_close = self.server_c.index(
            "BthEchoSrvRemoteDisconnectGuarded", disconnecting
        )
        self.assertLess(connecting, disconnecting)
        self.assertLess(disconnecting, deferred_close)
        guarded = self.server_section.index("BthEchoSrvRemoteDisconnectGuarded(")
        begin = self.server_section.index("BthEchoSrvBeginBrbSubmission", guarded)
        abandon = self.server_section.index(
            "SplatplostBridgeAbandonConnection", begin
        )
        send_close = self.server_section.index(
            "BthEchoConnectionObjectRemoteDisconnect", abandon
        )
        self.assertLess(begin, abandon)
        self.assertLess(abandon, send_close)

    def test_persisted_target_is_validated_and_generation_guarded(self):
        self.assertIn('L"ProvenRemoteAddress"', self.server_c)
        self.assertGreaterEqual(self.server_c.count("REG_QWORD"), 2)
        self.assertIn("BthEchoSrvIsValidRemoteAddress", self.server_c)
        self.assertIn("generation == devCtx->PairingGeneration", self.server_c)
        self.assertIn("DevCtx->PendingPairingPresent", self.server_c)
        self.assertIn("selection is", self.server_c)
        self.assertIn("authoritative even before its servers finish", self.server_c)
        self.assertIn("devCtx->DeviceServersReady = TRUE", self.server_c)
        self.assertIn("devCtx->TargetTransitioning = FALSE", self.server_c)

    def test_connect_acceptance_is_exact_and_rejects_teardown(self):
        self.assertIn("Psm != SPLATPLOST_CONTROL_PSM", self.server_c)
        self.assertIn("Psm != SPLATPLOST_INTERRUPT_PSM", self.server_c)
        self.assertIn("DevCtx->DeviceServerAddress != BtAddress", self.server_c)
        self.assertIn("DevCtx->RegistrationStopping", self.server_c)
        self.assertIn("!Connection->InConnectionList", self.bridge_c)
        self.assertIn("Connection->TeardownRequested", self.bridge_c)
        self.assertIn("Connection->DeleteRequested", self.bridge_c)
        publish_teardown = self.server_section.index("Serialize teardown intent")
        mark = self.server_section.index(
            "Connection->TeardownRequested = TRUE", publish_teardown
        )
        remove = self.server_section.index(
            "SplatplostBridgeConnectionRemoved(", mark
        )
        self.assertLess(mark, remove)

    def test_surprise_removal_gates_all_repeat_reader_submissions(self):
        self.assertIn("ActiveBrbSubmissions", self.added)
        self.assertIn("BrbRundownEvent", self.added)
        self.assertIn("connection->BeginBrbSubmission", self.server_c)
        self.assertIn("connection->EndBrbSubmission", self.server_c)
        self.assertIn("RepeatReader->Connection->BeginBrbSubmission", self.connection_c)
        self.assertIn("RepeatReader->Connection->EndBrbSubmission", self.connection_c)
        self.assertIn(
            "InterlockedCompareExchange(&RepeatReader->Stopping, 0, 0)",
            self.connection_c,
        )
        self.assertIn("WdfRequestCancelSentRequest", self.connection_c)
        self.assertIn("EX_RUNDOWN_REF SubmissionRundown", self.connection_h)
        self.assertIn("ExAcquireRundownProtection", self.connection_c)
        self.assertIn("ExReleaseRundownProtection", self.connection_c)
        self.assertIn("ExWaitForRundownProtectionRelease", self.connection_c)

    def test_reader_failure_callbacks_cannot_self_delete_at_passive_level(self):
        self.assertIn("KDPC FailureDpc", self.connection_h)
        failure_dpc = self.connection_c.index(
            "VOID\nBthEchoRepeatReaderFailureDpc"
        )
        callback = self.connection_c.index(
            "BthEchoConnectionObjectContReaderFailedCallback(", failure_dpc
        )
        stop_event = self.connection_c.index(
            "KeSetEvent(&repeatReader->StopEvent", callback
        )
        self.assertLess(callback, stop_event)

        outer_rundown = self.connection_c.index(
            "Hold an outer rundown reference across Submit"
        )
        outer_acquire = self.connection_c.index(
            "ExAcquireRundownProtection", outer_rundown
        )
        submit = self.connection_c.index(
            "status = BthEchoRepeatReaderSubmit(", outer_acquire
        )
        outer_release = self.connection_c.index(
            "ExReleaseRundownProtection", submit
        )
        self.assertLess(outer_acquire, submit)
        self.assertLess(submit, outer_release)

        cleanup_rundown = self.connection_section.rindex(
            "ExWaitForRundownProtectionRelease"
        )
        cleanup_stop = self.connection_section.index(
            "BthEchoRepeatReaderWaitForStop", cleanup_rundown
        )
        self.assertLess(cleanup_rundown, cleanup_stop)
        self.assertIn(
            "Invoke reader failed callback before setting the stop event",
            self.connection_removed,
        )

    def test_callback_and_request_lifetimes_are_explicit(self):
        self.assertIn("case IndicationAddReference", self.server_section)
        self.assertIn("case IndicationReleaseReference", self.server_section)
        self.assertIn("WdfObjectReference((WDFOBJECT)Context)", self.server_c)
        self.assertIn("WdfObjectDereference((WDFOBJECT)Context)", self.server_c)
        self.assertIn("WdfRequestReuse(", self.connection_c)
        self.assertIn("KeSetEvent(&Connection->DisconnectEvent", self.connection_c)
        self.assertIn("connection->ConnectDisconnectRequest = NULL", self.connection_c)
        self.assertIn(
            "KeInitializeEvent(&connection->DisconnectEvent, NotificationEvent, TRUE)",
            self.connection_c,
        )

    def test_repeat_reader_reuses_one_brb_memory_wrapper(self):
        self.assertIn("MemoryTransferBrb", self.added)
        self.assertIn("WdfMemoryCreatePreallocated(", self.connection_c)
        self.assertIn("RepeatReader->MemoryTransferBrb", self.connection_c)
        self.assertIn("_In_opt_ WDFMEMORY BrbMemory", self.added)
        reuse = self.connection_section.index(
            "status = WdfRequestReuse(RepeatReader->RequestPendingRead"
        )
        format_request = self.connection_section.index(
            "RepeatReader->MemoryTransferBrb", reuse
        )
        self.assertLess(reuse, format_request)
        self.assertNotIn(
            "DevCtxHdr->ProfileDrvInterface.BthReuseBrb((PBRB)brb",
            self.connection_c,
        )

    def test_stack_queues_input_and_write_failures_reach_user_mode(self):
        self.assertGreaterEqual(self.server_c.count("brb->IncomingQueueDepth"), 2)
        self.assertIn("status = BthEchoSrvSendEcho(", self.bridge_c)
        self.assertIn("WdfRequestComplete(Request, status)", self.bridge_c)
        echo_h = patch_section(
            self.patch, "bluetooth/bthecho/bthsrv/sys/echo.h"
        )
        self.assertIn("+NTSTATUS", echo_h)

    def test_sdp_request_reuse_failures_abort_before_ioctl(self):
        publish_reuse = self.server_c.index(
            "status = WdfRequestReuse(DevCtx->Header.Request"
        )
        publish_abort = self.server_c.index("goto exit", publish_reuse)
        publish_ioctl = self.server_c.index(
            "IOCTL_BTH_SDP_SUBMIT_RECORD", publish_abort
        )
        remove_reuse = self.server_c.index(
            "status = WdfRequestReuse(DevCtx->Header.Request", publish_ioctl
        )
        remove_abort = self.server_c.index("goto exit", remove_reuse)
        remove_ioctl = self.server_c.index(
            "IOCTL_BTH_SDP_REMOVE_RECORD", remove_abort
        )
        self.assertLess(publish_reuse, publish_abort)
        self.assertLess(publish_abort, publish_ioctl)
        self.assertLess(remove_reuse, remove_abort)
        self.assertLess(remove_abort, remove_ioctl)

    def test_status_ioctl_abi_remains_sixteen_bytes(self):
        samples = SAMPLES_PATCH.read_text(encoding="utf-8")
        diagnostics = DIAGNOSTICS_PATCH.read_text(encoding="utf-8")
        sample_added = changed_lines(samples, "+")
        diagnostic_added = changed_lines(diagnostics, "+")
        diagnostic_removed = changed_lines(diagnostics, "-")

        self.assertIn("CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)", sample_added)
        self.assertIn("ULONG ConnectedChannels;", sample_added)
        self.assertIn("ULONG Reserved;", diagnostic_removed)
        self.assertIn("NTSTATUS InitializationStatus;", diagnostic_added)
        self.assertIn("BTH_ADDR LocalAddress;", sample_added)
        self.assertNotIn("typedef struct _SPLATPLOST_STATUS", self.patch)
        self.assertEqual(struct.calcsize("<IIQ"), 16)


if __name__ == "__main__":
    unittest.main()
