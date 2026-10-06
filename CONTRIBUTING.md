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

## Testing crash recovery

Both apps recover from crashes by themselves. These switches crash or freeze them on purpose, so you can check that recovery works:

| | Command | What happens |
|---|---|---|
| Mac | `defaults write com.screenbeam.mac debug.crashOnLaunch -int 3` | The next 3 launches crash 2 s in. Expect: reopened, then safe mode, then not reopened |
| Mac | `defaults write com.screenbeam.mac debug.hangOnLaunch -bool YES` | The main thread freezes once. Expect: reopened after about 9 s |
| Phone | `adb shell setprop debug.screenbeam.crash 3` | Same as the first Mac row. Reset with `setprop debug.screenbeam.crash 0` |

Recovery state lives in `~/Library/Application Support/ScreenBeam/state.json` (Mac). To see the window in each state with demo data, run `ScreenBeam --render-preview out.png safemode`. The other states are `setup`, `recovered`, `failed`, `noaccess` and `extend`.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
