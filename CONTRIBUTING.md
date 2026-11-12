# Contributing to Halfstop

Thanks for your interest in Halfstop. Bug reports, ideas, documentation fixes and pull requests are all
welcome. By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Reporting bugs

Open an issue and include:

- your macOS version and Mac model (Apple Silicon or Intel)
- what you did, what you expected and what happened
- the type of photo involved (for example "Sony ARW" or "iPhone HEIC"), if relevant
- a screenshot or screen recording if it is a visual problem

Please do not attach photos you want to keep private.

## Suggesting features

Open an issue describing the problem you want solved, not only the solution. Halfstop's priorities are
**responsive sliders**, **an uncluttered interface** and **fast imports**, so changes that add
features without costing speed or clutter are the easiest to accept. For anything that changes the
interface, a quick sketch or mockup in the issue helps agree on a direction before code is written.

## Setting up

You need macOS 14 or later and the Swift 6 toolchain (Xcode 16+ or the Xcode command line tools).

```bash
git clone https://github.com/napalmj/halfstop.git halfstop
cd halfstop
./scripts/bundle.sh
open build/Halfstop.app
```

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for a map of the code.

## Before you open a pull request

1. Create a branch from `main`. Keep each pull request focused on one change.
2. Build a release bundle and run the self-test. It must print `EVERYTHING PASSED`:

   ```bash
   ./scripts/bundle.sh
   build/Halfstop.app/Contents/MacOS/Halfstop --selftest /tmp/halfstop-test
   ```

3. **Add a self-test case** (in `Sources/Halfstop/App/SelfTest.swift`) for any change to the develop
   pipeline, the library model or the sidecar format.
4. If you change a shortcut, update `HelpView.swift` and the shortcut table in the README.
5. If you add a setting to `Adjustments` or the sidecar, give it a default so existing sidecars still
   load. Never make a change that could rewrite or lose a user's photo files.
6. For performance-sensitive changes (anything in the render path), run `--bench` before and after and
   include the numbers in the pull request.
7. Describe what changed and why, and mention how you tested it. Add a line to
   [CHANGELOG.md](CHANGELOG.md) under "Unreleased" for user-visible changes.

## Code style

- Follow the style of the surrounding code. Swift with SwiftUI, no third-party dependencies unless
  discussed first.
- Keep UI work on the main actor and heavy image work off it.
- Prefer small, named functions and a comment explaining *why* over restating *what*.

## License

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
