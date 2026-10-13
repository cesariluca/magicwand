# MagicWand

Select text anywhere in Windows (PDFs, Word, Wikipedia, docs...) and a small wand appears next to it.
Click it and a compact card opens right under your cursor with Google's AI Overview (phone layout,
your Windows language, light/dark theme). Switch to Google AI Mode in the card's footer.

Free, no account, no API key, no admin rights. The card uses Microsoft WebView2 (built into Windows 11;
the SDK DLLs are in `lib\`, redistributable under `lib\WebView2-LICENSE.txt`).

| Action | Result |
|---|---|
| Drag-select or double-click a word, then **click the orb** | Answer card under the cursor |
| **Right-click the orb** | Card opens in Google AI Mode |
| Copy text, then **click the tray icon** | Look up the clipboard (for apps where no wand shows) |
| Tray icon right-click | Pause / Quit |

The card closes with `Esc` or a click outside it; the pin keeps it open, drag it by its header,
resize it from its edges. Links that open new windows go to your default browser.

## Install

Double-click `Install.cmd`. It copies the app to `%LOCALAPPDATA%\Programs\MagicWand`, starts it, and
starts it with Windows. Uninstall: `Install.cmd /uninstall`. To try it without installing:
`Start MagicWand.cmd`.

## How it works / limits

- The wand shows when you drag or double-click while the mouse cursor is the text I-beam (or in
  apps listed in `$AnyDragApps`, e.g. Acrobat and Office, which use their own cursors).
- Clicking the wand sends `Ctrl+C` to the app (`Ctrl+Insert` in terminals), reads the text and puts
  your previous clipboard back. Windows clipboard history (Win+V) will still record the selection.
- It can't read selections in apps running as administrator (Windows blocks input to them).
- Settings are at the top of `MagicWand.ps1` (wand timeout, optional "Ctrl+C twice"
  shortcut, off by default because DeepL uses it).
- Errors are logged to `%LOCALAPPDATA%\MagicWand\log.txt`.
