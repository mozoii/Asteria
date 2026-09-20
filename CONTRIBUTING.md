# Contributing to Asteria

Thanks for your interest in contributing! Contributions are welcome and are
accepted under the project's GPLv3 license (see [`LICENSE`](LICENSE)).

## Getting started

1. Fork the repository and create a branch for your change.
2. Install the build requirements:
   - macOS 26 or later on an Apple Silicon Mac (`arm64`)
   - [Xcode](https://developer.apple.com/xcode/) (auto-detected from
     `/Applications`; override with `DEVELOPER_DIR`)
   - [xcodegen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
3. Build and test:

```bash
./bootstrap.sh --test      # generate project, build, sign, run the test suite
./bootstrap.sh --release   # optimized build
./bootstrap.sh --doctor    # only verify the environment (OS, chip, Xcode, Swift) and regenerate the project
./bootstrap.sh --ios       # build the iPhone/iPad app (see README for signing)
./bootstrap.sh --test-ios  # run the AsteriaKit suite on an iOS simulator
```

No Apple Developer account is needed for the Mac app; it is signed with a local
self-signed identity (`Asteria Development (Self-Signed)`) that `bootstrap.sh`
creates on first run. Run `./bootstrap.sh` once before building from Xcode. The
iOS app does need a team, because iOS devices refuse self-signed code — a free
personal team is enough. See [`README.md`](README.md#building-for-iphone-and-ipad).

## Development workflow

- **TDD-first** - The `AsteriaKit` core is test-driven: red → green →
  refactor. Add tests for any behavior change before committing, and run the
  package suite before you push.
- **Regenerate the project** - After adding, removing, or renaming files under
  the `Asteria/` app target, or after changing `project.yml`, run
  `xcodegen generate`. Never hand-edit `Asteria.xcodeproj/project.pbxproj`;
  it is generated output.
- **Build both apps** - `Asteria/` is shared by the macOS and iOS targets, so a
  change to anything outside `Asteria/Platform/` has to build for both.
- **Every platform, every feature** - A feature is done when it works on every
  platform Asteria supports, currently macOS and iOS (iPhone), not
  when it works on the one you built it on. If a platform genuinely can't
  support it, say so in the PR.
- **One feature per PR** - Keep pull requests focused on a single feature or
  fix so they stay easy to review and revert.

## Platform code

The two app targets compile the same sources. Everything that names an
AppKit or UIKit type lives under `Asteria/Platform/macOS/` or
`Asteria/Platform/iOS/`, and each target excludes the other's folder — so a
file in a platform folder needs no `#if os(...)` and a file outside one should
need no platform import.

When a screen needs something platform-specific, add a **seam**: one type or
view modifier with the same name and shape in both folders (`DisplayProbe`,
`SystemClipboard`, `streamWindowChrome`, `PlatformImage`). Shared code calls the
seam and stays readable; the platform difference sits in one small file with a
comment saying why the platforms differ. `PlatformCopy` does the same job for
user-facing wording that names the device.

`AsteriaKit` is shared wholesale and uses `#if os(macOS)` in the handful of
places where a framework genuinely differs (the HTTPS transport, audio output
sizing, display reconfiguration).

## Code style

- **Readable code** - Self-documenting code; comments only for non-obvious
  *why*.
- **Swift Testing, not XCTest** - Tests use `@Suite` / `@Test` / `#expect`,
  and test targets mirror source targets.
- **Strict concurrency** - Swift 6 with strict concurrency enabled; keep
  network engine internals as actors and UI-facing state on the main actor.
- **Vendored C is frozen** - Don't modify the sources of the vendored
  libraries (`CENet/`, `CNanors/`, `COpus/`); adapters live alongside them.
  If dependencies change, keep
  [`ThirdPartyLicenses.md`](Asteria/Resources/ThirdPartyLicenses.md) in sync.

## Commit messages

Follow [Conventional Commits](https://www.conventionalcommits.org):
`type(scope): short imperative subject`, for example:

```text
fix(pairing): resolve correct TLS identity by fingerprint
feat(video): add MetalFX upscaling toggle
```

Keep the body brief and only when context is needed.

## Pull requests

- Describe what the change does and why; link related issues if any.
- Make sure the full `AsteriaKit` suite passes (`./bootstrap.sh --test`) and
  the app builds before opening the PR.
- Small, focused PRs get reviewed faster.

## Reporting bugs

Open a GitHub issue and include:

- Your macOS version and Mac model
- Host software and version (Sunshine, Apollo, Vibepollo)
- Steps to reproduce, expected vs actual behavior
- Any relevant console output

## License

By contributing, you agree that your contributions will be licensed under
the [GNU General Public License v3](LICENSE) (GPLv3).
