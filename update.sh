#!/bin/bash
set -euo pipefail

now=$(date '+%Y%m%d')

git checkout main
git pull origin main

# Reuse existing branch for same-day re-runs
if git show-ref --verify --quiet "refs/heads/$now"; then
  git checkout "$now"
else
  git checkout -b "$now"
fi

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
brew bundle dump -f
brew bundle -v
brew cleanup
brew doctor -v || true
mas upgrade
az upgrade --yes
mackup backup -f

if git diff --quiet && git diff --cached --quiet; then
  echo "No changes to commit."
  git checkout main
  git branch -d "$now"
  exit 0
fi

git add .
# Amend if a commit already exists on this branch
if git log main.."$now" --oneline | grep -q .; then
  git commit --amend -m "ran update on $now"
  git push --force-with-lease origin "$now"
else
  git commit -m "ran update on $now"
  git push --set-upstream origin "$now"
fi

# Create PR only if one doesn't already exist for this branch
if ! gh pr view "$now" &>/dev/null; then
  pr_url=$(gh pr create --fill -B "main")
else
  pr_url=$(gh pr view "$now" --json url -q '.url')
fi
gh pr merge "$pr_url" --admin --squash --delete-branch
git checkout main
git pull origin main
git branch -d "$now" 2>/dev/null || true

