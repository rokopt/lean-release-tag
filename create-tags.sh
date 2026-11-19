#!/bin/bash

set -euo pipefail

# Path of the `lean-toolchain` file, relative to the repository root.
TOOLCHAIN_PATH="${TOOLCHAIN_PATH:-lean-toolchain}"

# The commits that touch the lean toolchain, oldest first.
# We use `--first-parent` so that when a branch is merged with a merge commit, the merge commit
# (i.e. the commit on the branch that we were pushed to) is tagged, rather than the commit on the
# merged branch that originally made the change.
# On the initial push to a new repo, BEFORE is the null SHA.
if [[ "$BEFORE" == "0000000000000000000000000000000000000000" ]]; then
  commits=$(git log --first-parent --reverse --pretty=format:"%H" $AFTER -- "$TOOLCHAIN_PATH")
else
  commits=$(git log --first-parent --reverse --pretty=format:"%H" $BEFORE..$AFTER -- "$TOOLCHAIN_PATH")
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
