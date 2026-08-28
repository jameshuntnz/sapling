import Foundation
import SaplingCore

/// Tells a job that was killed for memory apart from one that failed.
///
/// A container that runs out of memory reports nothing about memory. The
/// guest's OOM killer sends SIGKILL, the victim gets no chance to say
/// anything, and whatever was supervising it describes only the hole left
/// behind: Gradle's client prints `daemon disappeared unexpectedly`, with no
/// stack trace and no exception, and the build fails with exit 1 like any
/// ordinary compile error.
///
/// That is how an Android build spent a debugging cycle looking like a broken
/// build. It got through Kotlin compilation and resource packaging and died at
/// `mergeExtDexDebug` — the peak of an Android debug build — in a container
/// holding `container`'s default 1GB, because `linux.memory_gb` was unset and
/// nothing on the node ever wrote it. Nothing in the log named memory.
///
/// So the signatures are matched on the *survivor's* wording as much as the
/// kernel's, and the reason names the allocation the container actually had —
/// which appears in no log and, when the setting is unset, in no config file
/// either.
enum MemoryKill {
    /// Wording that means something died for memory rather than for a fault.
    ///
    /// Compared lowercased. Kept narrow deliberately: this only ever rewrites
    /// the text of an already-failed job, so a miss costs a worse message,
    /// but a false positive would send someone after memory they have. Bare
    /// "killed" and exit 137 are both too broad to sit here — a job cancelled
    /// during teardown produces them too.
    static let signatures = [
        // The kernel, global and cgroup killers respectively.
        "out of memory: killed process",
        "memory cgroup out of memory",
        "oom-killer",
        // What is left running afterwards, which is all most job logs carry.
        "daemon disappeared unexpectedly",
        "the daemon has disappeared",
        // The JVM hitting its own ceiling before the kernel reaches for it.
        "java.lang.outofmemoryerror",
    ]

    /// Whether a chunk of job output carries one of the signatures.
    static func matches(_ text: String) -> Bool {
        let haystack = text.lowercased()
        return signatures.contains { haystack.contains($0) }
    }

    /// How the outcome reads once a signature has been seen.
    ///
    /// - Parameter memoryGB: `linux.memory_gb`, or `nil` if it was never set.
    /// - Returns: A message naming both the symptom and the allocation.
    static func reason(memoryGB: Int?) -> String {
        let allocation: String
        if let memoryGB {
            allocation = "this container had \(memoryGB)GB (linux.memory_gb)"
        } else {
            allocation =
                "this container had \(LinuxConfig.containerDefaultMemoryGB)GB — "
                + "`container`'s default, because linux.memory_gb is unset"
        }
        return
            "a process in the container was killed for memory, not by a build failure: "
            + "\(allocation). Raise linux.memory_gb and restart the daemon; "
            + "`sapling doctor` will size it against this machine. "
            + "Note that the tool that survived reports this as its own worker or "
            + "daemon vanishing, which names neither memory nor the setting."
    }
}

/// Records whether a job's output ever carried a `MemoryKill` signature.
///
/// An actor because it is written from the process-output task while the
/// watchdog and the timeout race alongside it.
actor MemoryKillWatch {
    /// Whether any chunk so far matched.
    private(set) var sawKill = false

    /// Inspect one chunk of job output.
    func observe(_ text: String) {
        guard !sawKill else { return }
        sawKill = MemoryKill.matches(text)
    }
}
