# AGENTS.md

Project: **`apple_internal` XKB model** — userspace Fn-key handling for Apple Silicon laptop
keyboards on Asahi Linux. Fork of `AsahiLinux/xkeyboard-config` (branch `asahi`).

Owner workspace: `github.com/IlyaasK/xkeyboard-config` (mirror of this repo).

## Status (read before touching anything)

- **Offline-verified**: all 12 Fn+F-key media mappings + 6 Fn+edit-key mappings compile and
  resolve correctly in libxkbcommon (verified via `xkbcomp` + a C test program + the upstream
  pytest suite: 2676 passed, 0 failed).
- **On-device testing pending**: Fedora Asahi + Hyprland on the user's M1 Pro. Use
  `./test-on-device.sh` (see below).
- No commit has been pushed upstream yet. Changes are on the `asahi` branch of this repo.

## What the change is

A new XKB model `apple_internal` (model name in rules/base.xml: "Apple Internal Keyboard")
that maps the Apple Silicon laptop keyboard's Fn key to media/edit keys entirely in userspace.
The kernel (`hid_apple` with `fnmode=5`, FKEYS_IGNORE) passes Fn as `KEY_FN` and F-keys as
plain F1–F12; XKB does all translation. This is exactly what the asahi `hid-apple.c` comment
calls for: "temporary Fn key mode **until xkeyboard-config has keyboard layouts with media key
mappings**" — this layout is that missing piece.

Files changed:
- `symbols/macintosh_vndr/apple` — new `partial modifier_keys function_keys xkb_symbols "internal"`
  section: FN → `ISO_Level3_Shift`; FK01–FK12 media keys at FOUR_LEVEL_X level 2; edit keys
  (BKSP/RTRN/UP/DOWN/LEFT/RGHT) with explicit FOUR_LEVEL symbols.
- `keycodes/aliases` — `alias <FN> = <I472>;` in **all three** sections (qwerty, azerty, qwertz).
- `rules/0004-evdev.m_k.part` — `apple_internal = evdev`
- `rules/0026-evdev.m_s.part` — `apple_internal = +inet(evdev)+macintosh_vndr/apple(internal)`
- `rules/base.xml` — model metadata entry
- `test-on-device.sh` — on-device test script (this file documents itself)

## Hard-won facts (do not "clean up" without re-verifying)

These cost hours of archaeology. If you change any of them, re-run the full verification below.

1. **FOUR_LEVEL_X maps Fn → level 2, not level 3.** `map[LevelThree] = Level2` in
   `types/extra`. Media-key symbols for F-keys must sit at **position 2**
   (`[ NoSymbol, XF86MonBrightnessDown, NoSymbol, NoSymbol ]`). Position 3 is Shift+Fn.
   (A CTRL+ALT base type coincidentally puts LevelThree at level 3 — do not rely on base types.)
2. **`NoSymbol` keeps the base symbol only if the base defines that level.** Base arrows/BKSP
   are ONE_LEVEL; overriding them requires explicit symbols on every level
   (`[ Up, Up, Page_Up, Page_Up ]`), not `NoSymbol` padding.
3. **`$evdevkbds` in `rules/0002-evdev.lists.part` is functional**, not metadata: it maps
   models to `+inet(%m)`. Do NOT add a model to it unless it has an `inet(<model>)` section.
   New models get their own line in `rules/0026-evdev.m_s.part`.
4. **The evdev rules file is merged from evdev parts only** (all `rules/*.part` except the
   `*-base.*` ones) — never run `merge.py` over all parts for one ruleset.
5. **Keycode 472 = KEY_FN (evdev 464 + 8).** X11 caps keycodes at 255, so this model is
   evdev/Wayland-only by design. libxkbcommon supports up to 709. `xkbcomp` will warn
   `Attempt to alias <FN> to non-existent key <I472>` when compiling X11 keymaps — expected.
