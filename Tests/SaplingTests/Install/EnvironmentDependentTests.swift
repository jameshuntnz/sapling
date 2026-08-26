import Foundation
import Testing

@testable import SaplingCore
@testable import SaplingInstall

/// Parent for every suite that reads or writes `SAPLING_HOME`.
///
/// The environment is process-wide state. `.serialized` applies to nested
/// suites too, so these can't interleave and corrupt one another's setup.
/// The suites themselves live in sibling files as extensions of this type.
@Suite("Environment-dependent", .serialized)
struct EnvironmentDependentTests {}
