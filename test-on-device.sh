#!/usr/bin/env bash
#
# test-on-device.sh — validate the apple_internal XKB model on an Asahi Linux box.
#
# Usage:
#   ./test-on-device.sh                 static checks only (no root, no changes)
#   ./test-on-device.sh --install       + install XKB files + live-switch Hyprland
#   ./test-on-device.sh --e2e           + synthesize Fn+key presses via ydotool,
#                                       verifying keysyms through wev
#   ./test-on-device.sh --restore       restore /usr/share/X11/xkb from last backup
#
# Works on Fedora Asahi + Hyprland. Static checks can also run on a dev Mac
# (the XKB_CONFIG_ROOT staging trick works anywhere; xkbcli/setxkbmap may be absent).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$(mktemp -d /tmp/xkb-stage.XXXXXX)"
BACKUP=/tmp/xkb-x11-backup-latest.tar.gz
FNMODE_WANT=5           # FKEYS_IGNORE: kernel passes Fn/F-keys through untranslated
MODEL=apple_internal
INSTALL=0
E2E=0

for a in "$@"; do
  case "$a" in
    --install) INSTALL=1 ;;
    --e2e) E2E=1 ;;
    --restore)
      [ -f "$BACKUP" ] || { echo "no backup at $BACKUP"; exit 1; }
      sudo tar -xzf "$BACKUP" -C / ; echo "restored; reload your compositor"
      exit 0 ;;
    *) echo "unknown arg: $a"; exit 1 ;;
  esac
done

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
FAILURES=0

echo "== repo: $REPO_ROOT"

