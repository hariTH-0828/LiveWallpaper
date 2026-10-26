import Foundation
import IOKit.ps

/// Watches Low Power Mode and whether the Mac is running on its power adapter.
@MainActor
final class PowerMonitor {
    private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var isOnPowerAdapter = PowerMonitor.readPowerAdapter()
    var onChange: (() -> Void)?

    private var runLoopSource: CFRunLoopSource?

    func start() {
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }
    }

    func refresh() {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let adapter = Self.readPowerAdapter()
        guard lowPower != isLowPowerMode || adapter != isOnPowerAdapter else { return }
        isLowPowerMode = lowPower
        isOnPowerAdapter = adapter
        onChange?()
    }

    /// Macs without a battery report no power source type and always count as on the adapter.
    private static func readPowerAdapter() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return true }
        return (type as String) != kIOPMBatteryPowerKey
    }
}
