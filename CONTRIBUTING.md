# Contributing

Thanks for taking a look. This is a small, dependency-free macOS app: you need
the Xcode Command Line Tools and nothing else.

```sh
make bundle    # build build/Glimpse.app
make run       # ...and open it
make check     # translations are consistent (Command Line Tools are enough)
make test      # unit tests (swift-testing, needs a full Xcode install)
```

## Adding or fixing a translation

This is the easiest way to help. The only Swift involved is one line, a case in
`AppLanguage` (step 4), and `make check` refuses the change if you forget it.

1. Copy `Resources/Localization/en.lproj` to
   `Resources/Localization/<code>.lproj`, where `<code>` is a language code such as
   `fr`, `ja`, `pl`, or a script-qualified one such as `zh-Hant`.
2. Translate the **values** only. Leave the keys alone, and keep every `%@` and
   `%d` placeholder: they are filled in at runtime with a shortcut, a number of
   seconds, or an image size. Positional forms like `%1$d × %2$d` must keep their
   numbers, though you may reorder them if your language reads better that way.
3. Translate `InfoPlist.strings` too. That one line is what macOS shows in the
   microphone permission dialog.
4. Add `<code>` to `CFBundleLocalizations` in `Resources/Info.plist`, and a case
   to `AppLanguage` in `Sources/Glimpse/Model/AppLanguage.swift` so the
   language appears in the Preferences picker. Name it in its own language
   ("Français", not "French").
5. Run `make check`. It fails if a key is missing, unknown, or if a placeholder
   was lost in translation.

Screenshots in the README are in English; there is no need to redo them.

## Code

Before your second build, create the local signing certificate:

```sh
sh scripts/make-signing-cert.sh
```

With the default ad-hoc signature macOS treats the app as new after every rebuild
and asks for Screen Recording permission again, which makes an edit-build-test
loop miserable. This is the one-time fix.

- Open an issue before a large change, so nobody writes the same thing twice.
  Small fixes can go straight to a pull request.
- Match the surrounding style: no external dependencies, comments that explain
  *why* rather than restate the code.
- Icon-only controls need an `.accessibilityLabel`. The tooltip from `.help()`
  is not read by VoiceOver.
- User-visible text goes through `L("key")` with the English string added to
  `en.lproj/Localizable.strings`; `make check` will tell you which translations
  are now missing it.
- `make check` and `make test` both run in CI on every pull request.

## Reporting a bug

Include your macOS version, whether you installed a release or built from
source, and the tail of `~/Library/Logs/Glimpse.log` if a recording
failed: it records the writer and audio format setup.
