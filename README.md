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

Add the `Lore` product to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "Lore", package: "lore-swift")
    ]
)
```

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
To work without a server, set `isOffline` in the options
and use a repository name instead of a URL.
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

Clone, push, and sync have `…Updates` variants that stream progress and the result:

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

Methods that take a `RevisionSpecifier` accept a string literal
in the syntax of the `lore` command-line tool,
or a specifier from a static method:

```swift
try await repository.sync(to: "main@2")
try await repository.sync(to: .number(2, on: "main"))
try await repository.sync(to: .latest(on: "feature"))
try await repository.sync(to: .id(revision.id))
```

### Reading history

```swift
for revision in try await repository.history(limit: 10) {
    print(revision.number, revision.message ?? "", revision.creator ?? "")
}

let changes = try await repository.changes(from: "main@1", to: "main@2")
for diff in try await repository.diff(of: ["hello.txt"], from: "main@1", contextLines: 3) {
    print(diff.patch)
}
```

### Working with branches

```swift
try await repository.createBranch(named: "feature")
try await repository.switchBranch(to: "feature")

for branch in try await repository.branches() {
    print(branch.name, branch.isCurrent ? "(current)" : "")
}
```

### Merging a branch

```swift
try await repository.switchBranch(to: "main")
let result = try await repository.mergeBranch(named: "feature", message: "Merge feature")
if !result.conflicts.isEmpty {
    try await repository.resolveConflicts(in: result.conflicts, keeping: .theirs)
    try await repository.commit(message: "Merge feature")
}
```

### Adding metadata and dependencies

File metadata, revision metadata, and dependencies are staged for the next commit.

```swift
try await repository.setMetadata(
    ["kind": .string("texture"), "approved": .boolean(true)],
    of: ["hero.png"]
)
let kind = try await repository.metadata(forKey: "kind", of: "hero.png")

try await repository.setRevisionMetadata(["ticket": .string("ART-42")])

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

### Logging in

```swift
let user = try await Authentication.logIn(token: token, server: "lore://lore.example.com:41337")
print("Logged in as", user.name)

try await repository.logOut()
```

`Authentication.logInInteractively(server:)` streams a URL
for the user to open and approve, instead of opening a browser.

### Handling errors

