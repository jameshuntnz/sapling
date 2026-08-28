import Foundation
import Testing

@testable import SaplingAPI
@testable import SaplingCore

/// The repositories a Kotlin/Android build resolves against.
///
/// One prefix each rather than a merged mirror: Gradle is told about them
/// separately and their order matters — `google()` is declared first and
/// filtered to Android and Google groups — so collapsing them would change
/// which repository an artifact resolves from.
@Suite("Maven mirror")
struct MavenMirrorTests {
    @Test("mirrors the four repositories the build declares")
    func coversTheDeclaredRepositories() {
        let bases = Set(CacheProxy.mavenUpstreams.values.map(\.base))
        #expect(bases.contains("https://repo1.maven.org/maven2"))
        #expect(bases.contains("https://dl.google.com/dl/android/maven2"))
        #expect(bases.contains("https://plugins.gradle.org/m2"))
        #expect(bases.contains("https://jitpack.io"))
    }

    @Test("each repository gets its own path prefix")
    func prefixesAreDistinct() {
        let prefixes = CacheProxy.mavenUpstreams.values.map(\.prefix)
        #expect(Set(prefixes).count == prefixes.count)
        #expect(prefixes.allSatisfy { $0.hasPrefix("maven/") })
    }

    /// A released coordinate never changes and can be served from disk
    /// forever. `maven-metadata.xml` is how a version range resolves, and a
    /// `-SNAPSHOT` is republished by definition — caching either would pin a
    /// build to a stale answer.
    @Test("released artifacts are immutable, metadata and snapshots are not")
    func immutabilityMatchesMavenSemantics() {
        let immutable = CacheProxy.isImmutableMavenPath
        #expect(immutable("androidx/core/core-ktx/1.13.1/core-ktx-1.13.1.aar"))
        #expect(immutable("org/jetbrains/kotlin/kotlin-stdlib/2.0.0/kotlin-stdlib-2.0.0.jar"))
        #expect(!immutable("androidx/core/core-ktx/maven-metadata.xml"))
        #expect(!immutable("com/example/lib/1.0-SNAPSHOT/lib-1.0-SNAPSHOT.jar"))
    }

    /// JitPack builds on demand and can republish a coordinate, so nothing
    /// from it is treated as permanent.
    @Test("nothing from JitPack is cached permanently")
    func jitpackIsNeverImmutable() {
        guard let jitpack = CacheProxy.mavenUpstreams["maven-jitpack"] else {
            Issue.record("jitpack upstream missing")
            return
        }
        #expect(!jitpack.immutableMatcher("com/github/user/repo/1.0/repo-1.0.jar"))
    }

    @Test("enabling maven turns on all four")
    func enablingMavenEnablesAll() async {
        var config = CacheConfig()
        config.proxies = ["maven"]
        let enabled = await CacheProxy(config: config).enabledUpstreams
        #expect(enabled.count == CacheProxy.mavenUpstreams.count)
    }
}
