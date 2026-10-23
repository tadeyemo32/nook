# Contributing to Nook

Thanks for helping. Bug reports, fixes and new features are all welcome.

## Reporting a bug

Open an issue with your macOS version, your Mac (Apple Silicon or Intel), what you
expected and what happened. For now-playing problems, say which player you used.

Security issues: report them privately via **Report a vulnerability** on the Security
tab, not in a public issue.

## Making a change

1. Fork the repo and create a branch from `main`.
2. Build and run it (needs Xcode 16 or later):

   ```sh
   sh scripts/install.sh     # build, sign, install to /Applications and launch
   swift run                 # quick dev run (no XPC helper: Music/Spotify only)
   swift test                # unit tests
   ```

3. Keep the change focused: one fix or feature per pull request. Match the style of the
   code around it. [Layout](README.md#layout) in the README shows where things live.
4. If you add a feature that needs a new permission, add it to the
   [Permissions](README.md#permissions) table, and make sure it is asked for only when
   the feature is on.
5. Open a pull request saying what changed, why, and how you tested it (macOS version,
   screenshots for UI changes). CI runs the tests, builds a universal app and launches it on
   macOS 14, 15 and 26. It must pass before merge.

For a large feature, open an issue first so we can agree on the approach before you
spend time on it.

## License

Nook is [GPL-3.0](LICENSE). By opening a pull request you agree that your contribution
is licensed under the same terms.
