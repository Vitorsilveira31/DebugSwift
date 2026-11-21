//
//  BatteryMonitor.swift
//  DebugSwift
//
//  Created by emircan.saglam on 7.06.2026.
//

@preconcurrency import Foundation
import UIKit

/// Monitors battery level, state, and energy impact over time.
/// Sampling occurs every 30 seconds to minimize monitoring overhead.
/// Battery level and state changes are also captured instantly via system notifications.
/// On Simulator, mock data is used since battery APIs are unavailable.
@MainActor
final class BatteryMonitor {
    static let shared = BatteryMonitor()

    // MARK: - Properties

    private(set) var snapshots: [BatterySnapshot] = []
    private(set) var isRunning = false
    private(set) var currentImpact: EnergyImpact?

    private let historyLimit = 60
    private var timer: Timer?

    private init() {}

    // MARK: - Public API

    func start() {
        guard !isRunning else { return }
        isRunning = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        setupNotifications()
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sample()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        UIDevice.current.isBatteryMonitoringEnabled = false
        removeNotifications()
    }

    var currentLevel: Float {
        UIDevice.current.batteryLevel
    }

    var currentState: UIDevice.BatteryState {
        UIDevice.current.batteryState
    }

    /// Returns false on physical devices where battery APIs are unavailable.
    /// Always returns true on Simulator using mock data.
    var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return UIDevice.current.batteryLevel >= 0
        #endif
    }

    // MARK: - Notifications

    /// Observes battery level and state changes for real-time updates
    /// between the 30-second periodic samples.
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(batteryLevelChanged),
            name: UIDevice.batteryLevelDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(batteryStateChanged),
            name: UIDevice.batteryStateDidChangeNotification,
            object: nil
        )
    }

    private func removeNotifications() {
        NotificationCenter.default.removeObserver(
            self,
            name: UIDevice.batteryLevelDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: UIDevice.batteryStateDidChangeNotification,
            object: nil
        )
    }

    @objc private nonisolated func batteryLevelChanged() {
        Task { @MainActor in
            self.sample()
        }
    }

    @objc private nonisolated func batteryStateChanged() {
        Task { @MainActor in
            self.sample()
        }
    }

    // MARK: - Sampling

    private func sample() {
        #if targetEnvironment(simulator)
        let previousLevel = snapshots.last?.level ?? 0.9
        let level = max(0.1, min(1.0, previousLevel - Float.random(in: 0.01...0.03)))
        let state: UIDevice.BatteryState = .unplugged
        #else
        let level = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState
        guard level >= 0 else { return }
        #endif

        let snapshot = BatterySnapshot(level: level, state: state, timestamp: Date())
        snapshots.append(snapshot)

        if snapshots.count > historyLimit {
            snapshots.removeFirst(snapshots.count - historyLimit)
        }

        currentImpact = EnergyImpact.calculate(
            cpuUsage: Self.currentCPUUsage(),
            state: state
        )
    }

    // MARK: - CPU Usage

    /// CPU use across the process's busy threads, as the live metrics read it.
    nonisolated static func currentCPUUsage() -> Double {
        ProcessMetrics.cpuPercent()
    }
}

// MARK: - UIDevice.BatteryState

extension UIDevice.BatteryState {
    var displayName: String {
        switch self {
        case .charging: return "Charging"
        case .full: return "Full"
        case .unplugged: return "Discharging"
        case .unknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }
}
