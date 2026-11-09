# Headroom

Menu bar meter for your Claude plan limits, so you can see a limit coming before you hit it.

- The menu bar shows two small bars (top: the 5-hour session, bottom: the weekly limit) and the higher of the two percentages. The number turns orange at 80% and red at 95%.
- Click it for every limit Claude reports (5-hour, weekly, and per-model weekly limits like Fable), each with its reset time.
- The tick on each bar shows how much of that window has passed. When usage is ahead of the tick, Headroom estimates when you'll run out at the current pace, if that's before the reset.
- Refreshes every 5 minutes, and when you open it if the last check is over a minute old.

## Where the numbers come from

Headroom never touches your Claude login. It asks Claude Code for the numbers through the `get_usage` request Claude Code offers to apps that host it, and Claude Code handles its own sign-in and token refresh. The numbers match `/usage` in Claude Code.

Each check runs `~/.local/bin/claude -p` in stream-json mode with no MCP servers, no settings, no slash commands and no saved session. It sends one `get_usage` request and quits. That takes about a second and makes no model call, so it costs nothing. Claude Code labels the request experimental, so a future Claude Code update could change the response shape.

The limits are for whichever account the terminal `claude` is signed in to, shown under the title. The Claude desktop app can be signed in to a different account. To track a different account, sign the terminal `claude` in to it with `/login`.

## Build

```sh
./build.sh            # builds build/Headroom.app
./build.sh --install  # copies to /Applications and launches it
```

Headroom adds itself as a login item on first launch. Turn that off with the checkbox in its popover.
