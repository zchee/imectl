# imectl

A world-fastest-latency macOS keyboard input-source CLI, written in Swift.

`imectl` gets and switches the system keyboard input source. It is **Carbon
(HIToolbox TIS) only, with zero AppKit linkage**, by design — AppKit cannot
manage the *system* input source from a headless process, and linking it would
only add cold-start latency.

## Install

```sh
swift build -c release
rm -f /usr/local/bin/imectl
cp .build/release/imectl /usr/local/bin/imectl
```

Always `rm` the destination before copying — do not `cp` (or `install`) over an
existing copy in place. The release binary carries an ad-hoc (linker-signed)
code signature; overwriting in place truncates and rewrites the file under the
same live vnode, leaving its cached code signature stale. On macOS 26+ (with the
Code Signing Monitor active) the next launch is then killed with `SIGKILL (Code
Signature Invalid)` even though `codesign --verify` still passes. Unlinking
first (`rm`, or BSD `/usr/bin/install`, which renames a fresh file into place)
discards that vnode and revalidates. Note GNU coreutils `install` truncates in
place and does *not* help. If you ever hit this, `rm` the binary and reinstall.

Requires macOS 26+ and a Swift 6.2+ toolchain.

## Usage

```sh
imectl                    # print the current input source ID
imectl get --name         # print the current source's localized name
imectl list               # list selectable, enabled keyboard sources (id<TAB>name)
imectl list --json        # same, as JSON
imectl set com.apple.keylayout.ABC                          # switch by ID
imectl set --language ja                                    # switch by language
imectl --version          # print version
```

Exit codes for `set`: `0` confirmed switch; `2` bad arguments; `3` source not
found; `4` source not selectable/enabled; `5` switch failed or unconfirmed.

## Daemon (lowest latency)

A one-shot invocation pays a ~18 ms one-time HIToolbox connection cost on every
run. For high-frequency switching (e.g. a per-keystroke editor mode hook), run
the resident daemon, which keeps the TIS connection warm and serves requests
over a per-user UNIX domain socket (`$XDG_RUNTIME_DIR/imectl.sock`, else
`~/Library/Application Support/imectl/imectl.sock`, mode `0600`):

```sh
imectl daemon            # run in the foreground (or via the LaunchAgent below)
```

When the daemon is running, `imectl get`/`set`/`list` automatically route to it.
When it is not, they transparently fall back to the in-process one-shot path —
same output, just slower. A sample LaunchAgent for auto-start at login is in
[`contrib/com.github.zchee.imectl.plist`](contrib/com.github.zchee.imectl.plist).

### Why a UNIX socket and not XPC?

The latency-critical path is a short-lived client that reconnects on every
invocation. Both libxpc Mach services and `NSXPCConnection` named services
require a launchd bootstrap lookup on each client start and cannot be vended
ad-hoc; a raw AF_UNIX `connect(2)` is microseconds, needs no launchd to
function, and lets the daemon run foreground/manual/launchd interchangeably.

## Latency

Benchmarked with `hyperfine -N --warmup 30 --runs 300` on macOS 26.5 (arm64),
against [`issw`](https://github.com/vovkasm/input-source-switcher) as the
reference tool:

| Path | Mean | Relative |
|---|---|---|
| `imectl get` (warm daemon) | **3.2 ms ± 0.3** | **10× faster than `issw`**, 8.4× faster than one-shot |
| `imectl get` (one-shot) | 26.8 ms ± 6.7 | 1.19–1.34× faster than `issw` |
| `issw` | 32.0 ms ± 4.3 | baseline |

The one-shot path is bounded by the HIToolbox input-system connection
(~18–22 ms, language-independent); the daemon removes it from the per-operation
cost.

## Architecture

- `IMECore` — library target; links `Carbon`. Contains the TIS wrapper
  (`InputSource`), operations (`TIS`), CLI dispatch (`CLI`), hand-built JSON,
  and the daemon (`Daemon`, `DaemonRouting`, `UnixSocket`, `RequestHandler`).
- `imectl` — thin executable entry point.

The release binary links **no AppKit** (verified via `otool -L`). Foundation is
linked transitively (TIS property bridging to Swift `String`) but is
latency-neutral, as it is resident in the dyld shared cache.

## License

See [LICENSE](LICENSE).
