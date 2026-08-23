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
```

No Apple Developer account is needed; the app is signed with a local self-signed
identity (`Asteria Development (Self-Signed)`) that `bootstrap.sh` creates on first
run. Run `./bootstrap.sh` once before building from Xcode.

## Development workflow

- **TDD-first** - The `AsteriaKit` core is test-driven: red → green →
  refactor. Add tests for any behavior change before committing, and run the
  package suite before you push.
- **Regenerate the project** - After adding, removing, or renaming files under
  the `Asteria/` app target, or after changing `project.yml`, run
  `xcodegen generate`. Never hand-edit `Asteria.xcodeproj/project.pbxproj`;
  it is generated output.
- **One feature per PR** - Keep pull requests focused on a single feature or
  fix so they stay easy to review and revert.

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
