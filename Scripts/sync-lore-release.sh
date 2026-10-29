#!/bin/bash
#
# Updates the package to a new release of Lore on GitHub
# and opens a pull request with the changes.
#
# Usage: Scripts/sync-lore-release.sh [--dry-run] [--release <version>]
#
#   --dry-run            Make the changes and show them, then restore the files.
#                        Don't create the release, push, or open the pull request.
#   --release <version>  Use this Lore release instead of the latest one.
#
# The script compares the Lore release with LORE_VERSION and stops
# if the package already uses it or a pull request for it is open.
# Otherwise, it sets the version and the SHA-256 digests that GitHub publishes
# for the release assets in Scripts/build-xcframework.sh
# and Scripts/fetch-loreserver.sh, checks the downloaded assets against them,
# rebuilds Vendor/liblore.xcframework.zip,
# attaches it to a liblore-<version> release of this repository,
# updates Package.swift, README.md, and the interface version test,
# pushes the mattt/update-lore-<version> branch, and opens a pull request.
# In GitHub Actions, it also starts the CI workflow on the branch.
#
# The script needs curl, gh, git, jq, and Xcode.
# Sign in with gh auth login or set GH_TOKEN.
# Without --dry-run, run it on the main branch.
#
# The script is compatible with Bash 3.2, the system Bash on macOS.

set -euo pipefail

readonly LORE_REPOSITORY="EpicGames/lore"
readonly REPOSITORY="${GITHUB_REPOSITORY:-mattt/lore-swift}"
readonly BASE_BRANCH="main"
readonly ARCHIVE="liblore.xcframework.zip"
readonly CHANGED_FILES="Scripts/build-xcframework.sh Scripts/fetch-loreserver.sh Package.swift README.md Tests/LoreTests/LibraryTests.swift"

dry_run=false
release=""
while [ $# -gt 0 ]; do
    case "$1" in
    --dry-run)
        dry_run=true
        ;;
    --release)
        if [ $# -lt 2 ]; then
            echo "error: --release needs a version" >&2
            exit 64
        fi
        release="${2#v}"
        shift
        ;;
    -h | --help)
        sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "error: unknown argument: $1" >&2
        exit 64
        ;;
    esac
    shift
done

in_actions() {
    [ "${GITHUB_ACTIONS:-}" = "true" ]
}

# Escapes a message for a workflow command,
# so that data from an API response stays on one annotation line.
escape() {
    local message="$1"
    message="${message//'%'/%25}"
    message="${message//$'\r'/%0D}"
    message="${message//$'\n'/%0A}"
    printf '%s' "$message"
}

notice() {
    if in_actions; then
        echo "::notice::$(escape "$1")"
    else
        echo "$1"
    fi
}

warning() {
    if in_actions; then
        echo "::warning::$(escape "$1")"
    else
        echo "warning: $1" >&2
    fi
}

error() {
    if in_actions; then
        echo "::error::$(escape "$1")"
    else
        echo "error: $1" >&2
    fi
}

group() {
    if in_actions; then
        echo "::group::$1"
    else
        echo "$1"
    fi
}

end_group() {
    if in_actions; then
        echo "::endgroup::"
    fi
}

is_version() {
    local pattern='^[0-9]+\.[0-9]+\.[0-9]+$'
    [[ "$1" =~ $pattern ]]
}

# Succeeds if version $1 is newer than version $2.
version_greater() {
    local a1 a2 a3 b1 b2 b3
    IFS=. read -r a1 a2 a3 <<<"$1"
    IFS=. read -r b1 b2 b3 <<<"$2"
    if [ "$a1" -ne "$b1" ]; then
        [ "$a1" -gt "$b1" ]
        return
    fi
    if [ "$a2" -ne "$b2" ]; then
        [ "$a2" -gt "$b2" ]
        return
    fi
    [ "$a3" -gt "$b3" ]
}

