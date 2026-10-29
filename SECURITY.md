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
MacSweep only lists items it can remove: its safety rules must allow every path,
and nothing System Integrity Protection guards is listed. When macOS doesn't let
MacSweep remove a selected item itself, Finder moves it to the Trash and asks for
your password if the item belongs to the system. For permanent deletion, macOS asks
for your administrator password once for the whole batch. As administrator,
MacSweep runs only fixed system tools, checks that each item is still the exact
file or folder it scanned, never follows symbolic links and never crosses into
another drive. A Trash move never silently becomes permanent deletion. Removing an
installer package deletes only the files that package installed and no other
package shares.

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
