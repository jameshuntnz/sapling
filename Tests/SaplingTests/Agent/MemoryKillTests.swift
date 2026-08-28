import Foundation
import Testing

@testable import SaplingAgent
@testable import SaplingCore

/// An OOM kill is the one failure that says nothing about itself.
///
/// The container is `--rm` and gone, the victim got SIGKILL, and the job log
/// carries only whatever supervised it — for the Android build that prompted
/// this, Gradle's `daemon disappeared unexpectedly` and an exit status of 1,
/// indistinguishable from a compile error.
@Suite("Memory kill detection")
struct MemoryKillTests {
    /// Verbatim from the run that took a debugging cycle to explain.
    @Test("recognises the wording Gradle leaves behind")
    func recognisesGradle() {
        #expect(
            MemoryKill.matches(
                "The message received from the daemon indicates that the daemon has disappeared."))
        #expect(
            MemoryKill.matches(
                "Gradle build daemon disappeared unexpectedly (it may have been killed or may have crashed)"
            ))
    }

    @Test("recognises the kernel's own wording")
    func recognisesKernel() {
        #expect(MemoryKill.matches("Out of memory: Killed process 291 (java)"))
        #expect(MemoryKill.matches("Memory cgroup out of memory: Killed process 4012"))
        #expect(MemoryKill.matches("kworker invoked oom-killer: gfp_mask=0x1100cca"))
        #expect(MemoryKill.matches("java.lang.OutOfMemoryError: Java heap space"))
    }

    /// This only ever rewrites the text of an already-failed job, so a miss is
    /// cheap and a false positive sends someone after memory they have.
    @Test("leaves ordinary build failures alone")
    func ignoresOrdinaryFailures() {
        #expect(!MemoryKill.matches("> Task :androidApp:mergeExtDexDebug"))
        #expect(!MemoryKill.matches("e: file.kt:12:5 Unresolved reference: foo"))
        #expect(!MemoryKill.matches("Process completed with exit code 1."))
        // Teardown and cancellation produce both of these.
        #expect(!MemoryKill.matches("container exited with status 137"))
        #expect(!MemoryKill.matches("Killed"))
    }

    /// The allocation appears in no log, and when unset in no config file
    /// either — so the message is the only place it is ever stated.
    @Test("names the default when linux.memory_gb is unset")
    func namesTheDefault() {
        let reason = MemoryKill.reason(memoryGB: nil)
        #expect(reason.contains("\(LinuxConfig.containerDefaultMemoryGB)GB"))
        #expect(reason.contains("linux.memory_gb is unset"))
    }

    @Test("names the configured size when there is one")
    func namesConfiguredSize() {
        let reason = MemoryKill.reason(memoryGB: 6)
        #expect(reason.contains("6GB"))
        #expect(!reason.contains("unset"))
    }

    @Test("the watch latches on the first match and holds it")
    func watchLatches() async {
        let watch = MemoryKillWatch()
        await watch.observe("> Task :androidApp:mergeLibDexDebug")
        #expect(await watch.sawKill == false)
        await watch.observe("The message received from the daemon indicates that the daemon has disappeared.")
        #expect(await watch.sawKill == true)
        // Output keeps flowing after the kill; the verdict must not be undone.
        await watch.observe("FAILURE: Build failed with an exception.")
        #expect(await watch.sawKill == true)
    }
}
