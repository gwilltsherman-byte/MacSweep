# Security

Report vulnerabilities privately using this repository's Security tab (Report a vulnerability). Do not post secrets, personal workout backups, or private file listings in public issues.

## Account and hosting controls

Use passkeys or hardware security keys for GitHub and hosting accounts. Keep recovery codes offline. Review installed apps and token scopes. Protect main with pull requests, passing checks, resolved conversations and no force pushes or deletion; apply the rule to administrators too. A solo maintainer can require checks without requiring a second person's approval.

Use GitHub Pages for the static Milo app and GitHub Releases for MacSweep downloads. No backend, API key or metered serverless service is required.

Review GitHub Budgets and alerts for Actions, storage, Codespaces and LFS; enable Stop usage when budget limit is reached where supported. GitHub notes some storage budgets may be exceeded in their first cycle. Avoid paid runners and unnecessary artifact retention.

References: https://docs.github.com/en/billing/how-tos/set-up-budgets

No configuration makes software invulnerable. Keep backups and update promptly.
