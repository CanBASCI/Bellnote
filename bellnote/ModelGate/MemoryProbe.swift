import Darwin
import Foundation
import os

/// Reads the number iOS compares with the app memory limit.
enum MemoryProbe {
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / 1_048_576)
    }

    /// How much more memory this app may use before iOS ends it. A small number here is the warning sign.
    static func availableMB() -> Int {
        Int(os_proc_available_memory() / 1_048_576)
    }

    static func thermalName() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// One log fragment with everything needed to tell a memory kill from a heat slowdown.
    static func summary() -> String {
        "footprintMB=\(footprintMB()) availableMB=\(availableMB()) thermal=\(thermalName())"
    }
}
