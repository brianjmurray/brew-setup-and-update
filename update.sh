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

if [[ $# -ne 1 ]]; then
  usage
fi

case "$1" in
  --init)   mode="init" ;;
  --update) mode="update" ;;
  *)        usage ;;
esac

# --- Git branching (update mode only) ---
now=$(date '+%Y%m%d')
if [[ "$mode" == "update" ]]; then
  git checkout main
  git pull origin main

  if git show-ref --verify --quiet "refs/heads/$now"; then
    git checkout "$now"
  else
    git checkout -b "$now"
  fi
fi

# --- System and package updates ---
sudo softwareupdate -ia --verbose
brew update

# Untap deprecated taps
deprecated_taps=$(brew tap 2>/dev/null | while read -r t; do
  if brew tap-info "$t" 2>&1 | grep -qi "deprecated"; then
    echo "$t"
  fi
done)
if [[ -n "$deprecated_taps" ]]; then
  echo "Untapping deprecated taps: $deprecated_taps"
  echo "$deprecated_taps" | xargs -n1 brew untap
fi

# Uninstall deprecated formulae and replace where applicable
for formula in python@3.9 tldr; do
  if brew list "$formula" &>/dev/null; then
    echo "Uninstalling deprecated formula: $formula"
    brew uninstall --ignore-dependencies "$formula"
  fi
done

brew upgrade

# Snapshot current state before installing (update mode only)
if [[ "$mode" == "update" ]]; then
  brew bundle dump -f
fi

brew bundle -v
brew cleanup
brew doctor -v || true
mas upgrade
az upgrade --yes

# --- Mackup ---
if [[ "$mode" == "init" ]]; then
  mackup restore
else
  mackup backup -f
fi

# --- Git commit and PR (update mode only) ---
if [[ "$mode" == "update" ]]; then
  if git diff --quiet && git diff --cached --quiet; then
    echo "No changes to commit."
    git checkout main
    git branch -d "$now"
    exit 0
  fi

  git add .
  if git log main.."$now" --oneline | grep -q .; then
    git commit --amend -m "ran update on $now"
    git push --force-with-lease origin "$now"
  else
    git commit -m "ran update on $now"
    git push --set-upstream origin "$now"
  fi

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

