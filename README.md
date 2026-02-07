# brew-setup-and-update

Automate macOS system setup and ongoing maintenance using Homebrew, the Mac App Store, and other CLI tools. Changes are tracked via Git with automatic PR creation and merging.

## What's included

| File | Purpose |
|---|---|
| `update.sh` | Single script for both initial setup and periodic updates — controlled via `--init` or `--update` flag |
| `Brewfile` | Declarative list of taps, formulae, casks, Mac App Store apps, and VS Code extensions managed by Homebrew Bundle |

## Prerequisites

- [Homebrew](https://brew.sh) installed
- [GitHub CLI](https://cli.github.com) (`gh`) authenticated

The following are installed automatically via the Brewfile:

- [mas](https://github.com/mas-cli/mas) — Mac App Store CLI
- [Mackup](https://github.com/lra/mackup) — app settings backup/restore

> **Optional**: If you use Mackup backed by iCloud, sign in to iCloud before running the initial setup so Mackup can restore your app settings. The Brewfile itself is tracked via Git — not iCloud — so it works reliably across machines without sync conflicts.

## Initial setup (new Mac)

1. Install Homebrew: <https://brew.sh>
2. Fork this repository and clone your fork
3. Run with `--init`:

```bash
./update.sh --init
```

This will install all formulae, casks, and apps from the Brewfile, then restore app settings from Mackup.

## Periodic updates

Run with `--update` every couple of weeks to keep everything current:

```bash
./update.sh --update
```

### What it does

1. Checks out `main` and pulls latest changes
2. Creates a date-based branch (`YYYYMMDD`) — reuses the same branch on same-day re-runs
3. Runs macOS software updates (`softwareupdate`)
4. Updates and upgrades all Homebrew packages
5. Automatically untaps deprecated taps and uninstalls deprecated formulae
6. Snapshots current installed state to the Brewfile (`brew bundle dump`)
7. Installs anything in the Brewfile not yet present (`brew bundle`)
8. Cleans up old package versions and runs `brew doctor`
9. Upgrades Mac App Store apps, Azure CLI, and backs up settings via Mackup
10. Commits changes, creates a GitHub PR, squash-merges it, and cleans up branches

If there are no changes after all updates, the script exits cleanly without creating a PR.

## Managing applications

- **Install**: Add the entry to the `Brewfile` and run `./update.sh --update`, or install directly and let `brew bundle dump` capture it on the next run
- **Uninstall**: Remove the application first (e.g., `brew uninstall <formula>`), then run `./update.sh --update` — the dump step will remove it from the Brewfile automatically before `brew bundle` has a chance to reinstall it

## Re-running after a failure

The script is designed to be re-run safely on the same day. If it fails partway through:

- The date-based branch is reused (not duplicated)
- Most update commands are idempotent
- Commits are amended and force-pushed rather than stacked
- PR creation is skipped if one already exists for the branch

## Personalizing your fork

After forking and cloning (see Initial setup), delete the existing `Brewfile` (it reflects the author's installed applications) and run `./update.sh --update` — a new Brewfile will be generated from your currently installed applications.
