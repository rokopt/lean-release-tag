#!/bin/bash

# Offline tests for `create-tags.sh`.
# Each test sets up a scratch repository with a bare "remote", runs the script as the action
# would, and checks which tags ended up on the remote (and on which commits).
# Releases are not tested here, since they require the GitHub API; see `test-me.sh` for that.

set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/create-tags.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

failures=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# Start a fresh test: an empty bare `origin` and a clone of it in `$work`, which becomes the cwd.
setup() {
  local name=$1
  echo "=== $name"
  rm -rf "$tmp/origin.git" "$tmp/work"
  git init -q --bare -b main "$tmp/origin.git"
  git clone -q "$tmp/origin.git" "$tmp/work" 2>/dev/null
  cd "$tmp/work"
  git checkout -q -b main
}

# commit FILE CONTENT MESSAGE: write CONTENT (verbatim, via printf) to FILE and commit it.
commit() {
  mkdir -p "$(dirname "$1")"
  printf "$2" > "$1"
  git add "$1"
  git commit -q -m "$3"
}

# Run the script, simulating the action's environment. Arguments are extra `VAR=value` settings.
run() {
  # Simulate `actions/checkout` with `fetch-depth: 0`: a fresh clone of the remote.
  rm -rf "$tmp/checkout"
  git clone -q "$tmp/origin.git" "$tmp/checkout"
  if ! (cd "$tmp/checkout" && env DO_RELEASE=false "$@" "$script") > "$tmp/log" 2>&1; then
    echo "  (script exited with an error)"
  fi
}

# expect_tags "TAG=commit subject" ...: check the remote's tags exactly match.
expect_tags() {
  local expected actual
  expected=$(printf '%s\n' "$@" | sed '/^$/d' | sort)
  actual=$(git -C "$tmp/origin.git" for-each-ref refs/tags --format='%(refname:short)=%(*subject)' | sort)
  if [[ "$expected" == "$actual" ]]; then
    echo "  ok"
  else
    echo "  FAIL"
    echo "  expected:"; printf '    %s\n' $expected
    echo "  actual:"; printf '    %s\n' $actual
    echo "  log:"; sed 's/^/    /' "$tmp/log"
    failures=$((failures + 1))
  fi
}

null=0000000000000000000000000000000000000000

setup "initial push"
commit lean-toolchain 'leanprover/lean4:v4.1.0\n' "bump 1"
git push -q origin main
run BEFORE=$null AFTER="$(git rev-parse HEAD)"
expect_tags "v4.1.0=bump 1"

setup "only new commits are tagged; newline variants"
commit lean-toolchain 'leanprover/lean4:v4.1.0\n' "bump 1"
git push -q origin main
before=$(git rev-parse HEAD)
commit lean-toolchain 'leanprover/lean4:v4.2.0' "bump 2 (no newline)"
commit README 'hi' "unrelated"
commit lean-toolchain 'leanprover/lean4:v4.3.0\r\n\n' "bump 3 (CRLF, extra newline)"
git push -q origin main
run BEFORE="$before" AFTER="$(git rev-parse HEAD)"
expect_tags "v4.2.0=bump 2 (no newline)" "v4.3.0=bump 3 (CRLF, extra newline)"

setup "existing tags are not moved"
commit lean-toolchain 'leanprover/lean4:v4.1.0\n' "bump 1"
git tag -a v4.1.0 -m "pre-existing"
git push -q origin main v4.1.0
before=$(git rev-parse HEAD)
commit lean-toolchain 'leanprover/lean4:v4.2.0\n' "bump 2"
commit lean-toolchain 'leanprover/lean4:v4.1.0\n' "back to 1"
git push -q origin main
run BEFORE="$before" AFTER="$(git rev-parse HEAD)"
expect_tags "v4.1.0=bump 1" "v4.2.0=bump 2"

setup "non-lean4 toolchains are ignored"
commit lean-toolchain 'leanprover/lean4-nightly:nightly-2024-01-01\n' "nightly"
commit lean-toolchain 'leanprover/lean4:v4.1.0 garbage\n' "garbage"
git push -q origin main
run BEFORE=$null AFTER="$(git rev-parse HEAD)"
expect_tags

