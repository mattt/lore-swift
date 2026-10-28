# Lore

Swift bindings for [Lore](https://github.com/EpicGames/lore),
Epic Games' version control system.

> [!WARNING]
> This package is an early prototype.
> Its API may change.

## Requirements

- Swift 6.2+ / Xcode 26+
- macOS 15+ on Apple silicon
- Lore 0.11.0

## Installation

Add the package to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/mattt/lore-swift.git", from: "0.1.0")
]
```

And add the `Lore` product to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "Lore", package: "lore-swift")
    ]
)
```

SwiftPM downloads the Lore C library as an XCFramework
from the [releases](https://github.com/mattt/lore-swift/releases) of this repository.

## Usage

### Creating a repository

```swift
import Lore

let repository = try await Repository.create(
    at: "/tmp/demo",
    name: "lore://127.0.0.1:41337/demo",
    options: .init(identity: "alice@example.com")
)
```

The `name` is the URL of the repository on a server.
To work without a server,
set `isOffline` in the options;
the `name` then names the repository.
Paths are relative to the repository directory.

### Staging and committing

```swift
try "Hello, Lore!\n".write(toFile: "/tmp/demo/hello.txt", atomically: true, encoding: .utf8)

try await repository.stage(["hello.txt"])
let revision = try await repository.commit(message: "Add hello.txt")
print("Committed revision", revision.number, revision.id)

let status = try await repository.status()
for file in status.files {
    print(file.action, file.path)
}
```

### Pushing, cloning, and syncing

```swift
try await repository.push()

let clone = try await Repository.clone(
    from: "lore://127.0.0.1:41337/demo",
    to: "/tmp/demo-clone",
    options: .init(identity: "bob@example.com")
)
try await clone.sync()
```

Clone, push, and sync also have `…Updates` variants
that return an `AsyncThrowingStream` of progress reports
and then the result:

```swift
for try await update in repository.pushUpdates() {
    switch update {
    case .progress(let progress):
        print("Pushed", progress.bytesTransferred, "of", progress.bytesToTransfer, "bytes")
    case .completed(let result):
        print("Pushed", result.branch, "to", result.remote)
    }
}
```

Operations can't be cancelled once they start.
Cancelling the task that iterates a stream ends the iteration,
but not the operation.

### Naming revisions

Methods that take a revision take a `RevisionSpecifier`.
Write one as a string literal in any form that the `lore` command-line tool accepts,
or use the static methods:

```swift
try await repository.sync(to: "main@2")
try await repository.sync(to: .number(2, on: "main"))
try await repository.sync(to: .latest(on: "feature"))
try await repository.sync(to: .id(revision.id))
```

### Working with branches

```swift
try await repository.createBranch(named: "feature")
try await repository.switchBranch(to: "feature")

for branch in try await repository.branches() {
    print(branch.name, branch.isCurrent ? "(current)" : "")
}
```

### Adding file metadata and dependencies

Metadata and dependencies become part of a file's staged state,
and the next commit records them.

```swift
try await repository.setMetadata(
    ["kind": .string("texture"), "approved": .boolean(true)],
    of: ["hero.png"]
)
let kind = try await repository.metadata(forKey: "kind", of: "hero.png")

try await repository.addDependencies(["hero.png"], to: "scene.usd")
let dependencies = try await repository.dependencies(of: ["scene.usd"], recursive: true)
let dependents = try await repository.dependents(of: ["hero.png"])
```

### Locking files

Locks are held on the server.

```swift
let result = try await repository.lock(["hero.png"])
print("Locked", result.acquired)

try await repository.unlock(["hero.png"])
```

### Handling errors

Failures throw `LoreError`.
Match on its code to handle a specific failure:

```swift
do {
    try await repository.commit(message: "Update")
} catch let error as LoreError where error.code == .nothingStaged {
    print("Nothing to commit")
}
```

### Logging

```swift
try Library.setLogHandler(level: .debug) { entry in
    print(entry.level, entry.message)
}
```

The handler runs on a library thread,
so it must return promptly.

## Coverage

| Area | C API | Swift API |
| --- | --- | --- |
| Version | `lore_version`, `LORE_INTERFACE_VERSION`, `lore_user_directory` | `Library.version`, `Library.interfaceVersion`, `Library.userDirectory` |
| Logging | `lore_log_configure`, `LORE_EVENT_LOG` | `Library.setLogHandler(level:_:)` |
| Shutdown | `lore_shutdown` | `Library.shutdown()` |
| Errors | `LORE_EVENT_COMPLETE`, `lore_error_detail_t` | `LoreError` |
| Create | `lore_repository_create_async` | `Repository.create(at:name:description:options:)` |
| Clone | `lore_repository_clone_async` | `Repository.clone(from:to:revision:options:)`, `cloneUpdates` |
| Status | `lore_repository_status_async` | `status(of:scanning:)` |
| Stage | `lore_file_stage_async` | `stage(_:scanning:)` |
| Commit | `lore_revision_commit_async` | `commit(message:)` |
| Push | `lore_branch_push_async` | `push(branch:allowingFastForward:)`, `pushUpdates` |
| Sync | `lore_revision_sync_async` | `sync(to:discardingLocalChanges:)`, `syncUpdates` |
| Branches | `lore_branch_list_async`, `lore_branch_create_async`, `lore_branch_switch_async` | `branches(includingArchived:)`, `createBranch(named:category:)`, `switchBranch(to:revision:discardingLocalChanges:)` |
| File metadata | `lore_file_metadata_get_async`, `lore_file_metadata_set_async` | `metadata(forKey:of:revision:)`, `setMetadata(_:of:)` |
| File dependencies | `lore_file_dependency_add_async`, `lore_file_dependency_list_async` | `addDependencies(_:to:tags:allowingCycles:)`, `dependencies(of:revision:recursive:tags:depthLimit:)`, `dependents(of:revision:recursive:tags:depthLimit:)` |
| Locks | `lore_lock_file_acquire_async`, `lore_lock_file_release_async`, `lore_lock_file_status_async`, `lore_lock_file_query_async` | `lock(_:branch:)`, `unlock(_:branch:)`, `locks(on:branch:)`, `locks(branch:owner:path:)` |

The binding doesn't yet cover the rest of the C API,
such as authentication, merges, history, links, layers, and the storage API.
`setMetadata(_:of:)` can't set binary or address values.

## Development

### Running tests

```console
$ swift test
```

### Integration tests

The integration tests run against a local `loreserver`:

```console
$ Scripts/fetch-loreserver.sh
$ Scripts/run-integration-tests.sh
```

### Updating the Lore library

To move the package to a new Lore release:

1. Set `LORE_VERSION` and the SHA-256 digests
   in `Scripts/build-xcframework.sh` and `Scripts/fetch-loreserver.sh`.
2. Run `Scripts/build-xcframework.sh`,
   which builds `Vendor/liblore.xcframework.zip`
   and prints its checksum.
3. To test before you publish the archive,
   change the `liblore` binary target to `path: "Vendor/liblore.xcframework"`.
4. Attach the archive to a new `liblore-<version>` release of this repository.
5. Set the binary target's `url` to the archive in that release
   and its `checksum` to the printed checksum.

### Formatting

```console
$ swift format -i -r Sources Tests Package.swift
```

## License

This project is available under the MIT license.
See the LICENSE file for more info.

The Lore library is available under the MIT license from Epic Games.
