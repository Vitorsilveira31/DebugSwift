//
//  DiskIOTestView.swift
//  Example
//
//  Created by Matheus Gois on 08/05/26.
//

import Foundation
import SwiftUI

/// Writes files in several ways so the debug panel's Disk I/O tool has activity to show.
struct DiskIOTestView: View {
    @State var log: [DiskIOLogEntry] = []
    @State var continuousTask: Task<Void, Never>?

    private let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("disk_io_test", isDirectory: true)

    var body: some View {
        List {
            Section {
                Button("Write Small File (1 KB)") { writeFile(size: 1_024, label: "1KB") }
                Button("Write Medium File (1 MB)") { writeFile(size: 1_024 * 1_024, label: "1MB") }
                Button("Write Large File (10 MB)") { writeFile(size: 10 * 1_024 * 1_024, label: "10MB") }
            } header: {
                Text("Single Write")
            }

            Section {
                Button("Write via FileHandle") { writeViaFileHandle() }
                Button("Write via OutputStream") { writeViaOutputStream() }
            } header: {
                Text("Other Write Methods")
            }

            Section {
                if continuousTask == nil {
                    Button("Start Continuous I/O (every 1s)") { startContinuous() }
                } else {
                    Button("Stop Continuous I/O") { stopContinuous() }
                        .foregroundColor(.red)
                }
            } header: {
                Text("Continuous")
            }

            Section {
                Button("Clean Up Test Files") { cleanup() }
                    .foregroundColor(.red)
            }

            if !log.isEmpty {
                Section {
                    ForEach(Array(log.reversed())) { entry in
                        Text(entry.text)
                            .font(.caption)
                    }
                } header: {
                    Text("Log")
                }
            }
        }
        .navigationTitle("Disk I/O Tests")
        .onDisappear { stopContinuous() }
    }

    // MARK: - Writes

    private func writeFile(size: Int, label: String) {
        ensureDir()
        let data = Data(repeating: 0xAB, count: size)
        let url = tempDir.appendingPathComponent("test_\(label)_\(Int(Date().timeIntervalSince1970)).bin")
        do {
            #if os(iOS)
            // NSData's write is the path DebugSwift's DiskWriteTracker observes on iOS.
            try (data as NSData).write(to: url, options: .atomic)
            #else
            try data.write(to: url, options: .atomic)
            #endif
            appendLog("Wrote \(label) → \(url.lastPathComponent)")
        } catch {
            appendLog("Write failed: \(error.localizedDescription)")
        }
    }

    private func writeViaFileHandle() {
        ensureDir()
        let url = tempDir.appendingPathComponent("fh_\(Int(Date().timeIntervalSince1970)).bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: url)
            let chunk = Data(repeating: 0xCD, count: 64 * 1_024)
            for _ in 0..<8 {
                try handle.write(contentsOf: chunk)
            }
            try handle.close()
            appendLog("FileHandle wrote 512 KB → \(url.lastPathComponent)")
        } catch {
            appendLog("FileHandle write failed: \(error.localizedDescription)")
        }
    }

    private func writeViaOutputStream() {
        ensureDir()
        let url = tempDir.appendingPathComponent("os_\(Int(Date().timeIntervalSince1970)).bin")
        guard let stream = OutputStream(url: url, append: false) else {
            appendLog("OutputStream: couldn't open")
            return
        }
        stream.open()
        let bytes = [UInt8](repeating: 0xEF, count: 256 * 1_024)
        let written = stream.write(bytes, maxLength: bytes.count)
        stream.close()
        appendLog("OutputStream wrote \(written) bytes → \(url.lastPathComponent)")
    }

    // MARK: - Continuous

    private func startContinuous() {
        continuousTask = Task { @MainActor in
            var iteration = 0
            while !Task.isCancelled {
                iteration += 1
                writeFile(size: 100 * 1_024, label: "continuous_\(iteration)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        appendLog("Continuous I/O started")
    }

    private func stopContinuous() {
        guard let continuousTask else { return }
        continuousTask.cancel()
        self.continuousTask = nil
        appendLog("Continuous I/O stopped")
    }

    // MARK: - Cleanup

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
        appendLog("Cleaned up test directory")
    }

    // MARK: - Helpers

    private func ensureDir() {
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        log.append(DiskIOLogEntry(text: "[\(formatter.string(from: Date()))] \(message)"))
    }
}

struct DiskIOLogEntry: Identifiable {
    let id = UUID()
    let text: String
}