setup "toolchain in a subdirectory (issue #3)"
commit lean-toolchain 'leanprover/lean4:v4.0.0\n' "root bump"
git push -q origin main
before=$(git rev-parse HEAD)
commit sub/dir/lean-toolchain 'leanprover/lean4:v4.1.0\n' "sub bump"
git push -q origin main
run BEFORE="$before" AFTER="$(git rev-parse HEAD)" TOOLCHAIN_PATH=sub/dir/lean-toolchain
expect_tags "v4.1.0=sub bump"

setup "subdirectory toolchain is ignored with default path"
commit sub/lean-toolchain 'leanprover/lean4:v4.1.0\n' "sub bump"
git push -q origin main
run BEFORE=$null AFTER="$(git rev-parse HEAD)"
expect_tags

setup "deleted toolchain file is skipped"
commit lean-toolchain 'leanprover/lean4:v4.1.0\n' "bump 1"
git push -q origin main
before=$(git rev-parse HEAD)
git rm -q lean-toolchain
git commit -q -m "delete"
git push -q origin main
run BEFORE="$before" AFTER="$(git rev-parse HEAD)"
expect_tags

setup "merge commit is tagged, not the merged branch's commit (issue #4)"
commit README 'hi' "init"
git push -q origin main
before=$(git rev-parse HEAD)
git checkout -q -b pr
commit lean-toolchain 'leanprover/lean4:v4.1.0\n' "pr bump"
commit README 'pr' "pr other"
git checkout -q main
commit README2 'main' "main other"
git merge -q --no-ff --no-edit -m "merge pr" pr
git push -q origin main
run BEFORE="$before" AFTER="$(git rev-parse HEAD)"
expect_tags "v4.1.0=merge pr"

setup "fast-forward merge tags the branch's commit"
commit README 'hi' "init"
git push -q origin main
before=$(git rev-parse HEAD)
git checkout -q -b pr
commit lean-toolchain 'leanprover/lean4:v4.1.0\n' "pr bump"
git checkout -q main
git merge -q --ff-only pr
git push -q origin main
run BEFORE="$before" AFTER="$(git rev-parse HEAD)"
expect_tags "v4.1.0=pr bump"

setup "workflow_dispatch: no before/after, scans everything"
commit lean-toolchain 'leanprover/lean4:v4.1.0\n' "bump 1"
commit lean-toolchain 'leanprover/lean4:v4.2.0\n' "bump 2"
git push -q origin main
run BEFORE= AFTER=
expect_tags "v4.1.0=bump 1" "v4.2.0=bump 2"

setup "force-push: unknown before commit, scans everything"
commit lean-toolchain 'leanprover/lean4:v4.1.0\n' "bump 1"
git push -q origin main
commit lean-toolchain 'leanprover/lean4:v4.2.0\n' "doomed"
before=$(git rev-parse HEAD)
git push -q origin main
git reset -q --hard HEAD~
commit lean-toolchain 'leanprover/lean4:v4.3.0\n' "bump 3"
git push -q -f origin main
# Make sure the old commit really is gone from the remote.
git -C "$tmp/origin.git" reflog expire --expire=now --all
git -C "$tmp/origin.git" gc -q --prune=now
run BEFORE="$before" AFTER="$(git rev-parse HEAD)"
expect_tags "v4.1.0=bump 1" "v4.3.0=bump 3"

setup "tag names are matched exactly"
commit lean-toolchain 'leanprover/lean4:v4.1.0\n' "bump 1"
git tag -a other/v4.1.0 -m "unrelated tag with the same suffix"
git push -q origin main other/v4.1.0
run BEFORE=$null AFTER="$(git rev-parse HEAD)"
expect_tags "other/v4.1.0=bump 1" "v4.1.0=bump 1"

echo
if [[ $failures -eq 0 ]]; then
  echo "All tests passed."
else
  echo "$failures test(s) failed."
  exit 1
fi
