import Foundation
import Testing

@testable import SaplingCore

/// Version comparison decides whether a node installs a build.
///
/// Getting prerelease precedence wrong means either refusing a real upgrade or downgrading a production node
/// onto a development build, so these follow semver.org §11 closely.
@Suite("Semantic version")
struct SemanticVersionTests {
    @Test("parses the shapes the release pipeline produces")
    func parsing() throws {
        let stable = try #require(SemanticVersion("0.5.0"))
        #expect((stable.major, stable.minor, stable.patch) == (0, 5, 0))
        #expect(stable.isStable)
        #expect(stable.channel == .stable)

        // Tags carry a leading v; version strings don't.
        #expect(SemanticVersion("v1.2.3") == SemanticVersion("1.2.3"))

        let dev = try #require(SemanticVersion("0.5.0-dev.12+abc1234"))
        #expect(dev.channel == .dev)
        #expect(dev.build == "abc1234")
        #expect(!dev.isStable)

        let candidate = try #require(SemanticVersion("0.5.0-rc.1"))
        #expect(candidate.channel == .rc)
    }

    /// An unparseable version must not compare as anything, or a malformed tag
    /// could read as an upgrade.
    @Test("refuses malformed versions rather than guessing")
    func rejectsMalformed() {
        for bad in ["", "1", "1.2", "1.2.3.4", "x.y.z", "1.2.-3", "1.2.3-", "1.2.3+", "-1.2.3"] {
            #expect(SemanticVersion(bad) == nil, "should reject \(bad)")
        }
    }

    @Test("orders by major, then minor, then patch")
    func ordersReleaseNumbers() throws {
        let ascending = ["0.1.0", "0.2.0", "0.2.1", "0.10.0", "1.0.0", "2.0.0"]
            .compactMap(SemanticVersion.init)
        #expect(ascending.count == 6)
        #expect(ascending == ascending.sorted())
        // Numeric, not lexical: 10 follows 2.
        #expect(try #require(SemanticVersion("0.2.0")) < #require(SemanticVersion("0.10.0")))
    }

    /// The rule that matters most: a prerelease precedes the release it leads
    /// to, so a node on 0.5.0 must never "upgrade" to 0.5.0-dev.1.
    @Test("a prerelease has lower precedence than its release")
    func prereleasePrecedesRelease() throws {
        let dev = try #require(SemanticVersion("0.5.0-dev.1"))
        let candidate = try #require(SemanticVersion("0.5.0-rc.1"))
        let stable = try #require(SemanticVersion("0.5.0"))

        #expect(dev < stable)
        #expect(candidate < stable)
        #expect(dev < candidate)
        #expect(!(stable < dev))
    }

    /// Numeric identifiers compare numerically.
    ///
    /// Compared as text, dev.9 would sort after dev.10 and a node would stop taking updates.
    @Test("numeric prerelease identifiers compare numerically")
    func numericIdentifiers() throws {
        #expect(try #require(SemanticVersion("0.5.0-dev.9")) < #require(SemanticVersion("0.5.0-dev.10")))
        #expect(try #require(SemanticVersion("0.5.0-rc.2")) < #require(SemanticVersion("0.5.0-rc.11")))
    }

    /// The example ordering given in semver.org §11.
    @Test("matches the specification's own worked example")
    func specExample() {
        let ordered = [
            "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
            "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0",
        ].compactMap(SemanticVersion.init)
        #expect(ordered.count == 8)
        #expect(ordered == ordered.sorted())
    }

    @Test("a shorter prerelease set precedes a longer one that shares its prefix")
    func shorterPrereleasePrecedes() throws {
        #expect(try #require(SemanticVersion("1.0.0-alpha")) < #require(SemanticVersion("1.0.0-alpha.1")))
    }

    /// Build metadata is explicitly excluded from precedence by the spec.
    @Test("ignores build metadata when comparing")
    func ignoresBuildMetadata() throws {
        let a = try #require(SemanticVersion("0.5.0+aaaa"))
        let b = try #require(SemanticVersion("0.5.0+bbbb"))
        #expect(a == b)
        #expect(!(a < b) && !(b < a))
        // But it survives round-tripping, for display.
        #expect(a.description == "0.5.0+aaaa")
    }

    @Test("round-trips through its description")
    func roundTrips() {
        for text in ["0.5.0", "1.2.3-rc.1", "0.5.0-dev.12+abc1234", "2.0.0-alpha.beta"] {
            #expect(SemanticVersion(text)?.description == text)
        }
    }
}

@Suite("Release channels")
struct ReleaseChannelTests {
    /// A node tracking dev wants rc and stable builds too — they are further
    /// along the same line, not a different product.
    @Test("a channel accepts anything at least as finished as itself")
    func acceptance() {
        #expect(ReleaseChannel.dev.accepts(.dev))
        #expect(ReleaseChannel.dev.accepts(.rc))
        #expect(ReleaseChannel.dev.accepts(.stable))

        #expect(!ReleaseChannel.rc.accepts(.dev))
        #expect(ReleaseChannel.rc.accepts(.rc))
        #expect(ReleaseChannel.rc.accepts(.stable))

        // A production node takes finished releases and nothing else.
        #expect(!ReleaseChannel.stable.accepts(.dev))
        #expect(!ReleaseChannel.stable.accepts(.rc))
        #expect(ReleaseChannel.stable.accepts(.stable))
    }

    @Test("derives the channel from the version itself")
    func derivedFromVersion() {
        #expect(SemanticVersion("1.0.0")?.channel == .stable)
        #expect(SemanticVersion("1.0.0-rc.1")?.channel == .rc)
        #expect(SemanticVersion("1.0.0-dev.4")?.channel == .dev)
        // Anything unrecognised is treated as least-finished, which is the
        // safe direction: a stable node won't install it.
        #expect(SemanticVersion("1.0.0-alpha.1")?.channel == .dev)
    }
}
