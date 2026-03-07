#!/bin/bash
set -euo pipefail

usage() {
  echo "Usage: ./update.sh [--init | --update] [--dry-run]"
  echo ""
  echo "  --init      Initial setup for a new Mac. Installs everything from the"
  echo "              Brewfile and restores app settings via Mackup."
  echo "  --update    Periodic update. Upgrades packages, snapshots the Brewfile,"
  echo "              and commits changes via GitHub PR."
  echo "  --dry-run   Preview what would be executed without making any changes."
  exit 1
}

step() { echo ""; echo "==> $1"; }

dry_run=false
mode=""

for arg in "$@"; do
  case "$arg" in
    --init)    mode="init" ;;
    --update)  mode="update" ;;
    --dry-run) dry_run=true ;;
    *)         usage ;;
  esac
done

if [[ -z "$mode" ]]; then
  usage
fi

run() {
  if [[ "$dry_run" == true ]]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

# --- Prevent concurrent runs ---
LOCK_FILE="/tmp/update.sh.lock"
if [[ -f "$LOCK_FILE" ]]; then
  existing_pid=$(cat "$LOCK_FILE")
  if kill -0 "$existing_pid" 2>/dev/null; then
    echo "Error: Another instance is already running (PID $existing_pid)."
    exit 1
  else
    echo "Warning: Removing stale lock file from PID $existing_pid."
    rm -f "$LOCK_FILE"
  fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# --- Verify required tools ---
step "Verifying required tools"
for tool in brew git; do
  if ! command -v "$tool" &>/dev/null; then
    echo "Error: '$tool' is required but not installed."
    exit 1
  fi
done

# --- Git branching (update mode only) ---
now=$(date '+%Y%m%d')
if [[ "$mode" == "update" ]]; then
  step "Preparing git branch"
  # Verify GitHub CLI auth before doing any work
  if ! gh auth status &>/dev/null; then
    echo "Error: Not authenticated to GitHub. Run 'gh auth login' first."
    exit 1
  fi

  run git checkout main
  run git pull origin main
  run git fetch --prune

  # Clean up local branches already merged into main
  for branch in $(git branch --merged main | grep -v '^\*\|main'); do
    run git branch -d "$branch" 2>/dev/null || true
  done

  if [[ "$dry_run" == false ]]; then
    if git show-ref --verify --quiet "refs/heads/$now"; then
      git checkout "$now"
    else
      git checkout -b "$now"
    fi
  else
    echo "[dry-run] git checkout -b $now"
  fi
fi

# --- System and package updates ---
step "Running macOS software update"
run sudo softwareupdate -ia --verbose
step "Updating Homebrew"
run brew update

# Untap deprecated taps
step "Checking for deprecated taps"
deprecated_taps=$(brew tap 2>/dev/null | while read -r t; do
  if brew tap-info "$t" 2>&1 | grep -qi "deprecated"; then
    echo "$t"
  fi
done)
if [[ -n "$deprecated_taps" ]]; then
  echo "Untapping deprecated taps: $deprecated_taps"
  while read -r tap; do
    [[ -n "$tap" ]] || continue
    run brew untap "$tap"
  done <<< "$deprecated_taps"
fi

# Uninstall deprecated formulae
step "Checking for deprecated formulae"
while read -r formula; do
  [[ -n "$formula" ]] || continue
  echo "Uninstalling deprecated formula: $formula"
  run brew uninstall --ignore-dependencies "$formula"
done < <(brew info --installed --json=v2 2>/dev/null \
  | python3 -c "import sys,json;[print(f['full_name']) for f in json.load(sys.stdin).get('formulae',[]) if f.get('deprecated')]")

step "Upgrading Homebrew packages"
run brew upgrade

# Snapshot current state before installing (update mode only)
if [[ "$mode" == "update" ]]; then
  step "Snapshotting Brewfile"
  run brew bundle dump -f
fi

step "Installing from Brewfile"
run brew bundle -v
step "Cleaning up Homebrew"
run brew cleanup
run brew doctor -v || true
step "Upgrading other package managers"
if command -v mas &>/dev/null; then run mas upgrade || true; fi
if command -v az &>/dev/null; then run az upgrade --yes || true; fi

# --- Mackup ---
step "Managing application settings via Mackup"
if ! command -v mackup &>/dev/null; then
  echo "Warning: mackup not found, skipping settings backup/restore."
elif [[ "$mode" == "init" ]]; then
  run mackup restore
else
  run mackup backup -f
fi

# --- Git commit and PR (update mode only) ---
if [[ "$mode" == "update" ]]; then
  step "Committing and creating PR"
  if [[ "$dry_run" == true ]]; then
    echo "[dry-run] git add . && git commit -m 'ran update on $now'"
    echo "[dry-run] git push origin $now"
    echo "[dry-run] gh pr create --fill -B main"
    echo "[dry-run] gh pr merge --admin --squash --delete-branch"
  else
    # Stage and commit if there are uncommitted changes
    if ! git diff --quiet || ! git diff --cached --quiet; then
      git add .
      if git log main.."$now" --oneline | grep -q .; then
        git commit --amend -m "ran update on $now"
      else
        git commit -m "ran update on $now"
      fi
    fi

    # Check if the branch has any commits beyond main
    if ! git log main.."$now" --oneline | grep -q .; then
      echo "No changes to commit."
      git checkout main
      git branch -d "$now" 2>/dev/null || true
      exit 0
    fi

    # Push the branch
    if git ls-remote --heads origin "$now" | grep -q .; then
      git push --force-with-lease origin "$now"
    else
      git push --set-upstream origin "$now"
    fi

    # Create or find existing PR, then merge
    if ! gh pr view "$now" &>/dev/null; then
      pr_url=$(gh pr create --fill -B "main")
    else
      pr_url=$(gh pr view "$now" --json url -q '.url')
    fi
    gh pr merge "$pr_url" --admin --squash --delete-branch
    git checkout main
    git pull origin main
    git branch -d "$now" 2>/dev/null || true
  fi
fi

