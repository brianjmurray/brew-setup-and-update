#!/bin/bash
set -euo pipefail

now=$(date '+%Y%m%d%H%M%S')

git checkout main
git pull origin main
git checkout -b "$now"

sudo softwareupdate -ia --verbose
brew update
brew upgrade
brew bundle -v
brew cleanup
brew doctor -v
mas upgrade
brew bundle dump -f
az upgrade
mackup backup -f

if git diff --quiet && git diff --cached --quiet; then
  echo "No changes to commit."
  git checkout main
  git branch -d "$now"
  exit 0
fi

git add .
git commit -m "ran update on $now"
git push --set-upstream origin "$now"
gh pr create --fill -B "main"
gh pr merge --admin --squash --delete-branch
git checkout main
git pull origin main
git branch -d "$now" 2>/dev/null || true