# Fetches a Lore release from the GitHub API into the release variable.
# The script stops quietly when the API is unavailable or rate limited,
# so that the next scheduled run tries again,
# and fails when the request is refused or the release doesn't exist.
fetch_release() {
    local url="https://api.github.com/repos/$LORE_REPOSITORY/releases/$1"
    local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    local output code message
    if [ -z "$token" ]; then
        token="$(gh auth token 2>/dev/null || true)"
    fi

    # curl reads the token from standard input
    # to keep it out of the process list.
    if ! output="$(
        if [ -n "$token" ]; then
            printf 'header = "Authorization: Bearer %s"\n' "$token"
        fi | curl --config - --silent --show-error --location \
            --header "Accept: application/vnd.github+json" \
            --header "X-GitHub-Api-Version: 2022-11-28" \
            --write-out '\n%{http_code}' "$url"
    )"; then
        warning "Could not reach the GitHub API; skipping this run."
        exit 0
    fi
    code="${output##*$'\n'}"
    release_json="${output%$'\n'*}"

    case "$code" in
    200) ;;
    401)
        error "GitHub API authentication failed (HTTP 401)."
        exit 1
        ;;
    403 | 429)
        # GitHub reports both rate limits and refused requests with 403.
        if [ "$code" = "429" ] || grep -qi "rate limit" <<<"$release_json"; then
            warning "GitHub API rate limit hit (HTTP $code); skipping this run."
            exit 0
        fi
        message="$(jq -r '.message // empty' <<<"$release_json" 2>/dev/null || true)"
        error "GitHub API refused the request (HTTP 403): $message"
        exit 1
        ;;
    404)
        error "$LORE_REPOSITORY has no release at $url (HTTP 404)."
        exit 1
        ;;
    *)
        warning "GitHub API returned HTTP $code; skipping this run."
        exit 0
        ;;
    esac
}

# Sets digest to the SHA-256 digest that GitHub publishes for a release asset.
asset_digest() {
    local name="$1" pattern='^[0-9a-f]{64}$'
    digest="$(jq -r --arg name "$name" \
        '.assets[] | select(.name == $name and .state == "uploaded") | .digest // empty' \
        <<<"$release_json")"
    digest="${digest#sha256:}"
    if ! [[ "$digest" =~ $pattern ]]; then
        error "Lore $version publishes no SHA-256 digest for $name."
        exit 1
    fi
}

# Downloads a release asset and checks it against its digest.
verify_asset() {
    local name="$1" sha256="$2"
    if ! curl --fail --location --silent --show-error --output "$work/$name" \
        "https://github.com/$LORE_REPOSITORY/releases/download/v$version/$name"; then
        error "Could not download $name from Lore $version."
        exit 1
    fi
    if ! echo "$sha256  $work/$name" | shasum -a 256 --check --status; then
        error "SHA-256 mismatch for $name from Lore $version."
        exit 1
    fi
    rm "$work/$name"
}

# Applies sed expressions to a file in place,
# keeping the file's permissions.
edit() {
    local file="$1"
    shift
    sed "$@" "$file" >"$work/edit"
    cat "$work/edit" >"$file"
}

# Fails unless the file has the line.
expect_line() {
    if ! grep -qxF -- "$2" "$1"; then
        error "Could not update $1; its format may have changed."
        exit 1
    fi
}

package_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$package_root"

work="$(mktemp -d "${TMPDIR:-/tmp}/sync-lore-release.XXXXXX")"
restore=false
cleanup() {
    if [ "$restore" = true ]; then
        # shellcheck disable=SC2086
        git checkout HEAD -- $CHANGED_FILES
    fi
    rm -rf "$work"
}
trap cleanup EXIT

current="$(sed -n 's/^readonly LORE_VERSION="\(.*\)"$/\1/p' Scripts/build-xcframework.sh)"
server_current="$(sed -n 's/^readonly LORE_VERSION="\(.*\)"$/\1/p' Scripts/fetch-loreserver.sh)"
if ! is_version "$current" || [ "$server_current" != "$current" ]; then
    error "Scripts/build-xcframework.sh and Scripts/fetch-loreserver.sh must set the same LORE_VERSION."
    exit 1
fi
if ! grep -qF "/releases/download/liblore-$current/$ARCHIVE\"" Package.swift; then
    error "The binary target in Package.swift doesn't use the liblore-$current release."
    exit 1
fi

if [ -n "$release" ]; then
    if ! is_version "$release"; then
        echo "error: --release needs a version such as 0.12.0" >&2
        exit 64
    fi
    fetch_release "tags/v$release"
else
    fetch_release "latest"
fi

tag="$(jq -r '.tag_name // empty' <<<"$release_json" 2>/dev/null || true)"
version="${tag#v}"
if [ "$tag" = "$version" ] || ! is_version "$version"; then
    warning "The Lore release has no tag in the form v<major>.<minor>.<patch>; skipping this run."
    exit 0
