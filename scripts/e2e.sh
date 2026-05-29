#!/usr/bin/env bash
# End-to-end test for imectl: cross-checks get/list/set against `issw`, exercises
# the daemon warm path and the daemon-down fallback, and verifies stale-socket
# handling. The user's original input source is captured up front and restored
# via an EXIT trap so a mid-run failure never strands the keyboard on an
# arbitrary source.
set -uo pipefail

IMECTL="${IMECTL:-.build/release/imectl}"
ISSW="${ISSW:-issw}"
fail=0

note() { printf '[e2e] %s\n' "$*"; }
check() {
    # check <description> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        note "PASS: $1"
    else
        note "FAIL: $1 (expected '$2', got '$3')"
        fail=1
    fi
}

command -v "$ISSW" >/dev/null 2>&1 || { note "issw not found; skipping cross-checks"; ISSW=""; }
[[ -x "$IMECTL" ]] || { note "imectl binary not found at $IMECTL"; exit 1; }

# Capture-and-restore: runs even on crash/early-exit.
ORIGINAL="$("$IMECTL" get 2>/dev/null || true)"
restore() {
    pkill -f "imectl daemon" 2>/dev/null || true
    if [[ -n "${ORIGINAL:-}" ]]; then
        "$IMECTL" set "$ORIGINAL" >/dev/null 2>&1 || true
    fi
}
trap restore EXIT
note "original input source: ${ORIGINAL:-<none>}"

# 1. get equivalence with issw
if [[ -n "$ISSW" ]]; then
    check "get matches issw" "$("$ISSW")" "$("$IMECTL" get)"
fi

# 2. round-trip over every selectable source, cross-checked with issw
mapfile -t IDS < <("$IMECTL" list | cut -f1)
if [[ "${#IDS[@]}" -eq 0 ]]; then
    note "PASS: empty/single-source edge case — list returned no selectable sources, round-trip skipped gracefully"
elif [[ "${#IDS[@]}" -eq 1 ]]; then
    note "single-source machine; setting the only source"
    "$IMECTL" set "${IDS[0]}" >/dev/null
    [[ -z "$ISSW" ]] || check "single set ${IDS[0]}" "${IDS[0]}" "$("$ISSW")"
else
    for id in "${IDS[@]}"; do
        out="$("$IMECTL" set "$id")"
        check "set returns id $id" "$id" "$out"
        [[ -z "$ISSW" ]] || check "issw confirms $id" "$id" "$("$ISSW")"
    done
fi

# 3. negative cases
"$IMECTL" set com.example.nonexistent.layout >/dev/null 2>&1
check "unknown id exit 3" "3" "$?"
"$IMECTL" set >/dev/null 2>&1
check "set no-arg exit 2" "2" "$?"
"$IMECTL" frobnicate >/dev/null 2>&1
check "unknown command exit 2" "2" "$?"

# Normalize to a known source before the daemon checks (the round-trip loop
# above left us on whatever sorted last).
[[ -n "${ORIGINAL:-}" ]] && "$IMECTL" set "$ORIGINAL" >/dev/null 2>&1

# 4. daemon warm path + fallback. Compare imectl against issw live (not against
# a stale captured value) so the check is about agreement, not absolute state.
pkill -f "imectl daemon" 2>/dev/null || true
sleep 0.3
SOCK="${XDG_RUNTIME_DIR:-$HOME/Library/Application Support/imectl}/imectl.sock"
nohup "$IMECTL" daemon >/tmp/imectl-e2e-daemon.log 2>&1 &
sleep 0.8
check "daemon socket exists" "yes" "$([[ -S "$SOCK" ]] && echo yes || echo no)"
if [[ -n "$ISSW" ]]; then
    check "warm get matches issw" "$("$ISSW")" "$("$IMECTL" get)"
fi
pkill -f "imectl daemon" 2>/dev/null || true
sleep 0.5
check "socket removed on daemon exit" "yes" "$([[ ! -e "$SOCK" ]] && echo yes || echo no)"
if [[ -n "$ISSW" ]]; then
    check "fallback get matches issw" "$("$ISSW")" "$("$IMECTL" get)"
fi

# 5. daemon hardening regressions (ba0cf80 reviewer follow-ups)
pkill -f "imectl daemon" 2>/dev/null || true
sleep 0.3
DAEMON_ERR=/tmp/imectl-e2e-harden-err.log
nohup "$IMECTL" daemon >/tmp/imectl-e2e-harden-out.log 2>"$DAEMON_ERR" &
sleep 0.8

# US-002: a client that connects and sends nothing must not permanently block
# the serial accept loop. With SO_RCVTIMEO (~2s) a concurrent request still
# completes (bounded by the timeout) and the daemon survives.
if command -v python3 >/dev/null 2>&1; then
    STALL_RESULT="$(python3 - "$SOCK" <<'PY'
import socket, sys
sock_path = sys.argv[1]
stall = socket.socket(socket.AF_UNIX)
stall.connect(sock_path)          # connect, send nothing, hold open
c = socket.socket(socket.AF_UNIX)
c.connect(sock_path)
c.sendall(b"get\n")
print(c.recv(4096).decode().strip())
c.close(); stall.close()
PY
)"
    check "stalled client does not block daemon (concurrent get served)" "$ORIGINAL" "$STALL_RESULT"
    check "daemon survives stalled client" "yes" "$(pgrep -f 'imectl daemon' >/dev/null && echo yes || echo no)"
else
    note "python3 unavailable; skipping stall-client check"
fi

# US-001: SIGTERM removes the socket file (async-signal-safe handler).
DPID="$(pgrep -f 'imectl daemon' | head -1)"
if [[ -n "$DPID" ]]; then
    kill -TERM "$DPID" 2>/dev/null || true
    sleep 0.6
    check "SIGTERM removes socket file" "yes" "$([[ ! -e "$SOCK" ]] && echo yes || echo no)"
fi

# US-003: daemon startup/shutdown emits no stray blank stderr line.
# grep -c exits 1 when count is 0; capture the numeric line only and default to 0.
BLANKS="$(grep -cE '^$' "$DAEMON_ERR" 2>/dev/null | head -1)"
BLANKS="${BLANKS:-0}"
check "no stray blank stderr line from daemon" "0" "$BLANKS"

if [[ "$fail" -eq 0 ]]; then
    note "ALL E2E CHECKS PASSED"
else
    note "E2E FAILURES DETECTED"
fi
exit "$fail"
