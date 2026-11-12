# Headroom

Menu bar meter for your Claude plan limits, across one or more Claude accounts, so you can see a limit coming before you hit it.

- The menu bar shows a small meter for each account, for both the 5-hour session and the weekly limit. Accounts are sorted alphabetically by name, here and in the popover. Each meter turns orange at 80% and red at 95%. Hover for each account's name and exact percentages.
- When usage credits (extra usage) are on and a limit is used up, every request against that limit is billed to credits, so that row turns blue in the menu bar and the popover says "Using usage credits". Claude Code's usage reply has no live in-use flag, so Headroom works this out from the reply: credits on, spending cap not reached, and the limit at 100%.
- Under each account's limits, the popover shows whether usage credits are on, how much they've cost this month, the monthly limit if you set one, and any prepaid balance Claude reports.
- Pick the meter style under Menu bar style in the popover:
  - **Dot matrix** (default): a braille-style dot grid, ten columns per row, one per 10%. Top rows 5-hour, bottom rows weekly.
  - **Hash and dots**: like an old terminal loading bar (`▮▮▮▮······`), solid where used and a dot where not.
  - **Horizontal meters**: solid bars. Top 5-hour, bottom weekly.
  - **Rings**: outer ring weekly, inner ring 5-hour, filling clockwise from the top.
  - **Stacked numbers**: tiny percentages, 5-hour above weekly.
  - **Vertical meters**: two columns that fill from the bottom. Left 5-hour, right weekly.
- Click it for every limit each account has (5-hour, weekly, and per-model weekly limits like Fable), each with its reset time. Uncheck Show Fable limit in the popover to hide the per-model ones.
- If you're using a limit faster than its window is passing, Headroom estimates when you'll run out at the current pace, if that's before the reset.
- Refreshes every 2 minutes by default. Pick 1, 2, 5, 10, 15 or 30 minutes under Refresh every in the popover. It also refreshes when you open it if the last check is over a minute old.

## Where the numbers come from

Headroom never touches your Claude logins. It asks Claude Code for the numbers through the `get_usage` request Claude Code offers to apps that host it, and Claude Code handles its own sign-in and token refresh. The numbers match `/usage` in Claude Code.

Each check runs `~/.local/bin/claude -p` in stream-json mode with no MCP servers, no settings, no slash commands, no saved session and a clean environment. It sends one `get_usage` request and quits. That takes about a second and makes no model call, so it costs nothing. Claude Code labels the request experimental, so a future Claude Code update could change the response shape.

## Accounts

The first account is whichever one your terminal `claude` is signed in to (`~/.claude`). Headroom can't remove it, but you can rename it.

**Add account** gives the new account its own Claude Code config folder in `~/Library/Application Support/Headroom/Accounts/` and opens Terminal to run `claude auth login` with `CLAUDE_CONFIG_DIR` set to that folder. Sign in in the browser with the account you want. If the browser is already signed in to a different Claude account, switch accounts there first. After you approve, the page shows a code: paste it into Terminal and press Return. Headroom picks up the new account a few seconds after you finish. Claude Code stores each folder's login under its own Keychain entry (`Claude Code-credentials-<hash of the folder>`), so adding an account never signs your terminal `claude` out of its own.

If you sign in to an account Headroom already tracks, its section warns you. Use **Sign In Again…** from its ⋯ menu to fix that. **Remove Account** runs `claude auth logout` for that folder, which deletes only that folder's Keychain entry, and then deletes the folder.

The Claude desktop app keeps its own login, which Headroom can't read. To track the account the desktop app uses, add it here too.

## Install

There are no prebuilt releases, so you build Headroom from source. You need an Apple silicon Mac on macOS 14 or later, the Swift compiler (Xcode or the Command Line Tools: `xcode-select --install`), and Claude Code at `~/.local/bin/claude`, signed in.

```sh
git clone https://github.com/jackrieger/headroom.git
cd headroom
./build.sh --install
```

`./build.sh --install` does this:

1. Compiles `Sources/*.swift` into `build/Headroom.app`.
2. Signs the app with the first Apple Development certificate in your Keychain, or ad-hoc if you don't have one. A real certificate keeps the login item registered across rebuilds; an ad-hoc signature changes with every build.
3. Quits any running Headroom, replaces `/Applications/Headroom.app`, and launches it.

Run `./build.sh` without `--install` to build `build/Headroom.app` only.

Headroom adds itself as a login item on first launch. Turn that off with the checkbox in its popover.

To update, `git pull` and run `./build.sh --install` again. To uninstall, quit Headroom, delete `/Applications/Headroom.app`, and, if you added accounts, remove each one from the popover first and then delete `~/Library/Application Support/Headroom`.

### Build fails with "plugin for module 'SwiftUIMacros' not found"

Newer macOS SDKs implement SwiftUI's `@State` as a macro, and the Command Line Tools don't ship its plugin (Xcode does). Without Xcode, build against an older SDK from the Command Line Tools:

```sh
ls /Library/Developer/CommandLineTools/SDKs
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./build.sh --install
```

Pick a macOS 26 SDK from the list. The macOS 27 SDKs have the problem.

## Icon

The icon is the Dot matrix meter, drawn by `tools/icon/main.swift`. To redraw it:

```sh
swiftc -O -o build/tools/icon tools/icon/main.swift && build/tools/icon build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
```