fi
if [ "$(jq -r '.prerelease or .draft' <<<"$release_json")" != "false" ]; then
    error "Lore $version is a prerelease."
    exit 1
fi

if [ "$version" = "$current" ]; then
    echo "The package already uses Lore $current; nothing to do."
    exit 0
fi
if ! version_greater "$version" "$current"; then
    echo "The package uses Lore $current, which is newer than Lore $version; nothing to do."
    exit 0
fi
notice "Lore $version is available; the package uses Lore $current."

release_tag="liblore-$version"
branch="mattt/update-lore-$version"

open_pull_request="$(gh pr list --repo "$REPOSITORY" --head "$branch" --state open \
    --json url --jq '.[0].url // empty')"
if [ -n "$open_pull_request" ]; then
    echo "Pull request $open_pull_request already updates the package to Lore $version; nothing to do."
    exit 0
fi

# shellcheck disable=SC2086
if ! git diff --quiet HEAD -- $CHANGED_FILES; then
    error "Commit or discard the changes to $CHANGED_FILES first."
    exit 1
fi
if [ "$dry_run" = false ] && [ "$(git symbolic-ref --quiet --short HEAD || true)" != "$BASE_BRANCH" ]; then
    error "Run the script on the $BASE_BRANCH branch, or use --dry-run."
    exit 1
fi

server_asset="loreserver-v$version-aarch64-apple-darwin.tar.gz"
asset_digest "liblore-v$version-aarch64-apple-darwin.tar.gz"
library_sha256="$digest"
asset_digest "$server_asset"
server_sha256="$digest"
echo "SHA-256 of the library: $library_sha256"
echo "SHA-256 of the server: $server_sha256"

restore=true
current_pattern="${current//./\\.}"

edit Scripts/build-xcframework.sh \
    -e "s/^readonly LORE_VERSION=\".*\"$/readonly LORE_VERSION=\"$version\"/" \
    -e "s/^readonly LIBRARY_SHA256=\".*\"$/readonly LIBRARY_SHA256=\"$library_sha256\"/"
expect_line Scripts/build-xcframework.sh "readonly LORE_VERSION=\"$version\""
expect_line Scripts/build-xcframework.sh "readonly LIBRARY_SHA256=\"$library_sha256\""

edit Scripts/fetch-loreserver.sh \
    -e "s/^readonly LORE_VERSION=\".*\"$/readonly LORE_VERSION=\"$version\"/" \
    -e "s/^readonly SERVER_SHA256=\".*\"$/readonly SERVER_SHA256=\"$server_sha256\"/"
expect_line Scripts/fetch-loreserver.sh "readonly LORE_VERSION=\"$version\""
expect_line Scripts/fetch-loreserver.sh "readonly SERVER_SHA256=\"$server_sha256\""

# Scripts/build-xcframework.sh checks the library against its digest.
echo "Verifying $server_asset"
verify_asset "$server_asset" "$server_sha256"
if ! Scripts/build-xcframework.sh; then
    error "Could not build the XCFramework from Lore $version."
    exit 1
fi

header="$(find Vendor/liblore.xcframework -name lore.h | head -n 1)"
interface_version="$(sed -n 's/^#define LORE_INTERFACE_VERSION "\(.*\)"$/\1/p' "$header")"
if ! is_version "$interface_version"; then
    error "Could not read LORE_INTERFACE_VERSION from lore.h in Lore $version."
    exit 1
fi
edit Tests/LoreTests/LibraryTests.swift \
    -e "s/#expect(Library.interfaceVersion == \"[^\"]*\")/#expect(Library.interfaceVersion == \"$interface_version\")/"
expect_line Tests/LoreTests/LibraryTests.swift \
    "        #expect(Library.interfaceVersion == \"$interface_version\")"

# A rebuilt archive has a different checksum,
# so an archive that a previous run attached to the release takes precedence.
release_assets=""
if release_assets="$(gh api "repos/$REPOSITORY/releases/tags/$release_tag" \
    --jq '.assets[].name' 2>"$work/release-error")"; then
    release_exists=true
elif grep -q "HTTP 404" "$work/release-error"; then
    release_exists=false
else
    error "Could not look up the $release_tag release of $REPOSITORY."
    exit 1
fi

