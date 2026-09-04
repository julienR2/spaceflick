<div align="center">

<img src="assets/icon-256.png" width="128" alt="spaceflick">

# spaceflick

**The macOS space swipe, landing instantly — with the half-swipe peek intact.**

[![macOS 11+](https://img.shields.io/badge/macOS-11%2B-000?logo=apple&logoColor=white)](https://github.com/julienR2/spaceflick)
[![Apple silicon + Intel](https://img.shields.io/badge/arch-arm64%20%2B%20x86__64-555)](https://github.com/julienR2/spaceflick)
[![No SIP changes](https://img.shields.io/badge/SIP-untouched-2ea44f)](https://github.com/julienR2/spaceflick)
[![~180 lines of Swift](https://img.shields.io/badge/~180%20lines-Swift-f05138?logo=swift&logoColor=white)](mac/main.swift)
[![MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

</div>

## The problem

The four-finger space swipe has two halves.

While your fingers are down, the desktops track them one-to-one. That's the good
half — the one you use when you hold a half-swipe to see two spaces at once.

Then you lift, and the Dock animates the remaining distance with a long
ease-out. **That** is the half-second you spend staring at a sliding wallpaper
before the other app is actually focused. It is not the switch being slow. It is
an animation being played to completion.

spaceflick deletes the second half and leaves the first one alone.

## How

It is a single passthrough `CGEventTap`. On the `ended` event of a horizontal
Dock swipe, it rewrites one number — the reported release velocity — to
something enormous. The Dock reads that as a hard flick and commits the
remaining distance in the next frame or two.

That's it. That's the whole program.

- **The gesture is still the native gesture.** Nothing is swallowed, nothing is
  replayed. The finger-tracking phase never sees the tap.
- **The peek still works.** So does peeking and then letting go slowly: a
  release below `--min-velocity` passes through untouched, so the Dock still
  decides that one from how far you dragged, and still snaps back if it wasn't
  far enough.
- **~0% CPU.** Two field reads and one field write per swipe. No timers, no
  polling, no space or window queries. Measured across 19 real swipes: **10ms of
  CPU total.**

## Install

```sh
brew install julienR2/spaceflick/spaceflick
brew services start spaceflick
```

Or from source, which also gets you a proper `/Applications` app started at login:

```sh
git clone https://github.com/julienR2/spaceflick && cd spaceflick
./build.sh install
```

Either way, macOS will ask for **Accessibility** — that is what lets an event tap
see trackpad events. Grant it in System Settings → Privacy & Security →
Accessibility, then restart it:

```sh
brew services restart spaceflick                              # brew
launchctl kickstart -k gui/$(id -u)/com.julien.spaceflick      # from source
```

> Both builds are unsigned, so **every upgrade invalidates the Accessibility
> grant** — macOS keys it to the binary's code signature, and a rebuild changes
> it. If swipes go back to feeling slow after an upgrade, remove spaceflick from
> the Accessibility list and re-add it.

Uninstall: `brew services stop spaceflick && brew uninstall spaceflick`, or
`./build.sh uninstall`.

## Try it before installing

```sh
./build.sh
./build/spaceflick run -v      # swipe a few times, ^C to stop
```

`-v` prints one line per release:

```
flick x 3.898 -> 999999                        # rewritten
skip  x 0.0046 (below --min-velocity 0.0800)   # peek-and-let-go, left alone
```

Decisive swipes land around ±1–5. Peeks land around ±0.005. Three orders of
magnitude apart, which is why a fixed threshold can tell them apart cleanly.

If *every* line says `skip`, your trackpad reports smaller velocities than the
default — lower the threshold with `--min-velocity 0.001`.

## Options

| flag | default | |
|---|---|---|
| `--velocity N` | `999999` | Claimed release velocity. Lower it (`40`, `60`) if you want a fast-but-visible slide instead of a hard cut. |
| `--min-velocity V` | `0.08` | Releases slower than this are passed through untouched, preserving peek-and-let-go. `0` flicks everything. |
| `--vertical` | off | Also flick vertical swipes (Mission Control). |
| `-v`, `--verbose` | off | Log every release. |
| `probe` | | Log the raw private fields of every Dock swipe event and change nothing. For when a macOS update moves the field numbers. |

Pass flags through Homebrew by editing the service plist, or just run the binary
yourself from a launch agent.

## Why not Blink

[Blink](https://github.com/benkoppe/Blink) is where I found the velocity trick,
and it's a much bigger program with a menu bar, hotkeys and settings. But it
*replaces* the gesture rather than adjusting it: it swallows every horizontal
Dock swipe — it doesn't check the finger count, so your four-finger swipe goes
with it — and synthesises its own `began`→`changed`→`ended` burst at velocity
999999.

Two consequences. The half-swipe peek is impossible by construction, because the
whole gesture is posted the instant a movement threshold trips. And the CPU cost
comes from the machinery needed around that: three active event taps, one of
them on **every keystroke**, plus `CGSCopyManagedDisplaySpaces` and a full
`CGWindowListCopyWindowInfo` sweep re-run every 40ms while a switch is in
flight.

spaceflick does the one thing and nothing else. If you want hotkeys, a menu bar
and jump-to-space-N, use Blink — it's good, and it's doing more.

### Things that do not work, so you can stop looking

| | |
|---|---|
| `defaults write com.apple.dock workspaces-swoosh-animation-off` | Dead. The string is not in the macOS 26 Dock binary at all. Last worked around 10.7. |
| `defaults write com.apple.dock expose-animation-duration` | Dead since Sierra, and it targeted Mission Control's zoom, never the space slide. |
| Accessibility → Reduce Motion | Works, doesn't help. Swaps the slide for a cross-fade of roughly the same duration, and you lose the interactive tracking. |
| `SLSSetSpaceTransitionDuration` and friends | Do not exist. No `*SpaceTransition*` symbol is exported from SkyLight on macOS 26. |
| `CGSManagedDisplaySetCurrentSpace` | Exists and switches with no animation, but leaves Dock/WindowServer bookkeeping inconsistent — the reason yabai pairs it with SIP disabled. |

## How it works, in detail

The trackpad's space swipe reaches the Dock as an undocumented event type `30`
(`kCGSEventDockControl`) carrying `kIOHIDEventTypeDockSwipe`. Its private
`CGEventField`s:

| field | meaning |
|---|---|
| `110` | `kIOHIDEventType` — `23` is a Dock swipe |
| `123` | axis — `1` horizontal, `2` vertical |
| `129` / `130` | velocity x / y |
| `132` | phase — `1` began, `2` changed, `4` ended, `8` cancelled |
| `135` | progress bits |

A tap at `.cgSessionEventTap` / `.headInsertEventTap` sits upstream of the Dock,
so a `.defaultTap` there can mutate field `129` on the `phase == 4` event as it
goes past, and hand it on. The Dock never knows.

Field numbers have been stable from at least macOS 11 through 26. If an update
breaks it, `spaceflick probe` shows you what moved.

## Credits

The velocity trick was reverse-engineered from **BetterTouchTool** by
[RGBCube/darwin-fast-workspace-switch](https://github.com/RGBCube/darwin-fast-workspace-switch),
and appears in [jurplel/InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher)
and [benkoppe/Blink](https://github.com/benkoppe/Blink). spaceflick's
contribution is narrow: apply it to the real gesture instead of a synthetic one,
so the peek survives.

## License

MIT
