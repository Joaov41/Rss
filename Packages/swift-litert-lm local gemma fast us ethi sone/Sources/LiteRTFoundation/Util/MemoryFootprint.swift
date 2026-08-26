// swift-litert-lm — process memory footprint
//
// Reports the task's `phys_footprint`, which is the metric the OS jetsam logic
// actually uses to decide whether to kill the app. This is what you want to
// watch while a multi-GB model is loaded, not `resident_size`.

import Foundation
import Darwin

/// The current process's physical memory footprint in bytes (0 on failure).
func processFootprintBytes() -> Int64 {
  var info = task_vm_info_data_t()
  var count = mach_msg_type_number_t(
    MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
  let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
    ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
      task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
    }
  }
  guard kr == KERN_SUCCESS else { return 0 }
  return Int64(info.phys_footprint)
}
