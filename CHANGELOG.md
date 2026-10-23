# Changelog

Nook follows [semantic versioning](https://semver.org). Until 1.0, a minor version
can include breaking changes.

## 0.6.0 — 2026-10-23

Accurate agent status
- Done means done. Claude Code ends a reply even while background tasks run, prompts are
  scheduled, or it has asked you something; Nook now reads that from the Stop hook and shows
  "2 running", Scheduled or Question instead, and the session stays active beside the notch.
- API errors (Claude's StopFailure hook) show as failures, with the error.
- The session that hands a task to Nook no longer says Done as it hands off.
- A background task that hits its turn or budget limit counts as failed, not done.

Background tasks
- A `/nook` skill for Claude Code and Codex (Settings → Coding Agents → Install). Type
  `/nook <task>`, close the terminal, and Nook runs the agent itself: its logo stays in the
  notch while it works, then Done or Failed with a sound. Claude's run forks your session,
  so it keeps the conversation. Tasks survive Nook quitting.
- The Agents page lists recent tasks with their summary, Stop, and Continue in Terminal.
- Choose what tasks may do: Claude's auto mode (default), edit files, or anything.

Connectors
- A `nook` command (show, progress, done, clear, timer, open, close, run), installable from
  Settings.
- Shortcuts actions: Show Alert, Show / Finish Progress, Start Timer, Open Nook, Run Agent
  Task in Background, Join Next Meeting. A Focus filter shows the Focus and can keep Nook
  quiet except for urgent alerts.
- Cursor and Gemini CLI alerts.
- GitHub notifications (review requests, mentions, CI results) through the `gh` CLI.
- ntfy push alerts from anywhere, with self-hosted servers and tokens.
- Home Assistant tiles on the Widgets page; tap to toggle lights, switches and fans.
- Join buttons on calendar events with a Zoom, Meet, Teams, Webex or FaceTime link.
- Today's reminders on Home, tick to complete, with alerts when they're due.
- Synced lyrics under the artist, from LRCLIB.

Project
- Unit tests (`swift test`), run in CI.

## 0.5.0 — 2026-10-19

Motion
- Smoother, more Apple-like animation. Content keeps its own size while the island morphs
  and the island's shape clips it, so nothing gets squashed into the small island on the
  way out (this was the cut-off artwork and controls). Content grows out of the notch and
  sinks back into it, and the island's closing bounce is gentler.
- Fixes the flash when the cursor leaves the island: fades no longer use the bouncy spring.
- Less work per frame: the shadow is on the shape only, the panels don't re-fit their
  windows to SwiftUI, and the cursor is checked at 60 Hz. `--slow-animations` plays the
  motion 5× slower for tuning.
- The open island widens to fit its page switcher and the chips beside the notch, so they
  never run under the notch. Smaller artwork in a 24 pt menu bar.

Coding agents (new Settings page)
- Claude Code and Codex side by side beside the notch, each with its logo and its busiest
  limit as percent used, percent left or a battery, only while that agent is working
  (until 5 minutes after it last did anything; a Claude session that ends goes at once,
  or choose "whenever its limits are known"). A new Agents page shows every limit
  with its reset time, plus (each optional) model and effort, plan, context, cost and lines.
- Codex usage is read from Codex's own session logs, so there's nothing to install. Codex
  alerts come from hooks in ~/.codex/hooks.json.
- Finer-grained alerts, each with its own switch: needs permission, has a question,
  finished, waiting for you, subagent finished, compacting, session started / ended,
  nearing a limit. Alerts show the agent's logo.

Displays
- Show the island on every display (one island per display, sharing what they show).
- Simulated notch: keep the idle island visible on displays without a notch.
- Hide while playing a game.
- Output device picker in now playing; the volume HUD shows AirPods, headphones, a display
  or AirPlay when that's where the sound goes.
- Lock screen: the island always shows at the top, even when "Hide when an app is
  fullscreen" is on and a fullscreen app is behind the lock screen (it used to vanish,
  leaving only the card). The card now sits just under the clock, clear of the password
  field, with a darker tint so it reads on any wallpaper; its position is adjustable.
  Hide it while paused; keep the display on while music plays.
- The waveform moves more like music without the live capture (no purple dot), varying
  per track.

- Fixes the lock card staying on the desktop for minutes after unlocking. The unlock sound
  was played on the main thread, and right after unlock macOS can hold that call for
  minutes while the audio output wakes up, freezing the whole app. Sounds now play in the
  background, and the card leaves the lock-screen space before it's hidden.

Removed
- "Pick Colour…" from the menu bar menu.

## 0.4.0 — 2026-10-19

Design
- The island follows Apple's design more closely: continuous corners, tuned
  springs, content that scales and un-blurs in, and a small lift on hover instead of a
  scale. Alerts are a symbol plus a value, like the iPhone's.
- Now playing uses Apple's layout: 56 pt artwork, seekable bar between the times, and
  five controls with shuffle and repeat. The album tint uses the artwork's dominant colour.
- The open island is quiet: no status clutter, and a page switcher only when there's
  more than one page.
- Lock screen: a Liquid Glass card (328 × 174) under the clock, inline
  weather / battery / timer above it, and a lock in the island that opens on unlock.
- Settings window in the style of System Settings (menu bar → Settings…).

Features
- Activities: low battery and Low Power Mode, AirPods / Bluetooth with battery, camera
  and mic in use, downloads, timer, calendar alerts.
- Pages: Shelf (drop files, AirDrop), Widgets, Clipboard history, System stats, Timer,
  Mirror. Calendar and weather on Home.
- Connectors: Claude Code (agent needs you, finished, usage limits), script plugins, and
  `nook://` links (show, progress, timer, open, close, settings).
- Display: choose the display, tune notch size, outlines, hide in fullscreen, hide from
  screen recordings. Seek ±10 s by swipe, hover delay, haptics toggle.

Fixes
- Accessibility is asked for once, not on every launch. Settings → HUD shows the status
  and can reset a stale permission left by an older build.
- `install.sh` waits for the old Nook to quit before opening the new one.

## 0.3.0 — 2026-10-19

- Lock screen: the island and a Liquid Glass now-playing card (artwork, progress,
  controls, swipe to skip) show over the lock screen through a private SkyLight space.
- App icon (`Support/AppIcon.icns`, drawn by `scripts/make-icon.swift`).
- Live waveform is now opt-in (menu → Live Waveform), because capturing system audio
  makes macOS show the purple recording dot.
- `scripts/install.sh` installs to /Applications. The version comes from `VERSION`,
  is shown in the menu, and builds are signed with a stable certificate, so permissions
  survive rebuilds.
- Fix: the island froze while the Audio Capture prompt was open.

## 0.2.0 — 2026-10-19

- System-wide now playing through a MediaRemote XPC helper, with AppleScript as the
  fallback.
- Volume and brightness HUDs that replace the system OSD (needs Accessibility).
- Live waveform from a system audio tap.

## 0.1.0 — 2026-10-18

- First version: the island over the notch, now playing for Music and Spotify, swipe
  gestures, volume HUD, charging activity, Launch at Login.
