# clut-hammerspoon

Switch between your most recently used Chrome tabs from the keyboard, like the
[CLUT](https://chromewebstore.google.com/detail/clut-cycle-last-used-tabs/cobieddmkhhnbeldhncnfcgcaccmehgn)
extension, but **without any extension**: handy on a Chrome profile managed by
an organization that blocks extensions. Runs on macOS with
[Hammerspoon](https://www.hammerspoon.org).

Bonus over CLUT: the history is **shared across all Chrome windows and
profiles**.

| Shortcut | Action |
|---|---|
| `⌥W` | Toggle between the last 2 tabs |
| `⌥S` | Go back through history: hold `⌥`, press `S` repeatedly, release `⌥` to confirm |
| `⌥⇧S` | Same, in the other direction |

Shortcuts are only active while Chrome is the frontmost app.

## Installation

```bash
brew install --cask hammerspoon
git clone https://github.com/Yop-La/clut-hammerspoon.git ~/clut-hammerspoon
mkdir -p ~/.hammerspoon
ln -s ~/clut-hammerspoon/clut.lua ~/.hammerspoon/clut.lua
cat >> ~/.hammerspoon/init.lua <<'EOF'
hs.autoLaunch(true)       -- start at login
clut = require("clut")
clut.start()
EOF
open -a Hammerspoon
```

Then, once:

1. On first launch, click **Open** on the macOS warning.
2. **System Settings → Privacy & Security → Accessibility**: enable
   Hammerspoon, then **quit and relaunch Hammerspoon** (it only picks up the
   permission after a restart).
3. On the first `⌥W`, allow Hammerspoon to **control Google Chrome**.

Update: `git -C ~/clut-hammerspoon pull`, then *Reload Config* from the
Hammerspoon menu.

## Configuration

Constants at the top of `clut.lua`: history size (`MAX_HISTORY`), overlay while
cycling with `⌥S` (`SHOW_HUD`). Shortcuts are defined in `M.start()`.

## How it works

Hammerspoon tracks the active tab (window title changes + light polling while
Chrome is frontmost), keeps a most-recently-used list, and activates the target
tab through AppleScript, which sees every Chrome window regardless of profile.

## Troubleshooting

- `hs -c "return clut.dump()"` prints the history with tab titles
  (CLI: `/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs`).
- Keyboard focus stays on the wrong window → Accessibility permission missing,
  or Hammerspoon not relaunched after granting it.

## Limitations

- Google Chrome only (single Chrome process; separate instances started with
  `--user-data-dir` are not seen).
- History builds up as you browse and resets when Chrome restarts.

## License

MIT
