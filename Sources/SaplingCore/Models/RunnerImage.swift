import Foundation

/// How a workflow job asks for a particular container image.
///
/// GitHub's REST API does not expose a job's `container:` key — the queued-job
/// payload carries `labels`, `head_sha` and little else — so the label set is
/// the only channel a job has for saying which image it wants. A job opts in
/// by adding one label:
///
/// ```yaml
/// runs-on: [self-hosted, linux, arm64, image:android]
/// ```
///
/// The selector is stripped before eligibility is decided, so the remaining
/// labels still have to be a subset of the node's own — an `image:` label
/// never widens what a node will accept.
public enum RunnerImageSelector {
    /// Label prefix that marks an image selector rather than a capability.
    public static let labelPrefix = "image:"

    /// Label prefix that asks for a memory size, in GB.
    ///
    /// `mem:6` on a job means "this one needs six gigabytes", overriding the
    /// platform default. It is a selector rather than a capability for the same
    /// reason `image:` is: the node cannot advertise every size a workflow might
    /// ask for, so leaving it among the capabilities would make every job that
    /// requests memory ineligible everywhere.
    public static let memoryLabelPrefix = "mem:"

    /// Splits runner labels into capability labels and the requested image.
    ///
    /// Returns `nil` for the image when no selector is present, which is the
    /// common case and means the node's configured default is used.
    public static func split(_ labels: [String]) -> (capabilities: [String], image: String?) {
        let parsed = parse(labels)
        return (parsed.capabilities, parsed.image)
    }

    /// Splits runner labels into capabilities, image, and requested memory.
    ///
    /// Every selector has to be stripped from `capabilities` here. Label
    /// matching is a subset test against what the node advertises, so a
    /// selector left in the list is a label the node will never have — which
    /// silently makes the job unroutable rather than loudly wrong.
    ///
    /// - Parameter labels: The `runs-on` labels from the workflow.
    /// - Returns: Capabilities to match on, the image, and memory in GB.
    public static func parse(
        _ labels: [String]
    ) -> (capabilities: [String], image: String?, memoryGB: Int?) {
        var capabilities: [String] = []
        var image: String?
        var memoryGB: Int?
        for label in labels {
            if label.hasPrefix(labelPrefix) {
                // Last one wins. Two selectors is a workflow bug, but silently
                // picking the first would make it harder to spot than honouring
                // the one nearest the end of the list.
                image = String(label.dropFirst(labelPrefix.count))
            } else if label.hasPrefix(memoryLabelPrefix) {
                memoryGB = parseMemoryGB(String(label.dropFirst(memoryLabelPrefix.count)))
            } else {
                capabilities.append(label)
            }
        }
        return (capabilities, image, memoryGB)
    }

    /// Reads `6` or `6g` as six gigabytes.
    ///
    /// Returns `nil` for anything it does not understand, which leaves the job
    /// on the platform default. Guessing at a malformed size would hand a build
    /// silently less memory than the workflow asked for — the failure this
    /// whole selector exists to prevent.
    public static func parseMemoryGB(_ text: String) -> Int? {
        var digits = text.lowercased()
        if digits.hasSuffix("gb") {
            digits = String(digits.dropLast(2))
        } else if digits.hasSuffix("g") {
            digits = String(digits.dropLast())
        }
        guard let value = Int(digits), value > 0, value <= 1024 else { return nil }
        return value
    }

    /// Whether a selector is safe to use as a directory name.
    ///
    /// The name is joined onto a path under the repository, so anything that
    /// could escape that directory has to be refused rather than sanitised —
    /// a quietly rewritten name would build a different image than the
    /// workflow asked for.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        guard name != ".", name != ".." else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.")
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        // A leading dot would target a hidden sibling of the images directory.
        return !name.hasPrefix(".")
    }
}

/// A container image built from a Dockerfile the repository owns.
///
/// The tag carries the git tree SHA of the image's directory, which is what
/// makes the cache correct without a registry: git already hashes that
/// directory's exact contents, so the tag changes when — and only when — the
/// image definition changes. An unrelated commit to application code resolves
/// to a tag that is already built.
public struct RunnerImageRef: Sendable, Hashable {
    /// Selector the workflow used, e.g. `android`.
    public var name: String
    /// Repository that owns the definition, in `owner/repo` form.
    public var repo: String
    /// Git tree SHA of the image's directory at the job's commit.
    public var treeSHA: String

    /// Creates a reference to a repository-defined image.
    public init(name: String, repo: String, treeSHA: String) {
        self.name = name
        self.repo = repo
        self.treeSHA = treeSHA
    }

    /// Prefix marking an image this node built, as opposed to one it pulled.
    ///
    /// Housekeeping uses it to decide what it is allowed to delete.
    public static let tagPrefix = "sapling-img-"

    /// The local tag this image is built and looked up under.
    ///
    /// Deliberately flat rather than `sapling/<slug>/<name>` — Apple's
    /// `container` reads a slash as a registry path and rewrites such a tag to
    /// `docker.io/sapling/…`, which both defeats a prefix match when listing
    /// and leaves local images looking like they came from Docker Hub.
    ///
    /// Namespaced by repository so two projects can both define `android`
    /// without colliding on the node.
    public var tag: String {
        let slug = repo.replacingOccurrences(of: "/", with: "-").lowercased()
        return "\(Self.tagPrefix)\(slug)-\(name):\(treeSHA.prefix(12))"
    }
}
