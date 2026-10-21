import Combine
import Foundation
import IOKit.hid

/// The button on a DJI Mic Mini transmitter, seen through its USB receiver. The receiver is a USB
/// composite device: an audio interface (the microphone) and a HID interface that reports the
/// transmitter button as a consumer-control key (Volume Up). Nemo opens only the HID interface,
/// exclusively ("seize"), so the press no longer changes the system volume and toggles dictation
/// instead. The microphone is untouched. Needs the Input Monitoring permission. Main-thread only.
final class MicButton: ObservableObject {
    static let shared = MicButton()
    static let vendorID = 0x2CA3
    static let productID = 0x4011
    /// Consumer page (0x0C), Volume Increment (0xE9): what the receiver sends for the transmitter button.
    static let triggerPage: UInt32 = 0x0C
    static let triggerUsage: UInt32 = 0xE9

    enum Status: Equatable {
        case off
        case needsPermission        // Input Monitoring not granted (yet)
        case waitingForDevice       // listening, receiver not connected
        case ready(blocking: Bool)  // receiver connected; blocking = opened exclusively
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    var onPress: () -> Void = {}

    private var manager: IOHIDManager?
    private var connected = 0
    private var seized = false
    private var permissionPoll: Timer?

    func setEnabled(_ on: Bool) {
        if on { start() } else { stop() }
    }

    private func start() {
        guard manager == nil else { return }
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        DebugLog.write("mic button · Input Monitoring access \(access == kIOHIDAccessTypeGranted ? "granted" : access == kIOHIDAccessTypeDenied ? "denied" : "unknown")")
        switch access {
        case kIOHIDAccessTypeGranted:
            break
        case kIOHIDAccessTypeUnknown:
            // raises the system prompt; the answer is picked up by the poll below
            let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            DebugLog.write("mic button · requested Input Monitoring access → \(granted)")
            guard granted else { waitForPermission(); return }
        default:
            waitForPermission()
            return
        }
        permissionPoll?.invalidate()
        permissionPoll = nil

        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: Self.vendorID, kIOHIDProductIDKey: Self.productID] as CFDictionary)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<MicButton>.fromOpaque(ctx).takeUnretainedValue().deviceAdded(device)
        }, me)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<MicButton>.fromOpaque(ctx).takeUnretainedValue().deviceRemoved()
        }, me)
        IOHIDManagerRegisterInputValueCallback(m, { ctx, _, _, value in
            guard let ctx else { return }
            Unmanaged<MicButton>.fromOpaque(ctx).takeUnretainedValue().handle(value)
        }, me)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        manager = m
        connected = 0

        var result = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        seized = result == kIOReturnSuccess
        if !seized {
            // another process holds the device exclusively, or seizing is refused: listen alongside it
            DebugLog.write(String(format: "mic button · exclusive open refused (0x%08X), listening without blocking", result))
            IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
            result = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if result != kIOReturnSuccess && result != kIOReturnNotFound {
            DebugLog.write(String(format: "mic button · open failed 0x%08X", result))
            teardown()
            status = .failed(String(format: "Could not open the receiver (0x%08X)", result))
            return
        }
        DebugLog.write("mic button · listening · exclusive \(seized)")
        updateStatus()
    }

    private func stop() {
        permissionPoll?.invalidate()
        permissionPoll = nil
        teardown()
        status = .off
    }

    private func teardown() {
        guard let m = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        connected = 0
    }

    /// Input Monitoring is granted in System Settings while Nemo runs: check every couple of seconds.
    private func waitForPermission() {
        status = .needsPermission
        DebugLog.write("mic button · waiting for Input Monitoring access")
        guard permissionPoll == nil else { return }
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return }
            self.permissionPoll?.invalidate()
            self.permissionPoll = nil
            self.start()
        }
    }

    private func deviceAdded(_ device: IOHIDDevice) {
        connected += 1
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "receiver"
        DebugLog.write("mic button · \(name) connected")
        updateStatus()
    }

    private func deviceRemoved() {
        connected = max(0, connected - 1)
        DebugLog.write("mic button · receiver disconnected")
        updateStatus()
    }

    private func updateStatus() {
        guard manager != nil else { return }
        status = connected > 0 ? .ready(blocking: seized) : .waitingForDevice
    }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let pressed = IOHIDValueGetIntegerValue(value)
        DebugLog.write(String(format: "mic button · page 0x%X usage 0x%X value %ld", page, usage, pressed))
        guard page == Self.triggerPage, usage == Self.triggerUsage, pressed != 0 else { return }
        onPress()
    }
}
