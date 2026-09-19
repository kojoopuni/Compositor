#!/bin/zsh
# Shows what merging upstream's latest would do, without touching this checkout: the merge is tried in a throwaway
# worktree, conflicts are listed, and the command-line tool is rebuilt against the merged code (which also catches a
# new upstream file that needs a window and has to be added to WINDOWED in CLI/make_project.py).
#
#   Fork/sync-upstream.sh            dry run: report only
#   Fork/sync-upstream.sh --merge    if the dry run is clean, merge upstream/main into the current branch
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
git fetch -q upstream
AHEAD=$(git rev-list --count HEAD..upstream/main)
if [[ "$AHEAD" == "0" ]]; then echo "Up to date: upstream has nothing new."; exit 0; fi
echo "Upstream has $AHEAD new commit(s):"
git log --oneline HEAD..upstream/main | sed 's/^/  /'
echo "Files they changed that the fork also changed:"
comm -12 <(git diff --name-only HEAD...upstream/main | sort) <(git diff --name-only upstream/main...HEAD | sort) | sed 's/^/  /' || true

TRIAL="$(mktemp -d)/trial"
git worktree add -q --detach "$TRIAL" HEAD
cleanup() { git worktree remove --force "$TRIAL" 2>/dev/null || true; }
trap cleanup EXIT
if ! git -C "$TRIAL" merge --no-commit --no-ff upstream/main > "$TRIAL.log" 2>&1; then
  echo "CONFLICTS — nothing here was changed. Files needing a hand merge:"
  git -C "$TRIAL" diff --name-only --diff-filter=U | sed 's/^/  /'
  exit 1
fi
echo "The merge is clean. Building the command-line tool against it…"
python3 "$TRIAL/CLI/make_project.py" > /dev/null
if ! xcodebuild -project "$TRIAL/CLI/CompositorCLI.xcodeproj" -target compositor-cli -configuration Debug -arch arm64 \
     SYMROOT="$TRIAL/CLI/build" OBJROOT="$TRIAL/CLI/build/obj" build > "$TRIAL.build.log" 2>&1; then
  echo "The merged code does not build for the command line:"
  grep -E "error:" "$TRIAL.build.log" | sed "s|$TRIAL/||" | sort -u | head -20
  echo "If an error names a file that builds views or windows, add it to WINDOWED in CLI/make_project.py."
  exit 1
fi
echo "Builds. Safe to merge."
if [[ "${1:-}" == "--merge" ]]; then
  git merge --no-ff upstream/main -m "Merge upstream/main"
  python3 CLI/make_project.py
  echo "Merged. Run the tests: python3 CLI/Tests/run.py && (cd MCP && npm test)"
fi