Failures throw `LoreError`:

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
| Repository | `lore_repository_info_async` | `info()` |
| Repository metadata | `lore_repository_metadata_get_async`, `lore_repository_metadata_set_async`, `lore_repository_metadata_clear_async` | `repositoryMetadata()`, `repositoryMetadata(forKey:)`, `setRepositoryMetadata(_:)`, `clearRepositoryMetadata(keys:)` |
| Stage | `lore_file_stage_async`, `lore_file_unstage_async`, `lore_file_reset_async` | `stage(_:scanning:)`, `unstage(_:)`, `reset(_:to:deletingUntrackedFiles:)` |
| Commit | `lore_revision_commit_async`, `lore_revision_amend_async`, `lore_revision_restore_async` | `commit(message:)`, `amend(message:)`, `restore(message:)` |
| Push | `lore_branch_push_async` | `push(branch:allowingFastForward:)`, `pushUpdates` |
| Sync | `lore_revision_sync_async` | `sync(to:discardingLocalChanges:)`, `syncUpdates` |
| Revisions | `lore_revision_history_async`, `lore_revision_info_async`, `lore_revision_diff_async` | `history(from:on:since:limit:stoppingAtBranchPoint:)`, `revision(_:)`, `changes(in:)`, `changes(from:to:paths:)` |
| Revision metadata | `lore_revision_metadata_get_async`, `lore_revision_metadata_list_async`, `lore_revision_metadata_set_async`, `lore_revision_metadata_clear_async` | `revisionMetadata(forKey:of:)`, `revisionMetadata(of:)`, `setRevisionMetadata(_:)`, `clearRevisionMetadata()` |
| Branches | `lore_branch_list_async`, `lore_branch_create_async`, `lore_branch_switch_async`, `lore_branch_info_async`, `lore_branch_archive_async`, `lore_branch_protect_async`, `lore_branch_unprotect_async`, `lore_branch_reset_async`, `lore_branch_latest_list_async` | `branches(includingArchived:)`, `createBranch(named:category:)`, `switchBranch(to:revision:discardingLocalChanges:)`, `branchInfo(named:)`, `archiveBranch(named:)`, `protectBranch(named:)`, `unprotectBranch(named:)`, `resetBranch(named:to:)`, `latestRevisions(on:limit:)` |
| Branch metadata | `lore_branch_metadata_get_async`, `lore_branch_metadata_set_async`, `lore_branch_metadata_clear_async` | `branchMetadata(of:)`, `branchMetadata(forKey:of:)`, `setBranchMetadata(_:of:)`, `clearBranchMetadata(keys:of:)` |
| Merges | `lore_branch_merge_start_async`, `lore_branch_merge_into_async`, `lore_branch_diff_async`, `lore_file_stage_merge_async`, `lore_file_reset_to_last_merged_async` | `mergeBranch(named:message:committing:)`, `mergeBranch(into:message:)`, `branchDiff(merging:into:path:mergingAutomatically:)`, `stageMerged(_:)`, `reset(_:toLastMergeFrom:keeping:deletingUntrackedFiles:)` |
| Reverts and cherry-picks | `lore_revision_revert_async`, `lore_revision_cherry_pick_async` | `revert(_:message:committing:)`, `cherryPick(_:message:committing:)` |
| Conflicts | `lore_branch_merge_resolve_async`, `lore_branch_merge_resolve_mine_async`, `lore_branch_merge_resolve_theirs_async`, `lore_branch_merge_unresolve_async`, `lore_branch_merge_restart_async`, `lore_branch_merge_abort_async`, `lore_revision_revert_resolve_async`, `lore_revision_revert_resolve_mine_async`, `lore_revision_revert_resolve_theirs_async`, `lore_revision_revert_unresolve_async`, `lore_revision_revert_restart_async`, `lore_revision_revert_abort_async` | `resolveConflicts(in:keeping:)`, `unresolveConflicts(in:)`, `restartMerge(of:)`, `abortMerge()` |
| Files | `lore_file_history_async`, `lore_file_info_async`, `lore_file_diff_async` | `history(of:from:on:limit:)`, `fileInfo(of:revision:)`, `diff(of:from:to:contextLines:ignoringTrailingWhitespace:ignoringWhitespaceChanges:)` |
| File metadata | `lore_file_metadata_get_async`, `lore_file_metadata_list_async`, `lore_file_metadata_set_async`, `lore_file_metadata_clear_async` | `metadata(forKey:of:revision:)`, `metadata(of:revision:)`, `setMetadata(_:of:)`, `clearMetadata(of:)` |
| File dependencies | `lore_file_dependency_add_async`, `lore_file_dependency_list_async`, `lore_file_dependency_remove_async` | `addDependencies(_:to:tags:allowingCycles:)`, `dependencies(of:revision:recursive:tags:depthLimit:)`, `dependents(of:revision:recursive:tags:depthLimit:)`, `removeDependencies(_:from:)` |
| Authentication | `lore_auth_login_with_token_async`, `lore_auth_login_interactive_async`, `lore_auth_logout_async`, `lore_auth_clear_async`, `lore_auth_list_async`, `lore_auth_user_info_async`, `lore_auth_local_user_info_async` | `Authentication.logIn(token:type:server:)`, `Authentication.logIn(token:type:authenticationURL:)`, `Authentication.logInInteractively(server:)`, `Authentication.logOut(from:userID:resource:)`, `Authentication.removeAllCredentials()`, `Authentication.credentials(includingTokens:)`, `Authentication.localUsers(withIDs:authenticationURL:includingTokens:)`, `logIn(token:type:)`, `logInInteractively()`, `logOut(userID:resource:)`, `users(withIDs:)`, `localUsers(withIDs:includingTokens:)`, `accessCredential()` |
| Locks | `lore_lock_file_acquire_async`, `lore_lock_file_release_async`, `lore_lock_file_status_async`, `lore_lock_file_query_async` | `lock(_:branch:)`, `unlock(_:branch:)`, `locks(on:branch:)`, `locks(branch:owner:path:)` |

The binding doesn't cover the rest of the C API,
such as links, layers, and the storage API.
The methods that set metadata can't set binary or address values.

## Development

### Running tests

```console
$ swift test
```

### Integration tests

The integration tests run against two local servers.
One requires tokens from a stub identity provider,
which runs with the system Python 3:

```console
$ Scripts/fetch-loreserver.sh
$ Scripts/run-integration-tests.sh
```

### Updating the Lore library

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

This project is available under the [MIT license](LICENSE.md).

The Lore library is available under the MIT license from Epic Games.
