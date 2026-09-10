# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-09-09

First public release.

### Added

- Menu-bar app combining screenshots and screen recording on macOS 15+.
- Screenshot overlay with rectangle, window and full-screen modes, a delay timer
  and a photo/video switch; output as PNG or JPEG, copied to the clipboard, with
  a preview panel offering *Open* and *Show in Finder*.
- Screen recording to MP4 or QuickTime, H.264 or HEVC, 10 to 60 fps, built on
  ScreenCaptureKit with its own `AVAssetWriter`.
- Pause and resume, with the paused stretch removed from the timeline rather
  than written as a still frame.
- Desktop audio, microphone and pointer can be switched during a recording;
  muted audio is written as silence so the file stays in sync. The microphone has
  to be on when the recording starts for its switch to do anything.
- Optional echo cancellation for the microphone through the system voice
  processor.
- Floating recording HUD, draggable and excluded from the capture.
- Separate folders for screenshots and recordings, both openable from the
  menu-bar menu, plus an optional Save panel for every capture.
- Remappable global shortcuts (⌃⇧S and ⌃⇧R by default).
- Interface in English, Italian, Spanish, German, Portuguese, Russian, Ukrainian
  and Simplified Chinese, with a language picker in Preferences.
- A recording cut short from outside the app (the recorded window closes, a
  display is unplugged, the disk fills) is finalised and kept rather than
  discarded.
- Errors surface even with the main window closed, which is the normal state
  for a menu-bar app.
- Quitting waits for a recording to finish being written.
- A delayed screenshot counts down in the menu bar.
- Assigning one shortcut the other's combination is refused, and a shortcut that
  cannot be registered shows a warning instead of failing silently.
- Universal builds (Apple silicon and Intel), signed with the hardened runtime.
- Keyframes every two seconds of wall clock rather than every N frames, so
  scrubbing works on a recording of a mostly still screen.
- Screenshots are put on the clipboard as PNG as well as TIFF; the TIFF is
  produced only if something asks for it, since it is uncompressed.
- A shortcut must include ⌘, ⌃ or ⌥, or be a bare function key. macOS would
  otherwise let a plain key, or one with only ⇧, swallow that key in every
  application on the Mac.
- Recordings are written with a one-second movie fragment interval, so a file cut
  short by a crash, a force-quit or a power cut still opens and plays up to the
  last fragment instead of not opening at all.
- The recording timer runs on the same clock as the file, so sleeping the Mac
  mid-recording no longer makes the timer disagree with what was recorded.
- A delayed screenshot can be called off by pressing the shortcut again.
- A save folder that is not a writable directory falls back to the default, and a
  folder that cannot be opened says so instead of doing nothing.
- The three live switches are in the menu-bar menu as well as the HUD. The HUD is
  a floating panel that takes no keyboard focus, so during a recording, when the
  main window is hidden, the menu is the only surface VoiceOver and the keyboard
  can reach.
- Four more interface languages: Français, 日本語, 한국어 and 繁體中文, bringing the
  total to twelve. The macOS interface paths quoted in the permission and shortcut
  instructions use Apple's own terminology in each language.
- A **Quality** setting for recordings: High, Balanced (the default) and Small
  files, scaling the bitrate the encoder is given. Screen content compresses much
  better than an encoder's defaults assume, so Balanced is close to
  indistinguishable from High at roughly a third less. Nothing is re-encoded after
  the fact: the file is written at the chosen size.
- Preferences is resizable and opens no taller than the screen allows. It was a
  fixed 732 pt with no scroll, so on a small or heavily scaled display the
  Shortcuts section at the bottom was unreachable.

[Unreleased]: https://github.com/AlexDevFlow/Glimpse/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/AlexDevFlow/Glimpse/releases/tag/v0.1.0
