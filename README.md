<div align="center">

<img src="docs/screenshots/icon.png" width="120" alt="Glimpse icon">

# Glimpse

Recording and capturing screens on macOS, the easy way.

[![CI](https://github.com/AlexDevFlow/Glimpse/actions/workflows/ci.yml/badge.svg)](https://github.com/AlexDevFlow/Glimpse/actions/workflows/ci.yml)

English · [Italiano](docs/README.it.md)

</div>

Glimpse puts screenshots and screen recording behind one menu-bar icon.

Screenshots use a bar at the top of the screen: rectangle, window or full screen,
a delay timer, and a switch between photo and video. Recording uses a small window
with a capture mode, three switches (desktop audio, microphone, pointer) and a
Record button.

Compared with ⌘⇧5 it adds live audio and pointer switches during a recording,
pause with the paused stretch cut out of the file, a choice of codec, container,
frame rate and compression level, separate folders for screenshots and recordings,
and twelve interface languages.

It is built on ScreenCaptureKit with its own `AVAssetWriter`. No dependencies, no
bundled binaries, no network access.

## Install

### Download

Take the latest `Glimpse-macos.zip` from the
[Releases](https://github.com/AlexDevFlow/Glimpse/releases) page, unzip it and move
Glimpse.app to your Applications folder.

> [!IMPORTANT]
> Releases are ad-hoc signed and not notarised, because this project has no paid
> Apple Developer account. macOS quarantines anything downloaded from the web, so
> the first launch is refused. Open it once, then allow it from System Settings →
> Privacy & Security → Open Anyway. That route keeps Gatekeeper's checks in place.
>
> To clear the flag directly instead:
>
> ```sh
> xattr -dr com.apple.quarantine /Applications/Glimpse.app
> ```
>
> That skips the notarisation check, so use it knowingly. Building from source
> avoids the question.

### Build from source

Only the Xcode Command Line Tools are needed.

```sh
make bundle        # build/Glimpse.app for this Mac
make run           # ...and open it
make install       # copy it to /Applications
make universal     # Apple silicon + Intel, the way releases are built
make check         # check the translations are consistent
make test          # unit tests, these need a full Xcode install
```

Everything except `make test` works with the Command Line Tools alone.
swift-testing cannot run without Xcode; the app itself never needs it.

## Screenshots

<div align="center">

<img src="docs/screenshots/main-window.png" width="250" alt="Main window">

*The recorder window: capture mode, live switches, Record.*

<img src="docs/screenshots/overlay-screenshot.png" width="620" alt="Screenshot overlay bar">

*Screenshot mode: rectangle, window or full screen, with a delay timer.*

<img src="docs/screenshots/overlay-recording.png" width="620" alt="Recording overlay bar">

*The same bar switched to video, with the three recording switches.*

<img src="docs/screenshots/recording-hud.png" width="360" alt="Recording HUD">

*While recording, a draggable HUD stays on top and is kept out of the video.*

<img src="docs/screenshots/preferences.png" width="480" alt="Preferences">

*Preferences: folders, interface language, audio, video, screenshots, shortcuts.*

</div>

## What it does

Screenshots: rectangle, window or full screen, with a delay timer. Saved as PNG or
JPEG, copied to the clipboard, and shown in a small preview with Open and Show in
Finder.

Recording: MP4 or QuickTime, H.264 or HEVC, eight frame rates from 10 to 60 fps.

Quality: High, Balanced or Small files. Screen content is mostly flat colour,
static regions and sharp text, so it compresses better than an encoder's defaults
assume. Balanced, the default, asks for half the bitrate of High; at 1080p on
screen content that measured about 1 dB of PSNR for roughly a third off the file.
Small files halves it again. At 4K/30 the ceiling goes 30, 15, 7 Mbit/s. Nothing is
re-encoded afterwards, so the file is written at the size you chose. At the same
quality, HEVC produces smaller files than H.264.

Pause and resume: the paused stretch is cut out of the file rather than frozen into
it, so the timer and the finished video agree.

Live switches: desktop audio, microphone and pointer can be toggled during the
recording. Muted audio is written as silence, so the file stays in sync. The
microphone is the exception. It has to be on when the recording starts, and the
live switch then mutes and unmutes it; started with it off, the switch stays dimmed
for that recording.

Echo cancellation: the microphone can go through the macOS voice processor, so
speaker output is not recorded twice. It applies only when the microphone is on
when the recording starts.

Where files go: separate folders for screenshots and recordings, both reachable
from the menu, or a Save panel for every capture.

Shortcuts: ⌃⇧S and ⌃⇧R by default, both remappable.

Requires macOS 15 or later. Apple silicon and Intel.

## First run

macOS puts more in the way of an unsigned app than of one from the App Store. In
order, once each:

1. Unzip, move Glimpse.app to Applications, open it. macOS refuses.
2. System Settings → Privacy & Security, scroll to the bottom, Open Anyway,
   authenticate, confirm. That button only appears for about an hour after the
   refused launch.
3. Glimpse opens as a menu-bar icon with a small window. Press Record.
4. macOS asks for Screen Recording permission. Allow it under Privacy & Security →
   Screen & System Audio Recording, then let Glimpse relaunch itself when it
   offers.
5. Press Record again. In the default Normal mode macOS shows its own picker so you
   can choose a display or a window. That sheet is part of the system, not Glimpse.
   Pick one and recording starts.

Switch the left tile to Selection to drag out an area instead of using the system
picker.

There is no auto-update. Watch the Releases page, or rebuild from source.

## Permissions

On first launch macOS asks for Screen Recording (System Settings → Privacy &
Security → Screen & System Audio Recording). The microphone is requested the first
time you start a recording with it switched on. macOS applies a newly granted
permission only after the app is reopened, and the app offers to relaunch itself.

With an ad-hoc signature, which is the default, macOS treats the app as new after
every rebuild and asks again. If you build often, create a local certificate once:

```sh
sh scripts/make-signing-cert.sh
make bundle SIGN_IDENTITY="Glimpse Dev"
```

If a later build fails with `errSecInternalComponent`, the key's partition list is
missing. Run the script again; it re-authorises an identity that already exists.

## Usage

| Action | Default shortcut |
|---|---|
| Screenshot (overlay) | ⌃⇧S |
| Start / stop recording | ⌃⇧R |
| Cancel the overlay | Esc |
| Confirm the selection | Return |

Shortcuts are remappable in Preferences. A shortcut needs ⌘, ⌃ or ⌥. A bare key, or
one with only ⇧, is refused, because macOS would let it swallow that key in every
application on the Mac; a function key on its own is allowed. To take over
⌘⇧3 / ⌘⇧4 / ⌘⇧5, first turn the system ones off in System Settings → Keyboard →
Keyboard Shortcuts → Screenshots.

In the screenshot overlay, drag out an area and press Return or hit Capture; or
hover a window and click; or click the screen you want. The video icon in the bar
reuses the same selection to start a recording and reveals the desktop audio,
microphone and pointer switches.

The timer in that bar applies to that capture. Leave it untouched and a recording
started from the overlay falls back to the Delay in Preferences instead. The two
never stack.

While recording, the main window disappears and a floating HUD takes over:
draggable, excluded from the video, with the timer, the three live switches, Pause
and Stop. The same switches are in the menu-bar menu, along with Pause and Resume
and the two folder items.

Pausing keeps the stream up but writes nothing, and the finished file skips the
pause. A recording paused for a minute is a minute shorter, not a minute of still
frame.

Ask where to save, in Preferences, puts a Save panel in front of every capture. A
screenshot asks before it is written, so cancelling discards it unless Copy to
clipboard is also on. A recording has to be written somewhere while it records, so
it goes to the recordings folder and the panel asks where to move it afterwards;
cancelling there leaves it where it is.

If a recording is cut short by something outside the app, such as the recorded
window closing, a display being unplugged or the disk filling, Glimpse finalises
what it has and gives you the partial file.

## Languages

English, Italiano, Español, Deutsch, Français, Português, Русский, Українська, 日本語, 한국어, 简体中文 and 繁體中文.
The interface follows the macOS language order by default; Preferences → Language
pins it to one language regardless of the system setting.

Adding one is mostly copying `en.lproj` and translating the values. `make check`
then verifies that no key or placeholder was lost. The steps are in
[CONTRIBUTING.md](CONTRIBUTING.md).

## Contributing

Bug reports, translations and patches are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md). Released versions are listed in
[CHANGELOG.md](CHANGELOG.md). Anything involving screen or microphone data should
go through [SECURITY.md](SECURITY.md) rather than a public issue.

## Project layout

```
Sources/Glimpse/
  App/         SwiftUI entry point, menu bar, hotkeys, app delegate
  Model/       persisted settings, video profiles, language list
  Recording/   SCStream + AVAssetWriter, system picker, state machine, HUD
  Capture/     full-screen overlay (rectangle / window / display) and its bar
  Screenshot/  screenshot flow, saving, preview panel
  UI/          main window, preferences, shortcut recorder
  Util/        Carbon hotkeys, KeyCombo, coordinates, permissions, logging, L()
Tests/         unit tests for the pure logic
Resources/     Info.plist, generated icon, one .lproj per language
scripts/       icon generator, local signing certificate, translation check
docs/          README translations and screenshots
```

## Known limitations

Worth knowing before you rely on the app.

Desktop audio and the microphone are written as two separate tracks. macOS plays
both, so a recording sounds right locally, but most software that reads the file
picks one audio track and keeps the desktop one, so narration disappears. This is
not only about re-encoding: `ffmpeg -c copy`, a plain remux with no encoding at
all, drops it, and so does `AVAssetExportSession` on every transcoding preset,
which is the engine behind QuickTime Player's Export As and a good deal of Mac
editing and upload software. Only its Passthrough preset keeps both. Until there is
a mixed-track option, export through something that preserves every audio track, or
record narration separately.

Above roughly 4096 pixels wide, H.264 output lands at Level 6.0, which postdates
most hardware decoders. A 5K display, or a 4K panel in a scaled HiDPI mode, can
produce a file some browsers, phones and editors refuse.

Screenshots and recordings do not share a colour space. A screenshot keeps the
display's own profile, Display P3 on most current Macs; a recording is tagged
Rec. 709, because forcing the video to match darkens it. Saturated colour can look
slightly different in a still and in a video of the same screen.

A slow microphone can be left out of the recording. The writer is built from the
formats seen in the first 1.5 seconds, and a Bluetooth headset switching profile
can take longer, leaving the recording with no microphone track. Only the log says
so. Start the recording once the headset is already active.

Microphone latency is not compensated. A Bluetooth headset can trail the picture by
100 to 200 ms.

Resizing the recorded window mid-recording letterboxes the rest of the take. The
output dimensions are fixed when recording starts.

A pause can shift audio against video by up to one audio packet, about 21 ms, so
many pauses in one recording accumulate a small drift.

## Credits

The recording window is modelled on [Kooha](https://github.com/seadve/kooha) by
Dave Patrick Caberto (GPL-3.0), a GNOME screen recorder. This is an independent
macOS implementation: no Kooha code or artwork is used, and the app icon and the
capture overlay are original. The settings keys deliberately mirror Kooha's schema.
The in-app glyphs are Apple's SF Symbols.

Differences worth knowing: no WebM or GIF, since on macOS the native containers are
MP4/MOV with H.264/HEVC; monitor and window selection goes through the macOS system
picker, the way Kooha uses the xdg portal on Linux; and screenshots are a
first-class half of the app rather than a separate tool.

## License

[MIT](LICENSE) © 2026 AlexDevFlow
