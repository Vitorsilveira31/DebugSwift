//
//  DiskMetrics.swift
//  DebugSwift
//
//  Created by Matheus Gois on 08/05/26.
//

import Foundation

struct DiskIOSample: Sendable {
    let bytesPerSecond: Double
    let timestamp: Date

    init(bytesPerSecond: Double, timestamp: Date = Date()) {
        self.bytesPerSecond = bytesPerSecond
        self.timestamp = timestamp
    }
}

struct OpenFileDescriptor: Identifiable, Sendable {
    enum FileType: String, Sendable {
        case readOnly = "R"
        case writeOnly = "W"
        case readWrite = "RW"
    }

    let id: Int
    let descriptor: Int32
    let path: String
    let fileType: FileType

    init(descriptor: Int32, path: String, fileType: FileType) {
        self.id = Int(descriptor)
        self.descriptor = descriptor
        self.path = path
        self.fileType = fileType
    }
}

