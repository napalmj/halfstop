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
- a request to the local AI control server that gets past its checks or does more than edit the open photo

You can expect an acknowledgement within a few days. Fixes are made as soon as is practical and you will
be credited in the changelog if you wish.

## Scope notes

- Halfstop makes no network requests to outside services and stores no accounts or API keys.
- The optional local AI control server (Settings ▸ Local AI control, off by default) listens on
  127.0.0.1 only and requires a random bearer token, kept in the login keychain. Ways around its
  token, Host or Origin checks, or ways to reach it from another machine or a web page, are in
  scope.
- Image decoding is done by macOS (ImageIO and Core Image). Vulnerabilities in the system decoders
  should be reported to Apple.
- Release builds are ad-hoc signed and not notarized. Build from source and review the code if you
  need to trust the binary.
