import Foundation
import Testing

@testable import Lore

/// The scratch directory of the package, which Git ignores.
let scratchDirectory = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: ".scratch")

/// Points `HOME` at a scratch directory,
/// so that the library keeps its per-user data out of the real home directory.
///
/// Every test that calls into the library must evaluate this first,
/// because the library reads `HOME` when it first needs its user directory.
let isolatedHome: String = {
    let home = scratchDirectory.appending(path: "test-home").path
    try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    setenv("HOME", home, 1)
    return home
}()
