# Nook

A Dynamic Island for the Mac notch. Free and open source (GPL-3.0). Written from
scratch: no code or assets from any other notch app.

Works on any Mac running **macOS 14 Sonoma or later**, Apple Silicon or Intel. Macs
without a notch (and external displays) get a pill-shaped island instead.

## What it does

- **The island** sits over the notch (a pill on notchless displays, or always shown with
  the simulated notch), on one display or all of them. It has Apple's continuous corners
  and tuned springs, and grows a few points on hover. Tap it or swipe down to
  open it. Drop files on it to put them on the shelf.
- **Now playing** from any app (MediaRemote helper, with AppleScript as the fallback):
  artwork, seekable progress, shuffle / previous / play-pause / next / repeat, and an
  album-colour tint, and an output device picker. Tap the artwork to open the player.
  Swipe to skip, or set swipes to seek ±10 s. The waveform is animated per track; the
  live waveform is opt-in (macOS shows its purple recording dot while it runs).
- **Live activities**, one at a time, highest priority first:
  - alerts as a symbol plus a value, like the iPhone: charging, low battery, Low Power
    Mode, AirPods / Bluetooth with battery, timer done, downloads done, calendar events;
  - lock and unlock;
  - connector activities (Claude waiting on you, build progress);
  - the timer and downloads;
  - now playing;
  - camera / mic in use.
- **HUD** that replaces the system volume and brightness overlay (needs Accessibility).
- **Pages in the open island:** Home (now playing or a clock, plus the calendar,
  reminders and weather if on) and Shelf (files, AirDrop). Agents appears while Claude Code or Codex has
  usage to show. Opt-in: Widgets (plugins), Clipboard history (skips passwords), System
  stats, Timer, Mirror.
- **Lock screen:** the island with a lock, plus a Liquid Glass now-playing card,
  with weather / battery / timer above it. Its height is adjustable.
- **Coding agents:** Claude Code and Codex usage side by side beside the notch, each with
  its logo, and an Agents page with every limit and the session details you pick. Alerts
  for permission, questions, finished, waiting, subagents, compacting and sessions, each
  with its own switch, from Claude Code, Codex, Cursor and Gemini CLI.
- **Background tasks:** type `/nook <task>` in Claude Code or Codex (or `nook run` in a
  shell), close the terminal, and Nook runs the agent and holds the session: its logo
  sits in the notch while it works, and Done (or Failed) shows when it finishes. Pick
  the session back up in Terminal from the Agents page.
- **Meetings and reminders:** a Join button on calls (Zoom, Meet, Teams, Webex, FaceTime),
  today's reminders with a tick to complete them, and synced lyrics under the artist.
- **Connectors:** a `nook` command, Shortcuts actions and a Focus filter, GitHub
  notifications, ntfy push alerts, Home Assistant tiles, script plugins in any language,
  and `nook://` links for everything else.
- **Settings window** (menu bar → Settings…, ⌘,) in the style of System Settings.
  Display choice, notch size tuning, outlines, hide in fullscreen, hide from screen
  recordings.

## Install

### Option 1: download the app

