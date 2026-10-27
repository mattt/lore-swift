# lore-swift

Swift bindings for the C library of
[Lore](https://github.com/EpicGames/lore),
Epic Games' version control system.
This is an early prototype.

The package wraps the same C library as the official SDKs
for [Go](https://github.com/EpicGames/lore-go),
[JavaScript](https://github.com/EpicGames/lore-js),
[Python](https://github.com/EpicGames/lore-python),
and [C#](https://github.com/EpicGames/lore-dotnet),
and follows their names where they fit Swift.
It targets Lore 0.11.0 on macOS 15 or later on Apple silicon.

## Example

```swift
import Lore

let repository = try await Repository.create(
    at: "/tmp/demo",
    name: "lore://127.0.0.1:41337/demo",
    options: .init(identity: "alice@example.com")
)

try "Hello, Lore!\n".write(toFile: "/tmp/demo/hello.txt", atomically: true, encoding: .utf8)
try await repository.stage(["hello.txt"])
let revision = try await repository.commit(message: "Add hello.txt")
print("Committed revision", revision.number, revision.id)

for try await update in repository.pushUpdates() {
    switch update {
    case .progress(let progress):
        print("Pushed", progress.bytesTransferred, "of", progress.bytesTotal, "bytes")
    case .completed(let result):
        print("Pushed", result.branch, "to", result.remote)
    }
}
```

Every operation is an `async` method on `Repository`
that returns when the library reports that the operation has ended.
Failures throw `LoreError`,
which carries the library's error code, message, and trace.
Clone, push, and sync also have `…Updates` variants
that return an `AsyncThrowingStream` of progress reports and a result.

The library can't cancel an operation once it starts,
so an operation finishes even if the calling task is cancelled.

## Setup

The package links against the Lore C library,
which the repository doesn't include.
Run the fetch script once before you build:

```console
$ Scripts/fetch-liblore.sh
```

The script downloads `liblore-v0.11.0-aarch64-apple-darwin.tar.gz`
from the [Lore 0.11.0 release](https://github.com/EpicGames/lore/releases/tag/v0.11.0),
checks its SHA-256 digest,
and builds `Vendor/liblore.xcframework` from `liblore.dylib` and `lore.h`.
The package's `liblore` binary target points at that XCFramework,
and the `CLore` target exposes the header to Swift.
SwiftPM copies `liblore.dylib` next to the products it builds,
with Epic Games' code signature intact.

Then build and test as usual:

```console
$ swift build
$ swift test
```

The unit tests need no server:
they run local operations on offline repositories in `.scratch/`.
The tests set `HOME` to `.scratch/test-home`,
so the library keeps its per-user data out of your home directory.

### Integration tests

The integration tests run against a local `loreserver`.
Fetch the server with the library,
then run the tests with the integration script:

```console
$ Scripts/fetch-liblore.sh --with-server
$ Scripts/run-integration-tests.sh
```

The script starts the server on 127.0.0.1,
with port 43537 for QUIC and gRPC and port 43539 for HTTP,
keeps its stores and logs in `.scratch/integration/`,
runs `swift test` with `LORE_INTEGRATION=1`,
and stops the server when the tests end.
The server runs with authentication off,
and the tests use the unencrypted `lore://` scheme.

## Coverage

| Area | C API | Swift API | Tests |
| --- | --- | --- | --- |
| Version | `lore_version`, `LORE_INTERFACE_VERSION`, `lore_user_directory` | `Library.version`, `Library.interfaceVersion`, `Library.userDirectory` | Unit |
| Logging | `lore_log_configure`, `LORE_EVENT_LOG` | `Library.setLogHandler(level:_:)` | Offline |
| Shutdown | `lore_shutdown` | `Library.shutdown()` | None |
| Errors | `LORE_EVENT_COMPLETE`, `lore_error_detail_t` | `LoreError` | Unit, offline |
| Create | `lore_repository_create_async` | `Repository.create(at:name:description:options:)` | Offline, server |
| Clone | `lore_repository_clone_async` | `Repository.clone(from:to:revision:options:)`, `cloneUpdates` | Server |
| Status | `lore_repository_status_async` | `status(paths:scan:)` | Offline, server |
| Stage | `lore_file_stage_async` | `stage(_:scan:)` | Offline |
| Commit | `lore_revision_commit_async` | `commit(message:)` | Offline |
| Push | `lore_branch_push_async` | `push(branch:fastForward:)`, `pushUpdates` | Server |
| Sync | `lore_revision_sync_async` | `sync(to:discardingLocalChanges:)`, `syncUpdates` | Offline, server |
| Branches | `lore_branch_list_async`, `lore_branch_create_async`, `lore_branch_switch_async` | `branches(includeArchived:)`, `createBranch(named:category:)`, `switchBranch(to:revision:discardingLocalChanges:)` | Offline, server |
| File metadata | `lore_file_metadata_get_async`, `lore_file_metadata_set_async` | `metadata(forKey:path:revision:)`, `setMetadata(_:forPaths:)` | Offline |
| File dependencies | `lore_file_dependency_add_async`, `lore_file_dependency_list_async` | `addDependencies(_:to:tags:allowingCycles:)`, `dependencies(of:revision:recursive:dependents:tags:depthLimit:)` | Offline |
| Locks | `lore_lock_file_acquire_async`, `lore_lock_file_release_async`, `lore_lock_file_status_async`, `lore_lock_file_query_async` | `lock(_:branch:)`, `unlock(_:branch:)`, `locks(on:branch:)`, `locks(branch:owner:path:)` | Offline, server |

The binding doesn't yet cover the rest of the C API,
such as authentication, merges, history, links, layers, and the storage API.
`setMetadata(_:forPaths:)` can't set binary or address values;
in Lore 0.11.0,
`lore_file_metadata_set` reads the value of a binary entry as a file path.

## License

The package is available under the MIT license.
See [LICENSE.md](LICENSE.md).
Lore is available under the MIT license from Epic Games.
