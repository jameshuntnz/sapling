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

    /// Where the guest kernel keeps its own count of OOM kills.
    ///
    /// Authoritative, unlike anything else in a job log. The kernel increments
    /// `oom_kill` when it kills for memory and at no other time, so reading it
    /// answers "was this memory?" outright — no wording to match and no build
    /// tool to have an opinion about it. Verified on this hardware: a container
    /// held to 512MB and pushed past it reports `oom_kill 1` here and
    /// `Memory cgroup out of memory: Killed process` in `dmesg`, while a build
    /// that merely failed leaves it at zero.
    static let cgroupEventsPath = "/sys/fs/cgroup/memory.events"

    /// What the watcher prints when the kernel says memory was the cause.
    ///
    /// Distinct from the heuristics below, and treated as proof rather than
    /// evidence, so the outcome can say which of the two it is.
    static let confirmedMarker = "sapling: the guest kernel OOM-killed a process in this container"

    /// Shell that watches the kernel's OOM counter for the life of the job.
    ///
    /// Backgrounded before the runner is `exec`ed, for two reasons. The
    /// container is `--rm`, so nothing can ask the guest anything once the job
    /// is over — the answer has to be taken while it is still running. And the
    /// runner has to stay PID 1: it is what `container stop` signals, and
    /// wrapping it in a shell that forwards signals is exactly the kind of
    /// change that has broken teardown here before. A backgrounded subshell
    /// survives the `exec` and writes to the same stderr Sapling is streaming.
    ///
    /// Polls rather than waits because `memory.events` has no usable
    /// notification, and cheaply: one `awk` over a file of six short lines.
    static var watchScript: String {
        """
        (
          while :; do
            if [ "$(awk '/^oom_kill /{print $2}' \(cgroupEventsPath) 2>/dev/null || echo 0)" -gt 0 ]
            then
              echo "\(confirmedMarker)" >&2
              break
            fi
            sleep 2
          done
        ) &
        """
    }

    /// Whether a chunk of job output carries one of the signatures.
    static func matches(_ text: String) -> Bool {
        let haystack = text.lowercased()
        return signatures.contains { haystack.contains($0) }
    }

    /// How the outcome reads once a signature has been seen.
    ///
    /// - Parameters:
    ///   - memoryGB: The size this container was given, or nil if never set.
    ///   - confirmed: Whether the kernel's own counter said so, rather than a
    ///     build tool's wording merely suggesting it.
    /// - Returns: A message naming both the symptom and the allocation.
    static func reason(memoryGB: Int?, confirmed: Bool = false) -> String {
        let evidence =
            confirmed
            ? "the guest kernel OOM-killed a process in this container"
            : "a process in the container looks to have been killed for memory"
        let allocation: String
        if let memoryGB {
            allocation = "this container had \(memoryGB)GB (linux.memory_gb)"
        } else {
            allocation =
                "this container had \(LinuxConfig.containerDefaultMemoryGB)GB — "
                + "`container`'s default, because linux.memory_gb is unset"
        }
        return
            "\(evidence): "
            + "\(allocation). Give it more with a `mem:` label, or raise the platform default; "
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
    /// Whether any chunk so far matched, by proof or by inference.
    private(set) var sawKill = false
    /// Whether the kernel's own counter said so.
    ///
    /// Tracked apart from `sawKill` because the two deserve different wording:
    /// one is a fact about the guest, the other is a guess from a build tool's
    /// choice of words. Reporting a guess as a fact is how an afternoon goes
    /// into sizing memory that was never the problem.
    private(set) var confirmed = false

    /// Inspect one chunk of job output.
    func observe(_ text: String) {
        if !confirmed, text.contains(MemoryKill.confirmedMarker) {
            confirmed = true
            sawKill = true
            return
        }
        guard !sawKill else { return }
        sawKill = MemoryKill.matches(text)
    }
}