6. **Keysyms `XF86Scale` and `XF86MicMute` do not exist** in xkbcomp 1.5.0's table. Use
   `XF86TaskPane` (F3, closest Mission Control analog, already used in symbols/inet) and
   `XF86AudioMicMute` (F5, matches inet's own KEY_MICMUTE mapping).
7. The `internal` section includes `level3(modifier_mapping)` — this exists in newer
   xkeyboard-config only; on old distros also overlay `symbols/level3` when installing.
8. **The FN alias must exist in all three sections of `keycodes/aliases`** (qwerty, azerty,
   qwertz). Rules select `+aliases(qwerty|azerty|qwertz)` by layout group (`$azerty` = be/fr,
   `$qwertz` = al/ch/cz/de/hr/hu/ro/si/sk), so a qwerty-only alias silently breaks every
   azerty/qwertz layout (`xkb_keymap_key_by_name("FN")` fails; media keys still work because
   the F-keys themselves are real key names).

## How to test

### On the Asahi box (Fedora + Hyprland)
```
./test-on-device.sh            # static checks: merge, compile, keysym assertions
./test-on-device.sh --install  # + set fnmode=5, install XKB files (backup made), live-switch Hyprland
./test-on-device.sh --e2e      # + synthesize Fn+F1/Fn+Up/Fn+BS via ydotool, assert keysyms via wev
./test-on-device.sh --restore  # restore /usr/share/X11/xkb from the backup
```
E2E caveats: `ydotool` needs the `ydotoold` daemon (root/uinput); `wev` and `ydotool`
must be installed (`dnf install wev ydotool`). `hyprctl` only works inside a Hyprland
session. Keys to verify by hand (can't be automated): F3 → Mission Control-style action,
mic mute, brightness actually changing, sleep key.

### Offline (any machine, e.g. this Mac)
The static checks of `test-on-device.sh` run anywhere — it stages the tree, merges rules,
compiles the keymap, and asserts keysyms (requires `xkbcli` or `setxkbmap`+`xkbcomp`, or
homebrew: `brew install xkbcomp libxkbcommon`).

Upstream pytest suite (fast, no network):
```
python3 -m venv /tmp/pyenv && /tmp/pyenv/bin/pip install pytest
python3 rules/merge.py <evdev parts only> > /tmp/xkbroot/rules/evdev   # see script for exact list
cp -R symbols keycodes types compat /tmp/xkbroot/ && cp rules/base.xml /tmp/xkbroot/rules/evdev.xml
XKB_CONFIG_ROOT=/tmp/xkbroot /tmp/pyenv/bin/pytest tests/ -q
```

## Iteration loop

1. Edit the `internal` section in `symbols/macintosh_vndr/apple` (or other files).
2. Re-run `./test-on-device.sh` (or the offline compile+assert).
3. On device: re-run with `--install`, then the hand-test list above.
4. Check the diff is minimal and follows xkeyboard-config style (tabs, 4-space symbol lists,
   comments referencing the kernel KEY_* constants).

## Next steps after on-device success

1. **Commit + push** a clean single commit on a fresh branch off `asahi` (squash the WIP;
   keep the working tree mirror at `github.com/IlyaasK/xkeyboard-config`).
2. **Open a PR against `AsahiLinux/xkeyboard-config`** (asahi branch). The keyboard yak is
   officially unclaimed there (help-wanted page says to contact janne via Asahi Linux Matrix
   — ping them before/with the PR, they own the Fn/macintosh keyboard work).
3. **Upstream later**: the same model should eventually go to freedesktop/xkeyboard-config
   master (KEY_FN + >255 keycodes are supported there); the only asahi-specific assumption is
   the exact kernel media-key table, which matches upstream hid-apple too.
4. **Kernel cleanup**: once the layout ships, the `fnmode=5` (FKEYS_IGNORE) hack in asahi
   hid-apple.c — documented as temporary-until-layouts-exist — can be revisited upstream
   (asahi kernel PR).
5. **Distro packaging**: Fedora Asahi ships distro xkeyboard-config, so no manual packaging
   once upstream lands.

## Environment notes

- Dev machine: macOS (brew: `xkbcomp` 1.5.0, `libxkbcommon` 1.13.2, `ninja`; no meson).
- Test machine: Fedora Asahi on Apple M1 Pro, Hyprland (Wayland), `hid_apple.fnmode`.
- Old brew bash is 3.2: scripts must not use `mapfile`/`declare -A`.
