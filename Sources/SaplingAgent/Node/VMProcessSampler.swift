import Darwin
import Foundation

/// One host process backing a job's environment, and the image it has open.
struct VMProcess: Sendable, Equatable {
    /// The host process id.
    let pid: Int32
    /// The VM or container name, taken from the directory holding its image.
    let environment: String
    /// The disk image the process has open, on the host.
    let imagePath: String
}

/// CPU time and memory for one process, as the kernel reports them.
struct VMProcessUsage: Sendable, Equatable {
    /// CPU consumed since the process started, in nanoseconds.
    ///
    /// Only meaningful as a difference between two readings.
    let cpuNanos: UInt64
    /// Physical memory the process has committed, in bytes.
    let footprint: Int64
}

/// Finds the processes that run job environments, and measures them.
///
/// Where the numbers come from, because it is not where you would first look:
/// neither `tart` nor `container` runs the guest itself. Both hand it to
/// Virtualization.framework, which spawns its own XPC process per VM — and
/// *that* is what holds the guest's memory and burns its CPU. Measured on the
/// node: a `tart` process for a running 6GB VM reports 13MB and 0.28 seconds
/// of CPU, while the helper beside it reports 6115MB and fourteen minutes.
/// Sampling the obvious process would have reported an idle, empty VM.
///
/// The helpers are adopted by launchd, so their parent is pid 1 and there is
/// no process tree to walk back to the job. What ties one to an environment is
/// the disk image it has open — `~/.tart/vms/<name>/disk.img` for a VM,
/// `.../containers/<name>/rootfs.ext4` for a container — which names the
/// environment in its path.
///
/// Reads the kernel directly rather than shelling out to `ps` or `lsof`, for
/// the reason `MetricsCollector` gives: this runs every few seconds for as
/// long as a job does.
enum VMProcessSampler {
    /// Executable path fragment identifying a Virtualization.framework helper.
    static let helperPathFragment = "Virtualization.framework"
    /// The helper's own name within that path.
    static let helperName = "com.apple.Virtualization.VirtualMachine"
    /// Image filenames that name their environment by their parent directory.
    ///
    /// `disk.img` is Tart's; `rootfs.ext4` is Apple `container`'s. A helper
    /// holds other files open too — nvram, a kernel, logs — so the match is on
    /// the one file that means "this is the guest's disk".
    static let imageFilenames = ["disk.img", "rootfs.ext4"]

    /// Every job environment currently backed by a host process.
    static func discover() -> [VMProcess] {
        var found: [VMProcess] = []
        for pid in liveProcessIDs() {
            let executable = executablePath(of: pid)
            guard executable.contains(helperPathFragment), executable.contains(helperName) else { continue }
            guard let image = openImagePath(of: pid) else { continue }
            let name = URL(fileURLWithPath: image).deletingLastPathComponent().lastPathComponent
            guard !name.isEmpty else { continue }
            found.append(VMProcess(pid: pid, environment: name, imagePath: image))
        }
        return found
    }

    /// CPU time and memory for one process.
    ///
    /// - Parameter pid: The process to measure.
    /// - Returns: Its usage, or `nil` if it has gone or cannot be read.
    static func usage(of pid: Int32) -> VMProcessUsage? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        // Physical footprint, not resident size. RSS counts the mapped disk
        // image as well as the guest's memory, and reported 10.4GB for the
        // same 6GB VM whose footprint was 6115MB.
        return VMProcessUsage(
            cpuNanos: info.ri_user_time + info.ri_system_time,
            footprint: Int64(bitPattern: info.ri_phys_footprint))
    }

    /// What a sparse disk image occupies, and the size the guest sees.
    ///
    /// - Parameter path: The image to measure.
    /// - Returns: Bytes allocated on the host and the image's nominal size, or
    ///   `nil` if it cannot be read.
    static func imageSize(at path: String) -> (used: Int64, capacity: Int64)? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        // Allocated blocks rather than length: the image is sparse, and its
        // length is the capacity the guest was promised, not what it has used.
        return (used: Int64(info.st_blocks) * 512, capacity: Int64(info.st_size))
    }

    // MARK: - Reading the kernel

    /// Every process id on the machine.
    static func liveProcessIDs() -> [Int32] {
        var capacity = 4096
        for _ in 0..<4 {
            var pids = [Int32](repeating: 0, count: capacity)
            let bytes = proc_listpids(
                UInt32(PROC_ALL_PIDS), 0, &pids, Int32(capacity * MemoryLayout<Int32>.size))
            guard bytes > 0 else { return [] }
            let count = Int(bytes) / MemoryLayout<Int32>.size
            // A full buffer means the list was probably truncated; try again
            // with room to spare rather than silently missing a VM.
            if count == capacity {
                capacity *= 2
                continue
            }
            return pids.prefix(count).filter { $0 > 0 }
        }
        return []
    }

    /// The executable behind a process id, or an empty string.
    static func executablePath(of pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }

    /// The guest disk image a process has open, if it has one.
    static func openImagePath(of pid: Int32) -> String? {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return nil }
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
        let read = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, size)
        guard read > 0 else { return nil }

        for descriptor in descriptors.prefix(Int(read) / MemoryLayout<proc_fdinfo>.stride)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let bytes = proc_pidfdinfo(
                pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info,
                Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard bytes > 0 else { continue }
            let path = withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard imageFilenames.contains(where: { path.hasSuffix("/" + $0) }) else { continue }
            return path
        }
        return nil
    }
}
