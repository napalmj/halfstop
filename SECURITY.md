# Security policy

## Supported versions

Halfstop is early software. Only the latest commit on `main` is supported with fixes.

## Reporting a vulnerability

Please **do not open a public issue** for a security problem. Use GitHub's private vulnerability
reporting (**Security ▸ Report a vulnerability** on the repository page), or contact a maintainer
privately through the details on their GitHub profile.

Include what you found, how to reproduce it and the possible impact. Examples of what matters here:

- a crafted image file that crashes Halfstop or runs unexpected code
- a way to make Halfstop delete, overwrite or read files outside the folders you imported
- a malformed sidecar or catalog file that causes data loss
- a way to make the `halfstop` command write anywhere but Halfstop's own edit files and the JPEG you ask `render` for

You can expect an acknowledgement within a few days. Fixes are made as soon as is practical and you will
be credited in the changelog if you wish.

## Scope notes

- Halfstop makes no network requests to outside services and stores no accounts or API keys.
- The `halfstop` command-line tool runs with the permissions of whoever runs it and only reads and
  writes local files: photos are only read; it writes Halfstop's sidecar files and the JPEG `render`
  is asked for (never over a photo, a link or an existing file without `--force`). It listens on no
  port. Arguments are validated strictly; ways to make it change photo files, lose edits, or write
  elsewhere are in scope.
- Image decoding is done by macOS (ImageIO and Core Image). Vulnerabilities in the system decoders
  should be reported to Apple.
- Release builds are ad-hoc signed and not notarized. Build from source and review the code if you
  need to trust the binary.
