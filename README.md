# MagicWand

Select text anywhere in Windows (PDFs, Word, Wikipedia, docs...) and a small wand appears next to it.
Click it and Google's answer (with its AI Overview) opens in a small popup next to the cursor.

Free, no account, no API key, no admin rights. Uses Edge (or Chrome) already on the PC.

| Action | Result |
|---|---|
| Drag-select or double-click a word, then **click the wand** | Google search in a popup |
| **Right-click the wand** | Google AI Mode in a popup |
| Copy text, then **click the tray icon** | Look up the clipboard (for apps where no wand shows) |
| Tray icon right-click | Pause / Quit |

Close the popup with `Ctrl+W` (or `Esc` then `Ctrl+W`).

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
- Settings are at the top of `MagicWand.ps1` (popup size, wand timeout, optional "Ctrl+C twice"
  shortcut, off by default because DeepL uses it).
- Errors are logged to `%LOCALAPPDATA%\MagicWand\log.txt`.
