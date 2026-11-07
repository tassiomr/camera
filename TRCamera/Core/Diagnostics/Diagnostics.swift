import CoreMotion
import Foundation
import os

enum Log {
    static let capture = Logger(subsystem: "com.trmedia.camera", category: "capture")
    static let storage = Logger(subsystem: "com.trmedia.camera", category: "storage")
    static let audio = Logger(subsystem: "com.trmedia.camera", category: "audio")
}

/// Watches ProcessInfo thermal state. Recording quality is never changed silently:
/// the view model only disables auxiliary tools and tells the user.
final class ThermalMonitor {
    var onChange: ((ProcessInfo.ThermalState) -> Void)?
    private var token: NSObjectProtocol?

    func start() {
        token = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onChange?(ProcessInfo.processInfo.thermalState)
        }
        onChange?(ProcessInfo.processInfo.thermalState)
    }
}

/// Device roll for the horizon level indicator.
final class LevelMonitor {
    private let manager = CMMotionManager()
    var onRoll: ((Double) -> Void)?

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 20
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let g = motion?.gravity else { return }
            self?.onRoll?(atan2(g.x, -g.y)) // 0 = upright portrait
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }
}