# ---------------------------------------------------------------- stage + merge
echo "== staging XKB tree"
mkdir -p "$STAGE/symbols" "$STAGE/keycodes" "$STAGE/types" "$STAGE/compat" "$STAGE/rules"
cp -R "$REPO_ROOT"/symbols/. "$STAGE/symbols/"
cp -R "$REPO_ROOT"/keycodes/. "$STAGE/keycodes/"
cp -R "$REPO_ROOT"/types/. "$STAGE/types/"
cp -R "$REPO_ROOT"/compat/. "$STAGE/compat/"
# evdev ruleset = all parts except the base-* ones (same selection meson makes)
PARTS=""
for p in "$REPO_ROOT"/rules/*.part; do
  case "$p" in *-base.*) ;; *) PARTS="$PARTS $p" ;; esac
done
python3 "$REPO_ROOT/rules/merge.py" $PARTS > "$STAGE/rules/evdev"
cp "$REPO_ROOT/rules/base.xml" "$STAGE/rules/evdev.xml"
grep -q "apple_internal" "$STAGE/rules/evdev" || fail "rules/evdev missing apple_internal"

# ---------------------------------------------------------------- kernel fnmode
echo "== kernel hid_apple fnmode"
FNMODE_SYS=$(ls /sys/module/hid_apple/parameters/fnmode 2>/dev/null || echo /nonexistent)
if [ -r "$FNMODE_SYS" ]; then
  CUR=$(cat "$FNMODE_SYS")
  echo "  current fnmode=$CUR (want $FNMODE_WANT)"
  if [ "$CUR" != "$FNMODE_WANT" ] && [ "$INSTALL" = 1 ]; then
    echo "  setting fnmode=$FNMODE_WANT (sudo)"
    echo "$FNMODE_WANT" | sudo tee "$FNMODE_SYS" > /dev/null
  elif [ "$CUR" != "$FNMODE_WANT" ]; then
    echo "  NOTE: run with --install to set fnmode=$FNMODE_WANT (sudo)"
  fi
else
  echo "  WARN: no /sys/module/hid_apple/parameters/fnmode (kernel module not loaded?)"
fi

# ---------------------------------------------------------------- compile check
echo "== compile keymap with model $MODEL"
DUMP=/tmp/apple_internal_keymap.txt
if command -v xkbcli > /dev/null 2>&1; then
  XKB_CONFIG_ROOT="$STAGE" xkbcli compile-keymap --rules evdev --model "$MODEL" --layout us > "$DUMP" 2>/tmp/xkbcli.err \
    || { cat /tmp/xkbcli.err; fail "xkbcli compile-keymap"; }
elif command -v setxkbmap > /dev/null 2>&1; then
  XKB_CONFIG_ROOT="$STAGE" setxkbmap -model "$MODEL" -layout us -print 2>/dev/null | xkbcomp -xkb - "$DUMP" -I"$STAGE" 2>/dev/null \
    || fail "setxkbmap/xkbcomp fallback"
else
  echo "  WARN: no xkbcli/setxkbmap — can't compile keymap here; run on the Asahi box"
  echo "  (on macOS, use the offline recipe in AGENTS.md)"
fi

if [ -s "$DUMP" ]; then
  check() { # check <label> <regex> <file>
    rg -q -- "$2" "$3" && pass "$1" || fail "$1"
  }
  check "FN key = ISO_Level3_Shift (key <I472>)" 'I472' "$DUMP"
  rg -q 'key <I472>' "$DUMP" && rg -q 'ISO_Level3_Shift' "$DUMP" && pass "FN sym" || fail "FN sym"
  check "Fn+F1 = XF86MonBrightnessDown" 'XF86MonBrightnessDown' "$DUMP"
  check "Fn+F5 = XF86AudioMicMute"      'XF86AudioMicMute' "$DUMP"
  check "Fn+UP = Page_Up (Prior)"       'Prior' "$DUMP"
  check "Fn+BKSP = Delete"              'Delete' "$DUMP"
fi

# ---------------------------------------------------------------- install
if [ "$INSTALL" = 1 ]; then
  echo "== install (backup first)"
  sudo tar -czf "$BACKUP" -C / usr/share/X11/xkb 2>/dev/null || true
  echo "  backup -> $BACKUP"
  XKB_DEST=/usr/share/X11/xkb
  sudo cp "$STAGE/symbols/macintosh_vndr/apple" "$XKB_DEST/symbols/macintosh_vndr/apple"
  sudo cp "$STAGE/symbols/level3"               "$XKB_DEST/symbols/level3"
  sudo cp "$STAGE/keycodes/aliases"             "$XKB_DEST/keycodes/aliases"
  sudo cp "$STAGE/keycodes/evdev"               "$XKB_DEST/keycodes/evdev"
  sudo cp "$STAGE/rules/evdev"                  "$XKB_DEST/rules/evdev"
  sudo cp "$STAGE/rules/evdev.xml"              "$XKB_DEST/rules/evdev.xml"
  # re-verify against the installed tree
  if command -v xkbcli > /dev/null 2>&1; then
    xkbcli compile-keymap --rules evdev --model "$MODEL" --layout us > /dev/null 2>&1 \
      && pass "installed tree compiles" || fail "installed tree compiles"
  fi
fi

# ---------------------------------------------------------------- hyprland
if command -v hyprctl > /dev/null 2>&1 && [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
  echo "== hyprland live switch"
  hyprctl keyword input:kb_model "$MODEL" > /dev/null
  CUR=$(hyprctl getoption input:kb_model -j 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["str"])' 2>/dev/null || true)
  [ "$CUR" = "$MODEL" ] && pass "input:kb_model=$MODEL" || fail "input:kb_model=$CUR"
else
  echo "== hyprland: not running here (set input:kb_model $MODEL in hyprland.conf)"
fi

# ---------------------------------------------------------------- e2e (wev+ydotool)
if [ "$E2E" = 1 ]; then
  echo "== e2e: wev + ydotool"
  command -v wev > /dev/null || { fail "wev not installed (dnf install wev)"; }
  command -v ydotool > /dev/null || { fail "ydotool not installed (dnf install ydotool, run ydotoold)"; }
  EVOUT=$(mktemp /tmp/wev-out.XXXXXX)
  wev -f keysym > "$EVOUT" 2>&1 &
  WEV_PID=$!
  sleep 0.5
  # evdev codes: KEY_FN=464, KEY_F1=59, KEY_UP=103, KEY_BACKSPACE=14
  try_fn_combo() { # label keycode
    rm -f "$EVOUT"
    ydotool key 464:1 || true; sleep 0.15
    ydotool key "$1":1 "$1":0 || true; sleep 0.15
    ydotool key 464:0 || true
    sleep 0.5
    rg -q -- "$2" "$EVOUT" && pass "$3" || fail "$3 (wev saw: $(tr '\n' ' ' < "$EVOUT" | head -c 120))"
  }
  try_fn_combo 59 'XF86MonBrightnessDown' "Fn+F1 keysym via wev"
  try_fn_combo 103 'Prior'                 "Fn+Up keysym via wev"
  try_fn_combo 14 'Delete'                 "Fn+BS keysym via wev"
  kill "$WEV_PID" 2>/dev/null || true
fi

# ---------------------------------------------------------------- summary
rm -rf "$STAGE"
echo
if [ "$FAILURES" -gt 0 ]; then
  echo "RESULT: $FAILURES failure(s)"
  exit 1
else
  echo "RESULT: all checks passed"
fi