1. Download `Nook.dmg` from the [latest release](https://github.com/tadeyemo32/nook/releases/latest)
   and double-click it to open.
2. Drag `Nook.app` onto the **Applications** shortcut.
3. Nook isn't notarized by Apple (that needs a paid developer account), so macOS blocks
   it the first time. Open Terminal and run:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Nook.app
   ```

   Or: open Nook once, click **Done** on the warning, then go to **System Settings →
   Privacy & Security**, scroll down and click **Open Anyway**.
4. Open Nook from Applications or Spotlight. It lives in the menu bar (no Dock icon);
   the island appears at the top of the screen. Settings: menu bar icon → Settings… (⌘,).
5. Optional: start it at login in **System Settings → General → Login Items → +**.

macOS asks for each permission only when you turn on the feature that needs it (see
[Permissions](#permissions)).

### Option 2: build from source

Needs Xcode 16 or later (free on the App Store).

```sh
git clone https://github.com/tadeyemo32/nook.git
cd nook
sh scripts/install.sh     # builds, signs, installs to /Applications and launches
```

Other commands:

```sh
swift run                            # quick dev run (no XPC helper: Music/Spotify only)
swift test                           # unit tests
sh scripts/bundle.sh                 # just build build/Nook.app for this Mac
UNIVERSAL=1 sh scripts/bundle.sh     # Apple Silicon + Intel build (needs full Xcode)
open build/Nook.app --args --preview-lock-screen   # the lock-screen layout on the desktop
open build/Nook.app --args --slow-animations       # the island's motion 5× slower, for tuning
```

### Uninstall

Quit Nook from its menu, delete `/Applications/Nook.app`, and optionally
`~/Library/Application Support/Nook`. If you connected a coding agent or installed the
`/nook` skill, click Disconnect and Remove in Settings → Coding Agents first.

### Troubleshooting

- **"Nook is damaged and can't be opened"**: run the `xattr` command from step 3.
- **Volume / brightness HUD doesn't work**: give Nook Accessibility access (Settings →
  HUD). After updating Nook, macOS can keep a stale entry: use Reset there.
- **Now playing shows nothing**: MediaRemote is a private macOS API and can change with
  macOS updates; Nook then falls back to Music and Spotify via AppleScript. Please open an
  issue with your macOS version.

**Versioning.** `VERSION` holds the semantic version. The build number is the git
commit count. Both are stamped in by `bundle.sh` and shown at the top of the menu bar
menu. For a release, bump `VERSION`, add a `CHANGELOG.md` section, commit, then tag and
push `vX.Y.Z`: CI builds a universal app, launches it on macOS 14, 15 and 26 (Apple
Silicon and Intel) and attaches `Nook.dmg` and `Nook.zip` to a GitHub release.

**Signing.** `bundle.sh` signs with your first Apple Development / Developer ID
certificate (override with `SIGN_IDENTITY="..."`), so macOS keeps Nook's permissions
across rebuilds. Without a certificate (CI) it signs ad-hoc, and every build is a new
app to macOS.

## Permissions

Each one is asked for only when its feature is on.

| Permission | Feature |
| --- | --- |
| Accessibility | Replace the system HUD (asked once; Settings → HUD shows the status and can reset a stale entry) |
| Audio Capture | Live waveform (off by default; macOS shows a purple dot while it runs) |
| Bluetooth | AirPods and device connections |
| Camera | Mirror page |
| Calendars | Calendar on Home, event alerts, Join buttons |
| Reminders | Reminders on Home and their alerts |
| Local Network | Home Assistant on your own network |
| Location | Weather (Open-Meteo) |
| Downloads folder | Download activity |
| Automation (Music / Spotify) | AppleScript fallback for now playing |

## Connectors

### Coding agents: Claude Code and Codex

Settings → Coding Agents. **Claude Code → Connect** adds hooks (Notification, Stop,
StopFailure, SubagentStop, UserPromptSubmit, PreCompact, SessionStart, SessionEnd) and, if you have
none, a status line to `~/.claude/settings.json`, saving a backup at
`settings.json.nook-backup`. **Codex → Connect** adds Stop, UserPromptSubmit and
SessionStart hooks to `~/.codex/hooks.json` (Codex asks you to trust them once). New
sessions then show, each with the agent's logo and its own switch:

- **needs permission** or **has a question**: an orange hand with the project name, until
  you answer;
- **done** when a reply really finishes: if it ends with background tasks still running,
  prompts scheduled or a question for you, the alert says "2 running", Scheduled or
  Question instead (from the Stop hook's own fields), and API errors show as failures;
- **waiting for you**, **subagent done**, **compacting**, **session started / ended**;
- **usage**: each agent's busiest limit beside the notch (percent used, percent left or a
  battery), side by side when both run. An agent shows while it's working and for 5
  minutes after; a Claude session that ends disappears at once (Codex has no session-end
  hook, so it waits out the 5 minutes). Or show it whenever its limits are known; the Agents page lists every limit with its reset
  time, plus model, effort, plan, context, cost and lines if you want them; alerts at 80,
  90 and 95%.

Claude's usage comes from its status-line data. Codex's comes from its own session logs
in `~/.codex/sessions` with no connection needed (finished sessions are zstd-compressed:
`brew install zstd`). Only the alert type, message and project folder reach Nook, never
prompts or transcripts. Disconnect removes exactly what Connect added.

Settings → Coding Agents also connects **Cursor** (`~/.cursor/hooks.json`: finished,
failed, subagents, compacting, sessions) and **Gemini CLI** (`~/.gemini/settings.json`:
permission, finished, compacting, sessions). Nook only adds hooks that observe, so they
can't block anything.

### Background tasks: the `/nook` skill

Settings → Coding Agents → Background tasks → **Install** puts a `nook` skill in
`~/.claude/skills` or `~/.codex/skills`. In a session, type:

```
/nook fix the flaky login test and open a PR
```

The agent hands the task to `nook run`, which leaves a request in
`~/Library/Application Support/Nook/Tasks` and pings Nook. Nook runs `claude -p` or
`codex exec` in that folder itself, so you can close the terminal (or quit the agent).
The notch shows the agent's logo and a spinner while it works, then Done or Failed with a
sound. The Agents page lists recent tasks with their summary, a Stop button, and
**Continue in Terminal**, which reopens the session (`claude --resume`, `codex resume`).

- Claude's background run forks your current session, so it keeps the whole conversation.
  Codex starts fresh from a self-contained brief the agent writes.
- What a task may do is set in Settings: Claude's auto mode (the default), edit files
  only, or anything. Codex is sandboxed to the project unless you pick anything.
- Tasks keep running if Nook quits; Nook picks them up again when it starts.

Without the skill, from any terminal: `nook run "update the changelog"`, or
`nook run --agent codex -- "…"`.

### The `nook` command

Settings → Coding Agents → **Install nook Command** links `nook` into your PATH
(`/opt/homebrew/bin`, `/usr/local/bin` or `~/.local/bin`). It's the Nook app itself, so it
can do what the links do:

```sh
nook show "Deploy done" --value 42s --symbol checkmark.circle.fill --tint green
nook progress build 40% --title Building    # then: nook done build
nook timer 25
nook open agents
nook run "write tests for the parser"
```

### Shortcuts and Focus

Nook adds actions to the Shortcuts app: **Show Alert**, **Show Progress** and **Finish
Progress**, **Start Timer**, **Open Nook**, **Run Agent Task in Background** and **Join
Next Meeting** ("Join my next meeting with Nook" works with Siri). As a **Focus filter**
(System Settings → Focus → a Focus → Add Filter → Nook), it shows the Focus turning on and
off, and can keep Nook quiet except for urgent alerts: an agent that needs you, a timer,
low battery, a high-priority push. `scripts/bundle.sh` builds the Shortcuts metadata, which
needs full Xcode.

### GitHub, ntfy and Home Assistant

Settings → Connectors:

- **GitHub:** review requests, mentions, assignments and CI results from your
  notifications, using the GitHub CLI's login (`gh auth login`), once a minute.
- **ntfy:** subscribe to an [ntfy](https://ntfy.sh) topic and anything can alert the notch:
  `curl -d "Backup done" ntfy.sh/your-topic`. Priority 4–5 messages are urgent. Self-hosted
  servers and access tokens work too.
- **Home Assistant:** your server, a long-lived token and a list of entities
  (`light.office, binary_sensor.front_door`). They show as tiles on the Widgets page; a tap
  toggles lights, switches and fans (never locks), and doors, sensors and locks alert when
  they change.

Tokens are stored in your keychain.

### Script plugins

Any executable in `~/Library/Application Support/Nook/Plugins` runs on the interval
in its name (`disk.5m.sh`, `stocks.30s.py`, `build.1h.rb`; 1 minute if none) and prints
`key=value` lines:

```sh
#!/bin/sh
echo "title=Disk"
echo "value=96% used"
echo "symbol=internaldrive.fill"   # any SF Symbol
echo "tint=red"                    # green red orange yellow blue purple pink
echo "progress=0.96"
echo "url=https://example.com"     # opened when the widget is clicked
echo "alert=Your disk is almost full"   # a notch alert whenever this text changes
```

Widgets show on the Widgets page. Settings → Connectors → Add Example installs this
disk plugin.

### `nook://` links

```sh
open -g "nook://show?title=Build%20passed&symbol=checkmark.circle.fill&tint=green&value=12s&duration=4"
open -g "nook://progress?id=build&title=Building&progress=0.4&symbol=hammer.fill"
open -g "nook://progress?id=build&done=1"      # or nook://clear?id=build
open -g "nook://timer?minutes=25"
open -g "nook://open?tab=shelf"                # home shelf widgets clipboard stats timer mirror
open -g "nook://close"
open -g "nook://settings"
open -a Nook ~/Desktop/report.pdf              # put files on the shelf
```

Any web page can open a link, so every value is checked and capped, and links can't
put files on the shelf.

## How the private-API features work

- **System-wide now playing.** `Nook.app/Contents/XPCServices/NookHelper.xpc` has the
  bundle id `com.apple.controlcenter.NookHelper`, because since macOS 15.4 MediaRemote
  only answers Apple-looking clients. The helper `dlopen`s MediaRemote for now-playing
  info, commands, seeking and the player's PID. It pushes changes to the app over
  `NSXPCConnection` (`Sources/NookXPC`). `MediaRouter` falls back to AppleScript.
- **HUD.** `MediaKeyTap` is a `CGEventTap` on `NSSystemDefined` aux-control events. It
  swallows the volume / brightness keys and applies them itself: CoreAudio for volume,
  private `DisplayServices` for brightness. Option+Shift gives quarter steps.
- **Live waveform.** `SystemAudioTap` is a Core Audio process tap in a private aggregate
  device, FFT'd into four bands (macOS 14.2+). It starts off the main thread, because
  creating it waits on the permission prompt.
- **Lock screen.** On `com.apple.screenIsLocked`, `LockScreenSpace` moves the island
  and the lock panel into a SkyLight space at absolute level 400 (Notification Center's
  lock-screen level), and moves them back out on unlock.

SwiftPM can't build `.xpc` bundles, so `scripts/bundle.sh` assembles the helper and
signs inside-out. `scripts/verify-bundle.sh` checks the bundle, including the usage
strings macOS requires.

### Prebuilt app from CI

Every push builds a universal `Nook.app` (Actions → Build → artifact `Nook`). It is
ad-hoc signed and not notarized, so clear the quarantine once:
`xattr -dr com.apple.quarantine Nook.app`.

## Security

- `nook://` links can come from any web page, so every value is checked and capped,
  links can't put files on the shelf or open the camera, and the coding-agent hook links
  carry a per-install secret, so a page can't fake agent alerts.
- A background task starts only from a request file in `Application Support/Nook/Tasks`,
  which only your account can write; `nook://task` just names one, and each request runs
  once. Nothing can join a meeting from a link.
- Script plugins run only from `~/Library/Application Support/Nook/Plugins`, which is
  private to your user account, with a 10-second limit each.
- Network, each only when its feature is on: weather from Open-Meteo, Spotify album art,
  lyrics from LRCLIB (title and artist), GitHub through `gh`, your ntfy server and your
  Home Assistant server. Nothing else leaves your Mac.
- Found a vulnerability? Please report it privately via GitHub's **Report a
  vulnerability** (Security tab) rather than a public issue.

## Layout

- `AppDelegate.swift`: windows, cursor tracking, settings, wiring the services
- `IslandModel.swift`: all state; activity priority and island sizes
- `IslandView.swift`: shape, springs, compact activities, HUD
- `ExpandedView.swift`: the open island and its pages
- `MediaViews.swift`: now-playing player, progress, controls, lock-screen view
- `SettingsWindow.swift`, `Prefs.swift`: settings UI and keys
- `Connectors.swift`: coding agents (Claude Code, Codex, Cursor, Gemini), the `/nook` skill and
  script plugins; `URLCommands.swift`: `nook://`
- `AgentTasks.swift`: background tasks; `CLI.swift`: the `nook` command; `Intents.swift`: Shortcuts
  and the Focus filter; `Integrations.swift`: GitHub, ntfy, Home Assistant, lyrics, keychain
- `Monitors.swift`: Bluetooth, camera/mic, clipboard, downloads, fullscreen
- `SystemMonitors.swift`, `StatsMonitor.swift`, `CalendarWeather.swift`, `Mirror.swift`
- `SystemMedia.swift`, `MediaController.swift`: now playing (helper, AppleScript)
- `MediaKeyTap.swift`, `SystemAudioTap.swift`, `LockScreen.swift`: the private-API pieces
- `Sources/NookXPC/`, `Sources/NookHelper/`: the MediaRemote XPC service
- `Support/`: Info.plists and `AppIcon.icns` (drawn by `scripts/make-icon.swift`)

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[GPL-3.0](LICENSE). You can use, change and share Nook; versions you distribute must
stay open source under the same license.
