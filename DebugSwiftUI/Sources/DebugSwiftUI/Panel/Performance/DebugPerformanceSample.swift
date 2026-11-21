import Foundation

/// One reading of the app's live metrics, as the Android tools report it.
struct DebugPerformanceSample: Decodable {
    let cpuPercent: Double
    let usedMemory: Int
    let maxMemory: Int
    let nativeHeap: Int
    let systemAvailable: Int
    let systemTotal: Int
    let lowMemory: Bool
    let fps: Int
    let frames: Int
    let slowFrames: Int
    let slowestFrameMs: Int
    let batteryPercent: Int
    let charging: Bool
    let plugged: String
    let readBytes: Int
    let writeBytes: Int
    let appFileCount: Int
    let appFileBytes: Int

    static func read() -> Result<DebugPerformanceSample, DebugResourceFailure> {
        DebugResourceClient.fetch("app.perf.sample", as: DebugPerformanceSample.self)
    }
}

/// The last readings of one metric, newest last, capped so the chart keeps a fixed width. Readings
/// come once a second, so the cap is the chart's time window in seconds.
struct DebugMetricHistory {
    static var capacity: Int {
        #if os(Android)
        // `timeWindowSeconds` can be set directly, below the 10-second floor its setters keep.
        let seconds = DebugSwift.Performance.Chart.timeWindowSeconds
        // Clamp before converting: a huge value would not fit in an Int. A day of samples at most.
        return seconds.isFinite ? Int(min(max(seconds, 10), 86_400)) : 120
        #else
        60
        #endif
    }

    private(set) var values: [Double] = []

    mutating func append(_ value: Double) {
        values.append(value)
        // Read once: another thread can change the window between two reads.
        let capacity = Self.capacity
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
}
