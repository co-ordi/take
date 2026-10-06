# Building Take with an AI coding assistant

This file is for AI coding assistants (Claude Code, Codex, Cursor and the like). The goal is simple: build Take from this repo and install it on the user's Mac, then hand over to them for the permission prompts.

## Before building

1. Check the Mac is on macOS 15 or later: `sw_vers -productVersion`.
2. Check Apple's Command Line Tools are installed: `xcode-select -p`. If that fails, run `xcode-select --install`. It opens a macOS dialog the user has to accept, so tell them, wait for it to finish, then carry on. Full Xcode is not needed.
3. Make sure the screen is unlocked (signing can show a keychain dialog).

## Build and install

From the repo root:

```sh
osascript -e 'quit app "Take"' 2>/dev/null   # only if it's already running
./build.sh
open ~/Applications/Take.app
```

`build.sh` compiles `Sources/*.swift` with `swiftc`, assembles `Take.app` with `Info.plist` and the icon, signs it, and installs it to `~/Applications/Take.app`. Take lives in the menu bar (a small circle), not the Dock.

## Hand over to the user

Tell them:

- Click Take's circle in the menu bar. The **Set up Take** card lists what it needs; click **Allow all**.
- Screen recording has to be switched on in System Settings (Take opens the right page): switch **Take** on, then **Quit & Reopen**.
- Allow the microphone, and the camera if they turn on the camera bubble.
- Record with the **Record** button or **⌃⌥⌘R**; recordings save to `~/Movies/Take`.

## Rules for the assistant

- Don't change macOS privacy settings, run `tccutil`, or use `sudo` on the user's behalf. Permission prompts are theirs to approve.
- Don't add personal details, keys or machine-specific paths to the repo.
- Keep edits to what the user asks for. `README.md` explains every feature and has a "What's where" table for finding code.

## Troubleshooting

- **`swiftc` not found:** the Command Line Tools aren't installed (step 2 above).
- **Build errors about missing APIs:** the Mac is older than macOS 15.
- **Permissions asked again after every rebuild:** builds are signed ad hoc by default. The user can create a local code-signing certificate named **Take Local Signing** (Keychain Access → Certificate Assistant → Create a Certificate…, type Code Signing) and `build.sh` will use it, so permissions stick.
- **Permissions in a muddle:** the user can reset them with `tccutil reset All com.coordi.take` and approve again.
- **Built but not installed:** Take was running. Quit it and run `./build.sh` again.