if [ "$release_exists" = true ] && grep -qxF "$ARCHIVE" <<<"$release_assets"; then
    mkdir "$work/release"
    gh release download "$release_tag" --repo "$REPOSITORY" \
        --pattern "$ARCHIVE" --dir "$work/release"
    checksum="$(swift package compute-checksum "$work/release/$ARCHIVE")"
    notice "Release $release_tag already has $ARCHIVE; using its checksum, $checksum."
else
    checksum="$(swift package compute-checksum "Vendor/$ARCHIVE")"
fi

edit Package.swift \
    -e "s|/releases/download/liblore-$current_pattern/$ARCHIVE\"|/releases/download/$release_tag/$ARCHIVE\"|" \
    -e "s|checksum: \"[0-9a-f]*\"|checksum: \"$checksum\"|"
expect_line Package.swift \
    "                \"https://github.com/$REPOSITORY/releases/download/$release_tag/$ARCHIVE\","
expect_line Package.swift "            checksum: \"$checksum\""

edit README.md -e "s/^- Lore $current_pattern$/- Lore $version/"
expect_line README.md "- Lore $version"

group "Changes"
# shellcheck disable=SC2086
git --no-pager diff --stat -- $CHANGED_FILES
# shellcheck disable=SC2086
git --no-pager diff -- $CHANGED_FILES
end_group

lore_release_url="https://github.com/$LORE_REPOSITORY/releases/tag/v$version"
release_notes="An XCFramework of \`liblore.dylib\` and \`lore.h\` from the [Lore $version release]($lore_release_url), built by \`Scripts/build-xcframework.sh\` for the package's \`liblore\` binary target. The dylib is unchanged and keeps Epic Games' code signature. The XCFramework includes Lore's \`LICENSE.txt\` and \`THIRD-PARTY-NOTICES.txt\`.

Checksum: \`$checksum\`"
title="Update Lore to $version"
body="This updates the Lore library and server to [Lore $version]($lore_release_url) and points the \`liblore\` binary target to the archive in the [$release_tag](https://github.com/$REPOSITORY/releases/tag/$release_tag) release.

Before you merge, compare the new \`lore.h\` with the binding and check the notes about Lore $current behavior in the documentation and tests."

if [ "$dry_run" = true ]; then
    if [ "$release_exists" = false ]; then
        notice "Dry run: would create the $release_tag release of $REPOSITORY with Vendor/$ARCHIVE."
    elif ! grep -qxF "$ARCHIVE" <<<"$release_assets"; then
        notice "Dry run: would attach Vendor/$ARCHIVE to the $release_tag release of $REPOSITORY."
    fi
    notice "Dry run: would commit \"$title\" and push it to $branch."
    notice "Dry run: would open a pull request from $branch to $BASE_BRANCH."
    if in_actions; then
        notice "Dry run: would start the CI workflow on $branch."
    fi
    exit 0
fi

# The release must have the archive before CI resolves the package.
if [ "$release_exists" = false ]; then
    gh release create "$release_tag" "Vendor/$ARCHIVE" --repo "$REPOSITORY" \
        --title "liblore $version" --notes "$release_notes" \
        --target "$(git rev-parse HEAD)" --latest=false
    notice "Created the $release_tag release of $REPOSITORY."
elif ! grep -qxF "$ARCHIVE" <<<"$release_assets"; then
    gh release upload "$release_tag" "Vendor/$ARCHIVE" --repo "$REPOSITORY"
    notice "Attached $ARCHIVE to the $release_tag release of $REPOSITORY."
fi

git switch --force-create "$branch"
# shellcheck disable=SC2086
git add -- $CHANGED_FILES
if in_actions; then
    git -c user.name="github-actions[bot]" \
        -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
        commit --quiet --message "$title"
else
    git commit --quiet --message "$title"
fi
restore=false

# A branch from an earlier run without an open pull request is replaced.
git push --force origin "HEAD:refs/heads/$branch"

if ! pull_request="$(gh pr create --repo "$REPOSITORY" --base "$BASE_BRANCH" \
    --head "$branch" --title "$title" --body "$body")"; then
    error "Could not open a pull request from $branch. In GitHub Actions, the repository must allow GitHub Actions to create pull requests."
    exit 1
fi
notice "Opened $pull_request."

# GitHub doesn't run workflows for a pull request
# that GITHUB_TOKEN opens, but it runs a dispatched workflow.
if in_actions; then
    gh workflow run ci.yml --repo "$REPOSITORY" --ref "$branch"
    notice "Started the CI workflow on $branch."
fi

git switch --quiet "$BASE_BRANCH"
