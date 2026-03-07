#!/bin/bash
set -euo pipefail

usage() {
  echo "Usage: ./update.sh [--init | --update]"
  echo ""
  echo "  --init    Initial setup for a new Mac. Installs everything from the"
  echo "            Brewfile and restores app settings via Mackup."
  echo "  --update  Periodic update. Upgrades packages, snapshots the Brewfile,"
  echo "            and commits changes via GitHub PR."
  exit 1
}

step() { echo ""; echo "==> $1"; }

if [[ $# -ne 1 ]]; then
  usage
fi

case "$1" in
  --init)   mode="init" ;;
  --update) mode="update" ;;
  *)        usage ;;
esac

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

  git checkout main
  git pull origin main
  git fetch --prune

  # Clean up local branches already merged into main
  for branch in $(git branch --merged main | grep -v '^\*\|main'); do
    git branch -d "$branch" 2>/dev/null || true
  done

  if git show-ref --verify --quiet "refs/heads/$now"; then
    git checkout "$now"
  else
    git checkout -b "$now"
  fi
fi

# --- System and package updates ---
step "Running macOS software update"
sudo softwareupdate -ia --verbose
step "Updating Homebrew"
brew update

# Untap deprecated taps
step "Checking for deprecated taps"
deprecated_taps=$(brew tap 2>/dev/null | while read -r t; do
  if brew tap-info "$t" 2>&1 | grep -qi "deprecated"; then
    echo "$t"
  fi
done)
if [[ -n "$deprecated_taps" ]]; then
  echo "Untapping deprecated taps: $deprecated_taps"
  echo "$deprecated_taps" | xargs -n1 brew untap
fi

# Uninstall deprecated formulae
step "Checking for deprecated formulae"
while read -r formula; do
  [[ -n "$formula" ]] || continue
  echo "Uninstalling deprecated formula: $formula"
  brew uninstall --ignore-dependencies "$formula"
done < <(brew info --installed --json=v2 2>/dev/null \
  | python3 -c "import sys,json;[print(f['full_name']) for f in json.load(sys.stdin).get('formulae',[]) if f.get('deprecated')]")

step "Upgrading Homebrew packages"
brew upgrade

# Snapshot current state before installing (update mode only)
if [[ "$mode" == "update" ]]; then
  step "Snapshotting Brewfile"
  brew bundle dump -f
fi

step "Installing from Brewfile"
brew bundle -v
step "Cleaning up Homebrew"
brew cleanup
brew doctor -v || true
step "Upgrading other package managers"
if command -v mas &>/dev/null; then mas upgrade || true; fi
if command -v az &>/dev/null; then az upgrade --yes || true; fi

# --- Mackup ---
step "Managing application settings via Mackup"
if ! command -v mackup &>/dev/null; then
  echo "Warning: mackup not found, skipping settings backup/restore."
elif [[ "$mode" == "init" ]]; then
  mackup restore
else
  mackup backup -f
fi

# --- Git commit and PR (update mode only) ---
if [[ "$mode" == "update" ]]; then
  step "Committing and creating PR"
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

