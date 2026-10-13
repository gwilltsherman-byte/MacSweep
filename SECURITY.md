# Security

If you find a security problem, please report it privately. Use GitHub's private
vulnerability reporting from the Security tab when available. If that option is
unavailable, open an issue asking me for a private reporting channel without
including vulnerability details.

Please keep file listings, credentials and personal files out of public issues.
For ordinary bugs, describe the steps you took and the result you expected.

## Using MacSweep safely

Review each selected item and the confirmation sheet before removing anything.
MacSweep normally moves files to the Trash. Some system commands, such as emptying
the Trash or removing a Time Machine snapshot, cannot be undone. Keep a backup
of important files.

Grant Full Disk Access only if you want MacSweep to scan protected folders.
File removal does not automatically escalate to administrator access. If a
Trash move fails, MacSweep leaves the file in place. Use an app's own uninstaller
for privileged installer files.

Local builds use an ad hoc signature. A public release needs a Developer ID
signature and notarization. See [README.md](README.md) for the release process.

## Repository and fork security

Every branch in this repository blocks force pushes and deletion, including for
administrators. If you maintain a fork, apply equivalent protection and choose
status checks that fit your contribution process.

Use passkeys or hardware security keys for GitHub and hosting accounts, keep
recovery codes offline, and review installed apps and token permissions. Check
usage limits and billing alerts before enabling paid runners, large build
artifacts, Codespaces, LFS or other metered services on a fork.

Keep the app updated and retain backups. These safeguards reduce risk but cannot
prevent every software defect.
