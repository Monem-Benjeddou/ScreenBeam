# Contributing to ScreenBeam

Thanks for helping out! Bug reports, ideas, and pull requests are all welcome.

## Reporting bugs and asking for features

Use the [issue templates](https://github.com/Monem-Benjeddou/ScreenBeam/issues/new/choose). For bugs, include your macOS version, your Mac's chip (Apple Silicon or Intel), and steps to reproduce. **Security problems go through [private reporting](https://github.com/Monem-Benjeddou/ScreenBeam/security/advisories/new), not public issues.**

## Making a change

1. Fork the repository and create a branch from `main`.
2. Build and run it locally:
   ```sh
   cd mac && ./build-app.sh   # Mac app
   cd android && ./gradlew assembleDebug   # Android app
   ```
3. Keep each pull request focused on one change, and match the style of the code around it.
4. Open a pull request against `main` and fill in the template.

`main` is protected:
- every change arrives through a pull request
- the **Build** workflow must pass
- the pull request needs an approving review
- history stays linear, so pull requests are squashed or rebased when merged

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
