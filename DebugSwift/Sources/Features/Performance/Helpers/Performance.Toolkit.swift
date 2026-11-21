//
//  Performance.Toolkit.swift
//  DebugSwift
//
//  Created by Matheus Gois on 15/12/23.
//  Copyright © 2023 apple. All rights reserved.
//

@preconcurrency import Foundation
import UIKit

@MainActor
final class PerformanceToolkit {
    let widget: PerformanceWidgetView
    nonisolated(unsafe) var measurementsTimer: Timer?
    nonisolated(unsafe) var fpsCounter = FPSCounter()
    var cpuMeasurements: [CGFloat] = []
    var currentCPU: CGFloat = 0
    var maxCPU: CGFloat = 0
    var memoryMeasurements: [CGFloat] = []
    var currentMemory: CGFloat = 0
    var maxMemory: CGFloat = 0
    var fpsMeasurements: [CGFloat] = []

    var currentFPS: CGFloat = 0
    var minFPS: CGFloat = 9999
    var maxFPS: CGFloat = 0

    var currentLeaks: CGFloat = 0
    var maxLeaks: CGFloat = 0
    var leaksMeasurements: [CGFloat] = []

    var currentMeasurementIndex = 0
    let measurementsLimit = 120
    var timeBetweenMeasurements: TimeInterval = 1
    var controllerMarked: TimeInterval = 120

    weak var delegate: PerformanceToolkitDelegate?

    var isWidgetShown: Bool {
        get {
            !widget.isHidden
        }
        set {
            widget.toggle(with: newValue)
            if newValue {
                DiskIOMonitor.shared.start()
            } else {
                DiskIOMonitor.shared.stop()
            }
        }
    }

    init(widgetDelegate: PerformanceWidgetViewDelegate) {
        self.widget = PerformanceWidgetView()
        widget.alpha = 0.0
        widget.isHidden = true
        widget.delegate = widgetDelegate

        setupPerformanceMeasurement()
        fpsCounter.startTracking()
    }

    deinit {
        measurementsTimer?.invalidate()
        measurementsTimer = nil
        fpsCounter.stopTracking()
    }

    func setupPerformanceMeasurement() {
        measurementsTimer = Timer(
            timeInterval: 1.0, target: self, selector: #selector(updateMeasurements), userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(measurementsTimer!, forMode: .common)

        // Additional setup for measurements
        cpuMeasurements = Array(repeating: 0, count: measurementsLimit)
        memoryMeasurements = Array(repeating: 0, count: measurementsLimit)
        fpsMeasurements = Array(repeating: 0, count: measurementsLimit)
        leaksMeasurements = Array(repeating: 0, count: measurementsLimit)
    }

    @objc private func updateMeasurements() {
        // CPU measurements
        currentCPU = cpu()
        cpuMeasurements = array(cpuMeasurements, byAddingMeasurement: currentCPU)
        maxCPU = max(maxCPU, currentCPU)

        // Memory measurements
        currentMemory = memory()
        memoryMeasurements = array(memoryMeasurements, byAddingMeasurement: currentMemory)
        maxMemory = max(maxMemory, currentMemory)

        // FPS measurements
        currentFPS = fps()
        fpsMeasurements = array(fpsMeasurements, byAddingMeasurement: currentFPS)
        if !currentFPS.isZero {
            minFPS = min(minFPS, currentFPS)
        }
        maxFPS = max(maxFPS, currentFPS)

        // Leaks measurements
        currentLeaks = leak()
        maxLeaks = max(maxLeaks, currentLeaks)
        leaksMeasurements = array(leaksMeasurements, byAddingMeasurement: leak())

        DispatchQueue.main.async {
            self.refreshWidget()
        }
        delegate?.performanceToolkitDidUpdateStats(self)
        currentMeasurementIndex = min(measurementsLimit, currentMeasurementIndex + 1)
    }

    private func array<T>(_ array: [T], byAddingMeasurement measurement: T) -> [T] {
        var newMeasurements = array

        if currentMeasurementIndex == measurementsLimit {
            // Shift previous measurements
            for index in 0..<measurementsLimit - 1 {
                newMeasurements[index] = newMeasurements[index + 1]
            }

            // Add the new measurement to the end of the array
            newMeasurements[measurementsLimit - 1] = measurement
        } else {
            // Add the next measurement if we haven't reached the limit
            newMeasurements.append(measurement)
        }

        return newMeasurements
    }

    private func refreshWidget() {
        widget.updateValues(
            cpu: currentCPU,
            memory: currentMemory,
            fps: currentFPS,
            leaks: currentLeaks
        )
    }

    nonisolated func cpu() -> CGFloat {
        CGFloat(ProcessMetrics.cpuPercent())
    }

    nonisolated private func memory() -> CGFloat {
        CGFloat(ProcessMetrics.residentBytes()) / 1024.0 / 1024.0
    }

    func simulateMemoryWarning() {
        let keyData = Data([
            0x5f, 0x70, 0x65, 0x72, 0x66, 0x6f, 0x72, 0x6d, 0x4d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x57,
            0x61, 0x72, 0x6e, 0x69, 0x6e, 0x67
        ])
        let key = String(data: keyData, encoding: .ascii)!
        let selector = NSSelectorFromString(key)
        let object = UIApplication.shared
        if object.responds(to: selector) {
            _ = object.perform(selector)
        }
    }

    nonisolated private func fps() -> CGFloat {
        fpsCounter.fps
    }

    nonisolated func leak() -> CGFloat {
        CGFloat(PerformanceLeakDetector.shared.leaks.filter(\.isActive).count)
    }
}

@MainActor
protocol PerformanceToolkitDelegate: AnyObject {
    func performanceToolkitDidUpdateStats(_ toolkit: PerformanceToolkit)
}
