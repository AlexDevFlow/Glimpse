# Security

Glimpse records your screen and, when you ask it to, your microphone. It runs
without the App Sandbox and is distributed without Apple notarisation. That makes
security reports worth taking seriously, so please send them privately rather than
opening a public issue.

## Reporting

Use GitHub's private vulnerability reporting: the **Security** tab of this
repository → **Report a vulnerability**. That opens a private thread visible only
to the maintainers.

Please include what you were doing, what happened, the macOS version, and whether
you were running a release build or one you compiled yourself.

## What is in scope

- Anything that lets another process obtain screen or microphone data through
  Glimpse, or borrow the Screen Recording permission it holds.
- Anything that writes capture data somewhere the user did not choose.
- Anything in the build or release pipeline that could put code into a release
  artefact.

## What is known and not a vulnerability

- **Releases are ad-hoc signed and not notarised.** This project has no paid Apple
  Developer account. That is a distribution limitation, documented in the README,
  not a report.
- **The app is not sandboxed.** A sandboxed app cannot capture other applications'
  windows, which is the entire purpose here.
- **The diagnostic log** at `~/Library/Logs/Glimpse.log` is created readable only
  by its owner and records capture formats and error descriptions, no window
  titles, no file contents, no screen data.

## Supported versions

Only the latest release. This is a small project with a single maintainer.
