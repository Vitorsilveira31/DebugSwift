//
//  ProcessMetrics.swift
//  DebugSwift
//

import Darwin
import Foundation

/// Readings of the app process: CPU, memory and disk I/O. The live metrics screen, the widget and
/// the battery monitor all read them from here.
enum ProcessMetrics {
    /// CPU use of the process's busy threads, in percent of one core (several cores can exceed 100).
    static func cpuPercent() -> Double {
        var total = 0.0
        var threads: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return 0 }
        defer {
            // task_threads hands over a send right for each thread, as well as the array.
            for index in 0..<Int(count) {
                mach_port_deallocate(mach_task_self_, threads[index])
            }
            let size = vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), size)
        }
        for index in 0..<Int(count) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            guard result == KERN_SUCCESS else { break }
            if info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }
        return total
    }

    /// Resident memory of the process, in bytes.
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    /// The memory the system counts against the app (Xcode's memory gauge), in bytes.
    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : residentBytes()
    }

    /// How much more memory the app can use before the system ends it, in bytes.
    static func availableBytes() -> UInt64 {
        UInt64(os_proc_available_memory())
    }

    /// Bytes the process has read from and written to disk since it started.
    static func diskIO() -> (read: UInt64, written: UInt64) {
        guard let procPidRusage else { return (0, 0) }
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                procPidRusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return (0, 0) }
        return (usage.ri_diskio_bytesread, usage.ri_diskio_byteswritten)
    }

    private typealias ProcPidRusage = @convention(c) (Int32, Int32, UnsafeMutablePointer<rusage_info_t?>) -> Int32

    /// `proc_pid_rusage` from libproc, which the iOS SDK does not expose to Swift.
    private static let procPidRusage: ProcPidRusage? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_pid_rusage") else { return nil }
        return unsafeBitCast(symbol, to: ProcPidRusage.self)
    }()
}
