// spaceflick — make the macOS 4-finger space swipe land instantly.
//
// The native gesture stays exactly as it is: the spaces still track your
// fingers, so a half-swipe still shows both desktops side by side. The only
// thing this changes is the release: when your fingers lift, the Dock is told
// the flick was far faster than it really was, so it commits the remaining
// distance in ~0 instead of playing the long ease-out.
//
// It is a single passthrough CGEventTap that rewrites two numbers on one event
// per swipe. No synthetic events, no polling, no window/space queries, so it
// sits at 0% CPU when you are not swiping.

import Foundation
import CoreGraphics
import ApplicationServices

// MARK: - private CGEvent fields on the Dock's swipe pipeline
// Field numbers reverse-engineered by BetterTouchTool, and reused by
// InstantSpaceSwitcher and Blink. Stable from at least macOS 11 to 26.

private func field(_ n: UInt32) -> CGEventField { CGEventField(rawValue: n)! }

private let fHIDType     = field(110)  // kIOHIDEventType; 23 = DockSwipe
private let fSwipeMotion = field(123)  // 1 = horizontal, 2 = vertical
private let fVelocityX   = field(129)
private let fVelocityY   = field(130)
private let fPhase       = field(132)  // 1 began, 2 changed, 4 ended, 8 cancelled
private let fProgress    = field(135)

private let dockControlEventType: UInt32 = 30   // kCGSEventDockControl
private let hidTypeDockSwipe: Int64 = 23        // kIOHIDEventTypeDockSwipe
private let motionHorizontal: Int64 = 1
private let phaseEnded: Int64 = 4

// MARK: - options

struct Options {
    var probe = false
    var velocity: Double = 999_999   // what we claim your fingers were doing
    var minVelocity: Double = 0.08   // below this, leave the gesture alone
    var vertical = false             // also flick vertical (Mission Control) swipes
    var verbose = false
}

func parseArgs() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while let a = args.first {
        args.removeFirst()
        switch a {
        case "probe":           o.probe = true
        case "run":             break
        case "--velocity":      o.velocity = Double(args.removeFirst()) ?? o.velocity
        case "--min-velocity":  o.minVelocity = Double(args.removeFirst()) ?? o.minVelocity
        case "--vertical":      o.vertical = true
        case "-v", "--verbose": o.verbose = true
        case "-h", "--help":
            print("""
            spaceflick — instant landing for the native macOS space swipe

              spaceflick run      rewrite the release velocity (the actual tool)
              spaceflick probe    log raw DockSwipe events, change nothing

            Options
              --velocity N        claimed release velocity (default 999999)
              --min-velocity V    don't touch releases slower than V (default 0.08),
                                  so a slow peek-and-let-go still snaps back natively
              --vertical          also flick vertical swipes (Mission Control)
              -v, --verbose       log every swipe it rewrites
            """)
            exit(0)
        default:
            FileHandle.standardError.write("spaceflick: unknown argument \(a)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return o
}

let opts = parseArgs()

// MARK: - probe / rewrite

func dump(_ e: CGEvent) {
    var parts: [String] = []
    for n in UInt32(100)...UInt32(150) {
        let f = field(n)
        let i = e.getIntegerValueField(f)
        let d = e.getDoubleValueField(f)
        if i == 0 && d == 0 { continue }
        parts.append(abs(d) > 0 && Double(i) != d ? "\(n)=\(String(format: "%.4f", d))" : "\(n)=\(i)")
    }
    print("dockControl " + parts.joined(separator: " "))
    fflush(stdout)
}

let callback: CGEventTapCallBack = { _, type, event, _ in
    // The tap can be shut off by the system if we are ever too slow; turn it back on.
    if type.rawValue == 0xFFFF_FFFE || type.rawValue == 0xFFFF_FFFF {
        if let tap = tapRef { CGEvent.tapEnable(tap: tap, enable: true) }
        return nil
    }
    guard type.rawValue == dockControlEventType,
          event.getIntegerValueField(fHIDType) == hidTypeDockSwipe
    else { return Unmanaged.passUnretained(event) }

    if opts.probe {
        dump(event)
        return Unmanaged.passUnretained(event)
    }

    let motion = event.getIntegerValueField(fSwipeMotion)
    guard motion == motionHorizontal || (opts.vertical && motion != motionHorizontal),
          event.getIntegerValueField(fPhase) == phaseEnded
    else { return Unmanaged.passUnretained(event) }

    // Only amplify a release that already had a direction. A near-zero release
    // is you peeking at the next space and letting go: the Dock decides that one
    // from how far you dragged, and we must not force it to commit.
    let axis = motion == motionHorizontal ? fVelocityX : fVelocityY
    let v = event.getDoubleValueField(axis)
    guard abs(v) >= opts.minVelocity else {
        if opts.verbose {
            print(String(format: "skip  %@ %.4f (below --min-velocity %.4f)",
                         motion == motionHorizontal ? "x" : "y", v, opts.minVelocity))
            fflush(stdout)
        }
        return Unmanaged.passUnretained(event)
    }

    let flung = v < 0 ? -opts.velocity : opts.velocity
    event.setDoubleValueField(axis, value: flung)
    if opts.verbose {
        print(String(format: "flick %@ %.3f -> %.0f", motion == motionHorizontal ? "x" : "y", v, flung))
        fflush(stdout)
    }
    return Unmanaged.passUnretained(event)
}

var tapRef: CFMachPort?

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write("""
    spaceflick needs Accessibility access to see the trackpad's swipe events.
    Grant it in System Settings → Privacy & Security → Accessibility, then run again.

    """.data(using: .utf8)!)
    // Ask once, so the entry appears in the list.
    let opt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([opt: true] as CFDictionary)
    exit(1)
}

// .cgSessionEventTap + headInsert puts us upstream of the Dock, which is the
// process that owns the space animation.
guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,                 // must be a default tap: we mutate the event
    eventsOfInterest: CGEventMask(1) << CGEventMask(dockControlEventType),
    callback: callback,
    userInfo: nil
) else {
    FileHandle.standardError.write("spaceflick: could not create the event tap\n".data(using: .utf8)!)
    exit(1)
}
tapRef = tap

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

if opts.probe {
    print("spaceflick probe — swipe now, ^C to stop")
} else if opts.verbose {
    print("spaceflick running — velocity \(opts.velocity), min \(opts.minVelocity)")
}
fflush(stdout)
CFRunLoopRun()
