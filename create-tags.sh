#!/bin/bash

set -euo pipefail

# Path of the `lean-toolchain` file, relative to the repository root.
TOOLCHAIN_PATH="${TOOLCHAIN_PATH:-lean-toolchain}"
BEFORE="${BEFORE:-}"
AFTER="${AFTER:-}"

# When the workflow is not triggered by `push` (e.g. `workflow_dispatch`), there is no `after`
# commit: use whatever revision the repository is checked out at.
if [[ -z "$AFTER" ]]; then
  AFTER=HEAD
fi

# Determine the range of commits to scan.
# If we cannot tell which commits are new, scan all of the history leading up to `AFTER`.
# This is safe because we never create a tag that already exists, so only Lean versions that
# have not been tagged yet are affected.
if [[ -z "$BEFORE" ]]; then
  # Not triggered by `push` (e.g. `workflow_dispatch`).
  echo "INFO: No \`before\` commit given; scanning all history up to $AFTER."
  range=("$AFTER")
elif [[ "$BEFORE" =~ ^0+$ ]]; then
  # On the initial push to a new repo (or branch), BEFORE is the null SHA.
  echo "INFO: Initial push; scanning all history up to $AFTER."
  range=("$AFTER")
elif ! git cat-file -e "$BEFORE^{commit}" 2>/dev/null; then
  # After a force-push, the old commit is typically no longer reachable, so it is not in our clone.
  echo "WARNING: \`before\` commit $BEFORE not found (force-push?); scanning all history up to $AFTER."
  range=("$AFTER")
else
  range=("$BEFORE..$AFTER")
fi

# The commits that touch the lean toolchain, oldest first.
# We use `--first-parent` so that when a branch is merged with a merge commit, the merge commit
# (i.e. the commit on the branch that we were pushed to) is tagged, rather than the commit on the
# merged branch that originally made the change.
commits=$(git log --first-parent --reverse --pretty=format:"%H" "${range[@]}" -- "$TOOLCHAIN_PATH")
if [[ -z "$commits" ]]; then
  echo "INFO: No commits changing $TOOLCHAIN_PATH found."
fi

for commit in $commits; do
  # Get the toolchain that this PR switched to.
  toolchain=$(git show "$commit:$TOOLCHAIN_PATH") || {
    echo "WARNING: Could not read $TOOLCHAIN_PATH at commit $commit. Please avoid newlines or other special characters!"
    continue
  }
  # Strip the repository prefix, so we just get the suffix.
  if [[ "$toolchain" =~ ^leanprover/lean4:(.*)$ ]]; then
    toolchain_version="${BASH_REMATCH[1]}"
  else
    echo "INFO: Not on leanprover/lean4 toolchain; not tagging commit: $commit"
    continue
  fi

  # Only add a tag for this toolchain if we haven't added it before.
  if git ls-remote --tags --exit-code origin "$toolchain_version" >/dev/null; then
    echo "INFO: Already have a tag for $toolchain_version; not tagging commit: $commit"
  else
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    # If the tag does not exist, create and push the tag to remote
    git tag -a "$toolchain_version" -m "Release $toolchain_version" $commit
    git push origin  "$toolchain_version"

    if [[ "$DO_RELEASE" == "true" ]]; then
      gh release create "$toolchain_version" --title "$toolchain_version" --notes "Automated release for Lean version $toolchain_version"
    fi
  fi
done
