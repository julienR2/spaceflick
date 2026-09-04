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
private let phaseBegan: Int64 = 1
private let phaseEnded: Int64 = 4

// MARK: - where we are in the space list
//
// Flinging at 999999 past the last space lands the Dock on an index that does
// not exist, which shows as a black screen. Native rubber-bands instead, so at
// an edge we simply leave the gesture alone and let it do that.
//
// The symbols are resolved by hand: they are private, and if a macOS update
// removes one we want to fall back to "allow" rather than fail to launch.

private typealias CGSConnection = Int32
private let cgHandle = dlopen(
    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)

private func cgSymbol<T>(_ name: String, _ type: T.Type) -> T? {
    guard let h = cgHandle, let p = dlsym(h, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

private let cgsMainConnectionID =
    cgSymbol("CGSMainConnectionID", (@convention(c) () -> CGSConnection).self)
private let cgsCopyManagedDisplaySpaces =
    cgSymbol("CGSCopyManagedDisplaySpaces", (@convention(c) (CGSConnection) -> CFArray?).self)
private let cgsCopyActiveMenuBarDisplayIdentifier =
    cgSymbol("CGSCopyActiveMenuBarDisplayIdentifier", (@convention(c) (CGSConnection) -> CFString?).self)

struct SpacePosition {
    var index = -1          // -1 = unknown, in which case we allow the flick
    var count = 0
    var canGoPrev: Bool { index < 0 || index > 0 }
    var canGoNext: Bool { index < 0 || index < count - 1 }
}

/// The swipe applies to the display the pointer is on, which is identified in
/// the space list by its UUID string.
private func cursorDisplayIdentifier() -> String? {
    guard let probe = CGEvent(source: nil) else { return nil }
    var displayID: CGDirectDisplayID = 0
    var matched: UInt32 = 0
    guard CGGetDisplaysWithPoint(probe.location, 1, &displayID, &matched) == .success,
          matched > 0,
          let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
    else { return nil }
    return CFUUIDCreateString(nil, uuid) as String?
}

/// One WindowServer round-trip. Called on `began`, so its cost lands at the
/// start of the gesture where nothing is waiting on it.
func currentSpacePosition() -> SpacePosition {
    var pos = SpacePosition()
    guard let mainID = cgsMainConnectionID, let copySpaces = cgsCopyManagedDisplaySpaces
    else { return pos }
    let cid = mainID()
    guard let displays = copySpaces(cid) as? [[String: Any]], !displays.isEmpty
    else { return pos }

    func identifier(_ d: [String: Any]) -> String? { d["Display Identifier"] as? String }
    let wanted = cursorDisplayIdentifier()
        ?? cgsCopyActiveMenuBarDisplayIdentifier.flatMap { $0(cid) as String? }
    let display = displays.first { identifier($0) == wanted } ?? displays.first!

    // "Spaces" is ordered left to right, and each entry is keyed by id64.
    func spaceID(_ d: [String: Any]) -> UInt64? {
        (d["id64"] as? NSNumber)?.uint64Value
    }
    guard let spaces = display["Spaces"] as? [[String: Any]],
          let current = display["Current Space"] as? [String: Any],
          let currentID = spaceID(current)
    else { return pos }

    let ids = spaces.compactMap(spaceID).filter { $0 != 0 }
    guard let idx = ids.firstIndex(of: currentID) else { return pos }
    pos.index = idx
    pos.count = ids.count
    return pos
}

var spacePosition = SpacePosition()

// MARK: - options

struct Options {
    var probe = false
    var velocity: Double = 999_999   // what we claim your fingers were doing
    var minVelocity: Double = 0.08   // below this, leave the gesture alone
    var vertical = false             // also flick vertical (Mission Control) swipes
    var edgeGuard = true             // don't flick off the end of the space list
    var invert = false               // escape hatch if the direction mapping is wrong
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
        case "--no-edge-guard":  o.edgeGuard = false
        case "--invert":        o.invert = true
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
              --no-edge-guard     allow flicking past the first/last space
              --invert            flip the swipe-direction mapping
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
    let phase = event.getIntegerValueField(fPhase)
    guard motion == motionHorizontal || (opts.vertical && motion != motionHorizontal)
    else { return Unmanaged.passUnretained(event) }

    if phase == phaseBegan {
        spacePosition = opts.edgeGuard ? currentSpacePosition() : SpacePosition()
        return Unmanaged.passUnretained(event)
    }
    guard phase == phaseEnded else { return Unmanaged.passUnretained(event) }

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

    // Positive velocity means the Dock moves right, to the higher index. The
    // trackpad's scroll-direction preference is applied upstream of us, so the
    // sign already encodes where you are going, not which way your fingers went.
    var goesNext = v > 0
    if opts.invert { goesNext.toggle() }

    if motion == motionHorizontal, opts.edgeGuard,
       goesNext ? !spacePosition.canGoNext : !spacePosition.canGoPrev {
        if opts.verbose {
            print(String(format: "edge  %@ %.3f — space %d/%d, no %@ space, left native",
                         goesNext ? "next" : "prev", v,
                         spacePosition.index + 1, spacePosition.count,
                         goesNext ? "next" : "previous"))
            fflush(stdout)
        }
        return Unmanaged.passUnretained(event)
    }

    let flung = v < 0 ? -opts.velocity : opts.velocity
    event.setDoubleValueField(axis, value: flung)
    if opts.verbose {
        print(String(format: "flick %@ %.3f -> %.0f  (%@, space %d/%d)",
                     motion == motionHorizontal ? "x" : "y", v, flung,
                     goesNext ? "next" : "prev",
                     spacePosition.index + 1, spacePosition.count))
        fflush(stdout)
    }
    return Unmanaged.passUnretained(event)
}

var tapRef: CFMachPort?

func log(_ line: String) {
    print(line)
    fflush(stdout)
}

/// .cgSessionEventTap + headInsert puts us upstream of the Dock, which is the
/// process that owns the space animation.
func installTap() -> Bool {
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,             // must be a default tap: we mutate the event
        eventsOfInterest: CGEventMask(1) << CGEventMask(dockControlEventType),
        callback: callback,
        userInfo: nil
    ) else { return false }

    tapRef = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    if opts.probe {
        log("spaceflick probe — swipe now, ^C to stop")
    } else if opts.verbose {
        log("""
        spaceflick running — velocity \(opts.velocity), min \(opts.minVelocity), \
        edge guard \(opts.edgeGuard ? "on" : "off")
        """)
    }
    return true
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("spaceflick: \(message)\n".data(using: .utf8)!)
    exit(1)
}

if AXIsProcessTrusted() {
    guard installTap() else { fail("could not create the event tap") }
} else {
    // Do NOT exit here. Under launchd (brew services, or the login agent) the
    // job is KeepAlive, so exiting would just respawn us every 10 seconds
    // forever. Instead wait for the grant, which also means granting it takes
    // effect immediately rather than needing a restart.
    log("""
    spaceflick needs Accessibility access to see the trackpad's swipe events.
    Add it in System Settings → Privacy & Security → Accessibility.
    Waiting for that — no need to restart me once you have.
    """)
    // Ask once, so the entry shows up in the list ready to be switched on.
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)

    // The only polling in the program, and it stops the moment we are trusted.
    let timer = CFRunLoopTimerCreateWithHandler(
        kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 2, 2, 0, 0
    ) { timer in
        guard AXIsProcessTrusted() else { return }
        CFRunLoopTimerInvalidate(timer)
        log("Accessibility granted.")
        guard installTap() else { fail("could not create the event tap") }
    }
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
}

CFRunLoopRun()
