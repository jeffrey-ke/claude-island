# UI/Window Mechanisms — Claude Island

This document covers every macOS and Swift framework call used across the UI, window, and component layers of Claude Island, explaining *why* each API achieves its intended effect and how the calls are composed together.

---

## Table of Contents

1. [App Entry and Lifecycle](#1-app-entry-and-lifecycle)
2. [Window Construction — NotchPanel](#2-window-construction--notchpanel)
3. [Window Controller and SwiftUI Hosting](#3-window-controller-and-swiftui-hosting)
4. [Hit-Testing and Click-Through](#4-hit-testing-and-click-through)
5. [Screen Detection and Observation](#5-screen-detection-and-observation)
6. [Global Event Monitoring](#6-global-event-monitoring)
7. [Core ViewModel — State and Geometry](#7-core-viewmodel--state-and-geometry)
8. [NotchShape — Custom Clip Path](#8-notchshape--custom-clip-path)
9. [Animation System](#9-animation-system)
10. [NotchView — Top-Level SwiftUI Layout](#10-notchview--top-level-swiftui-layout)
11. [Canvas-Based Pixel Art Icons](#11-canvas-based-pixel-art-icons)
12. [ProcessingSpinner — Timer-Driven Animation](#12-processingspinner--timer-driven-animation)
13. [Chat View — Inverted Scroll](#13-chat-view--inverted-scroll)
14. [Markdown Renderer](#14-markdown-renderer)
15. [Screen Selection](#15-screen-selection)
16. [Sound Selection and Playback](#16-sound-selection-and-playback)
17. [Session State Model](#17-session-state-model)
18. [Activity Coordinator](#18-activity-coordinator)
19. [Single-Instance Enforcement and Activation Policy](#19-single-instance-enforcement-and-activation-policy)
20. [Event Re-posting via CGEvent](#20-event-re-posting-via-cgevent)
21. [Launch-at-Login via ServiceManagement](#21-launch-at-login-via-servicemanagement)
22. [Accessibility Permission Check](#22-accessibility-permission-check)
23. [Hardware Identity via IOKit](#23-hardware-identity-via-iokit)

---

## 1. App Entry and Lifecycle

**File:** `ClaudeIsland/App/ClaudeIslandApp.swift`, `ClaudeIsland/App/AppDelegate.swift`

### `@main` / `App` protocol

```swift
@main
struct ClaudeIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}
```

SwiftUI's `App` protocol provides the application entry point via the `@main` attribute. The `body` returns a scene graph. Because Claude Island uses a fully custom window rather than a SwiftUI-managed `WindowGroup`, the scene is left as an empty `Settings` scene — this satisfies the type system without creating any window. All real window management happens in `AppDelegate`.

`@NSApplicationDelegateAdaptor` bridges the SwiftUI lifecycle to an `NSApplicationDelegate`. SwiftUI would otherwise own the app delegate; this property wrapper injects a custom class that hooks into AppKit lifecycle callbacks (`applicationDidFinishLaunching`, `applicationWillTerminate`).

### `NSApplicationDelegate` callbacks

`applicationDidFinishLaunching` is the first safe place to create windows and register observers because the run loop is running, screen geometry is available, and AppKit has completed its own setup.

`applicationWillTerminate` is used to flush analytics and tear down the screen observer before the process exits.

### `NSApplication.shared.setActivationPolicy(.accessory)`

This call, made in `applicationDidFinishLaunching`, removes Claude Island from the Dock and the Cmd-Tab application switcher. `.accessory` apps remain running but are invisible to the user as a conventional application — appropriate for a menu-bar / notch overlay that should never steal focus from the user's workflow.

---

## 2. Window Construction — NotchPanel

**File:** `ClaudeIsland/UI/Window/NotchWindow.swift`

### `NSPanel` subclass instead of `NSWindow`

`NSPanel` is chosen over `NSWindow` because panels are designed for auxiliary floating UI. The key capability needed here is `.nonactivatingPanel` — a panel with this style mask can receive mouse events and key input without becoming the active application. A regular `NSWindow` would bring the app to the foreground whenever clicked, which would disrupt whatever the user is working on.

### Style mask composition

```swift
styleMask: [.borderless, .nonactivatingPanel]
```

- `.borderless` removes the title bar, resize handles, and all chrome, leaving only the content view. This is required because the panel is a purely custom-drawn shape — any window chrome would be visible through the transparent background.
- `.nonactivatingPanel` is the panel-specific mask that suppresses app activation on click.

### Transparency configuration

```swift
isOpaque = false
backgroundColor = .clear
hasShadow = false
```

These three properties together make the window background invisible. `isOpaque = false` tells AppKit that the window's backing buffer uses pre-multiplied alpha, enabling pixel-level transparency. `backgroundColor = .clear` removes the default opaque background paint. `hasShadow = false` removes the default drop shadow that AppKit would otherwise project from the window edges — the shadow is re-added selectively via SwiftUI's `.shadow()` modifier only when the panel is open.

### Window level

```swift
level = .mainMenu + 3
```

`NSWindow.Level.mainMenu` is the level of the macOS menu bar itself. Adding 3 places the panel above the menu bar in the compositor's z-order, which is necessary to draw in the notch region — the notch is physically above the menu bar's rendering layer.

### Collection behavior

```swift
collectionBehavior = [
    .fullScreenAuxiliary,
    .stationary,
    .canJoinAllSpaces,
    .ignoresCycle
]
```

- `.fullScreenAuxiliary`: Allows the panel to appear in full-screen spaces, where regular windows would be hidden.
- `.stationary`: Prevents Mission Control from moving or animating this window during space transitions.
- `.canJoinAllSpaces`: Makes the window appear on every Space simultaneously, so it is always visible regardless of which Space the user navigates to.
- `.ignoresCycle`: Excludes the window from the Cmd-Tab and window-cycling mechanisms.

### `ignoresMouseEvents = true` (initial state)

When the notch is closed, mouse events must pass through the panel to reach the menu bar and applications behind it. Setting `ignoresMouseEvents = true` achieves this: AppKit will not deliver any mouse events to this window at all. The `NotchWindowController` toggles this to `false` when the panel opens so that buttons inside the panel work.

### `isMovable = false`

Prevents AppKit from moving the window in response to window-drag gestures. Without this, a drag in the notch area would try to move the panel.

---

## 3. Window Controller and SwiftUI Hosting

**File:** `ClaudeIsland/UI/Window/NotchWindowController.swift`, `ClaudeIsland/UI/Window/NotchViewController.swift`

### `NSWindowController`

`NotchWindowController` subclasses `NSWindowController`, which is the standard AppKit controller that owns an `NSWindow` and manages its show/hide lifecycle. The controller is the appropriate home for window construction logic because it has a defined lifecycle that matches the window's.

### Frame positioning

```swift
let windowFrame = NSRect(
    x: screenFrame.origin.x,
    y: screenFrame.maxY - windowHeight,
    width: screenFrame.width,
    height: windowHeight
)
```

The window spans the full width of the screen at its very top. AppKit screen coordinates have the origin at the bottom-left of the primary screen. `screenFrame.maxY - windowHeight` positions the bottom edge of the window 750 points below the top of the screen, making the window's top flush with the screen's top edge. This ensures the notch content is always correctly positioned regardless of screen resolution.

### SwiftUI hosting via `NSHostingController` / `NSHostingView`

`NSViewController` is the bridge between AppKit's view controller hierarchy and SwiftUI. `NSHostingView<Content>` (subclassed as `PassThroughHostingView`) wraps a SwiftUI view tree in an `NSView` that participates in the AppKit responder chain. Setting it as `contentViewController` hands the SwiftUI root view ownership of the window's content area.

### Combine subscription for mouse event toggling

```swift
viewModel.$status
    .receive(on: DispatchQueue.main)
    .sink { [weak notchWindow, weak viewModel] status in
        switch status {
        case .opened:
            notchWindow?.ignoresMouseEvents = false
            NSApp.activate(ignoringOtherApps: false)
            notchWindow?.makeKey()
        case .closed, .popping:
            notchWindow?.ignoresMouseEvents = true
        }
    }
    .store(in: &cancellables)
```

`@Published var status` on `NotchViewModel` produces a Combine publisher. The `$status` projected value is that publisher. `.receive(on: DispatchQueue.main)` ensures the `ignoresMouseEvents` mutation happens on the main thread, where AppKit requires all window state changes. The subscription is kept alive by storing the `AnyCancellable` in `cancellables`, which is owned by the controller.

`NSApp.activate(ignoringOtherApps: false)` and `makeKey()` bring the panel to key window status when opened by user click or hover, allowing keyboard input to reach the panel's text fields and buttons. When opened by notification (Claude finished), these calls are skipped so the user's current application keeps focus.

---

## 4. Hit-Testing and Click-Through

**File:** `ClaudeIsland/UI/Window/NotchViewController.swift`

### `PassThroughHostingView` — overriding `hitTest`

```swift
class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    var hitTestRect: () -> CGRect = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard hitTestRect().contains(point) else {
            return nil
        }
        return super.hitTest(point)
    }
}
```

`hitTest(_:)` is AppKit's mechanism for determining which view should receive a mouse event. When a view returns `nil`, AppKit passes the event down to the next window in z-order. By overriding it to return `nil` for points outside the notch panel rectangle, clicks anywhere on the screen that are not over the visible panel content are forwarded to the applications or menu bar behind the window. This gives the appearance of a transparent overlay that only intercepts clicks on its own visible content.

The `hitTestRect` closure is recomputed on each call based on the current `viewModel.status`, so the interactive area automatically changes between the small notch region (closed) and the full panel (opened).

### Coordinate system note

AppKit's `NSView` coordinate system has the origin at the bottom-left, with Y increasing upward. Since the window is anchored to the top of the screen, the hit-test rect is calculated as:

```swift
y: windowHeight - panelHeight
```

This places the rect at the top of the window's coordinate space.

---

## 5. Screen Detection and Observation

**File:** `ClaudeIsland/App/ScreenObserver.swift`, `ClaudeIsland/Core/Ext+NSScreen.swift`, `ClaudeIsland/Core/ScreenSelector.swift`

### `NSApplication.didChangeScreenParametersNotification`

```swift
NotificationCenter.default.addObserver(
    forName: NSApplication.didChangeScreenParametersNotification,
    object: nil,
    queue: .main
) { [weak self] _ in
    self?.onScreenChange()
}
```

macOS posts this notification whenever the display configuration changes: a monitor is connected or disconnected, resolution changes, display arrangement changes, or the machine wakes from sleep with a different screen. Listening to it allows the app to destroy and recreate the notch window at the correct position for the new configuration.

The observer is stored as `Any?` (the opaque token returned by `addObserver`) and removed in `deinit` via `NotificationCenter.default.removeObserver(observer)` to prevent dangling observers.

### `NSScreen.safeAreaInsets.top` — notch detection

```swift
var hasPhysicalNotch: Bool {
    safeAreaInsets.top > 0
}
```

On MacBooks with a physical notch, macOS reports `safeAreaInsets.top > 0` for the built-in display. This is the authoritative way to detect a notch: it is set by the display driver and is not guessable from screen dimensions.

### Notch size calculation

```swift
let notchHeight = safeAreaInsets.top
let fullWidth = frame.width
let leftPadding = auxiliaryTopLeftArea?.width ?? 0
let rightPadding = auxiliaryTopRightArea?.width ?? 0
let notchWidth = fullWidth - leftPadding - rightPadding + 4
```

`auxiliaryTopLeftArea` and `auxiliaryTopRightArea` are `NSRect` properties on `NSScreen` that describe the usable menu bar areas to the left and right of the notch. Subtracting them from the full screen width yields the notch width. The `+ 4` adjustment matches the calculation used by other notch apps (notably boring.notch) to align perfectly with the physical camera housing edge.

### Built-in display detection

```swift
var isBuiltinDisplay: Bool {
    guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
        return false
    }
    return CGDisplayIsBuiltin(screenNumber) != 0
}
```

`deviceDescription` is an `NSScreen` property returning a dictionary of display hardware characteristics. The `"NSScreenNumber"` key maps to the `CGDirectDisplayID`, which is CoreGraphics' integer identifier for a connected display. `CGDisplayIsBuiltin()` queries IOKit via CoreGraphics to determine whether that display is the laptop's internal panel. This is more reliable than checking the screen's name string.

### Screen identifier persistence

`ScreenIdentifier` encodes a `CGDirectDisplayID` and a `localizedName`. The display ID is the primary match key; the name is a fallback for when the display is reconnected and macOS assigns it a new ID. The identifier is JSON-encoded and stored in `UserDefaults` using `JSONEncoder`/`JSONDecoder`, persisting the user's screen selection across app restarts.

---

## 6. Global Event Monitoring

**File:** `ClaudeIsland/Events/EventMonitor.swift`, `ClaudeIsland/Events/EventMonitors.swift`

### `NSEvent.addGlobalMonitorForEvents(matching:)` and `addLocalMonitorForEvents`

```swift
globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
    self?.handler(event)
}
localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
    self?.handler(event)
    return event
}
```

Global monitors receive events from all applications system-wide, regardless of which app is active. This is the only way to track mouse movement and clicks when the user is interacting with another application — which is the normal state, since Claude Island is a background overlay. Accessibility permission (`AXIsProcessTrusted()`) is required for global monitors.

Local monitors receive events destined for the app itself. Both are registered so that events work whether the user is inside or outside Claude Island.

The local monitor handler returns the event (`return event`), which allows it to propagate normally through the responder chain. Returning `nil` would swallow the event.

### `EventMonitors` — Combine bridge

`EventMonitors` wraps the raw monitor callbacks in Combine subjects:

```swift
let mouseLocation = CurrentValueSubject<CGPoint, Never>(.zero)
let mouseDown = PassthroughSubject<NSEvent, Never>()
```

`CurrentValueSubject` holds the most recent mouse position and replays it to new subscribers, which is the correct semantic for "current state." `PassthroughSubject` has no stored value and only delivers events to active subscribers, which is correct for discrete events like mouse down.

`NSEvent.mouseLocation` (called inside the move monitor callback) returns the current cursor position in screen coordinates. The coordinates use the AppKit convention (origin at bottom-left of primary screen).

### Throttling in `NotchViewModel`

```swift
events.mouseLocation
    .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
    .sink { [weak self] location in
        self?.handleMouseMove(location)
    }
```

`.throttle(for:scheduler:latest:true)` limits mouse move processing to at most 20 times per second. Without throttling, mouse movement generates hundreds of events per second, and the hover geometry check would run that often. `latest: true` means the most recent location within each 50ms window is delivered, preventing stale positions.

---

## 7. Core ViewModel — State and Geometry

**File:** `ClaudeIsland/Core/NotchViewModel.swift`, `ClaudeIsland/Core/NotchGeometry.swift`

### `@MainActor` class with `@Published` properties

```swift
@MainActor
class NotchViewModel: ObservableObject {
    @Published var status: NotchStatus = .closed
    @Published var openReason: NotchOpenReason = .unknown
    @Published var contentType: NotchContentType = .instances
```

`@MainActor` ensures all mutations to this object happen on the main thread, which is required because SwiftUI reads `@Published` properties on the main thread to drive view updates. Without this annotation, the compiler would not enforce thread safety.

`ObservableObject` + `@Published` is the SwiftUI reactivity mechanism. When a `@Published` property changes, the object sends a `objectWillChange` notification before the mutation. SwiftUI's `@ObservedObject` (in views) subscribes to this and invalidates the view's body for the next render cycle.

### `DispatchWorkItem` for hover timer

```swift
let workItem = DispatchWorkItem { [weak self] in
    guard let self = self, self.isHovering else { return }
    self.notchOpen(reason: .hover)
}
hoverTimer = workItem
DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
```

`DispatchWorkItem` is used instead of a `Timer` because it can be cancelled cheaply without invalidation side effects. When the mouse leaves the notch before 1 second, `hoverTimer?.cancel()` prevents the open action from firing. This implements the hover-delay-to-open behavior without leaking a timer.

### `NotchGeometry` — pure value type

`NotchGeometry` is a `struct` marked `Sendable` (safe for concurrent reads) that holds only `CGRect` and `CGFloat` values. All hit-testing computations are methods on this struct. Keeping geometry calculations in a pure value type makes them testable in isolation and free of side effects.

`notchScreenRect` converts the window-local `deviceNotchRect` to screen coordinates by adding `screenRect.midX` and `screenRect.maxY` offsets. This is necessary because `NSEvent.mouseLocation` returns screen coordinates, not window-local coordinates.

---

## 8. NotchShape — Custom Clip Path

**File:** `ClaudeIsland/UI/Components/NotchShape.swift`

### `Shape` protocol and `Path`

```swift
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: ...)
        path.addQuadCurve(to:control:)
        path.addLine(to:)
        ...
        return path
    }
}
```

SwiftUI's `Shape` protocol requires a single method `path(in:)` that returns a `Path` for a given bounding rectangle. The shape is used as a `.clipShape()` on the notch background, causing SwiftUI to mask all content to the path. This produces the rounded notch shape.

`Path.addQuadCurve(to:control:)` draws a quadratic Bézier curve. The top corners use inward-curving quadratics to match the physical notch's characteristic concave top edges. The bottom corners use outward quadratics for the convex bottom rounded corners.

### `AnimatablePair` for morphing animation

```swift
var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { .init(topCornerRadius, bottomCornerRadius) }
    set { topCornerRadius = newValue.first; bottomCornerRadius = newValue.second }
}
```

SwiftUI's animation system interpolates the `animatableData` property when a shape changes. By conforming to `Animatable` via `AnimatablePair`, both corner radii are interpolated simultaneously when the notch transitions between closed (small radii) and opened (large radii) states. Without this, the shape would snap between states without animating.

---

## 9. Animation System

**File:** `ClaudeIsland/UI/Views/NotchView.swift`

### Spring animations

```swift
private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
```

`Animation.spring(response:dampingFraction:)` produces a physically-based spring animation. `response` controls the speed (lower = faster). `dampingFraction: 0.8` on open gives a slight overshoot (bounce), mimicking the Dynamic Island's expand animation. `dampingFraction: 1.0` on close is critically damped — no bounce — giving a clean collapse.

### `.animation(_:value:)` — explicit value-based triggers

```swift
.animation(viewModel.status == .opened ? openAnimation : closeAnimation, value: viewModel.status)
.animation(openAnimation, value: notchSize)
.animation(.smooth, value: activityCoordinator.expandingActivity)
```

The explicit `.animation(_:value:)` form (as opposed to the deprecated implicit `.animation()`) animates only when the specified `value` changes. This prevents unintended animations when unrelated state changes occur. Multiple modifiers can be stacked to apply different animation curves to different state changes on the same view.

### `.transition(.asymmetric(...))` — content swap animations

```swift
.transition(
    .asymmetric(
        insertion: .scale(scale: 0.8, anchor: .top)
            .combined(with: .opacity)
            .animation(.smooth(duration: 0.35)),
        removal: .opacity.animation(.easeOut(duration: 0.15))
    )
)
```

`.asymmetric` allows different animations for appearing and disappearing. Content inserts by growing from 80% scale at the top anchor while fading in (giving a "drop down" feel). It removes by simply fading out quickly. `.combined(with:)` runs both transitions simultaneously.

### `@Namespace` and `matchedGeometryEffect` — element continuity

```swift
@Namespace private var activityNamespace

ClaudeCrabIcon(...)
    .matchedGeometryEffect(id: "crab", in: activityNamespace, isSource: showClosedActivity)
```

`matchedGeometryEffect` implements the "hero transition" from iOS. When the `isSource` parameter changes between two views sharing the same `id` and namespace, SwiftUI animates the geometric transition between their positions and sizes. Here, the crab icon smoothly moves from its closed-state position (in the header row's activity indicator) to its opened-state position (in the opened header content). SwiftUI inserts a ghost image and animates its frame rather than re-rendering both views.

### `withAnimation` + `DispatchWorkItem` for bounce

```swift
isBouncing = true
DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
    isBouncing = false
}
```

The bounce animation triggers when a session enters `waitingForInput`. The `isBouncing` state change is observed by an `.animation(.spring(response: 0.3, dampingFraction: 0.5), value: isBouncing)` modifier, which produces an underdamped spring (`dampingFraction: 0.5` < 1.0) causing visible oscillation. Setting `isBouncing` back to `false` after 150ms triggers another spring in the reverse direction, creating the brief bounce.

---

## 10. NotchView — Top-Level SwiftUI Layout

**File:** `ClaudeIsland/UI/Views/NotchView.swift`

### `.preferredColorScheme(.dark)`

Applied at the root of `NotchView`, this forces the entire subtree to use dark mode. Since the notch background is always black, all text and icons need to be designed for dark mode. Without this, system components like `TextField` and `ProgressView` would use the user's system appearance, which could be light.

### `.onAppear` / `.onReceive` / `.onChange`

These three modifiers represent three different subscription patterns:

- `.onAppear`: one-shot setup when the view enters the hierarchy (starts monitoring, initializes visible state).
- `.onChange(of:)`: reacts to specific `@State` or `@ObservedObject` value changes within this view hierarchy. The two-parameter form `{ oldValue, newValue in }` is the modern API (iOS 17+/macOS 14+) that provides both old and new values.
- `.onReceive(_:)`: subscribes to an arbitrary Combine publisher. Used here to subscribe to `ChatHistoryManager.shared.$histories` (a `@Published` dictionary) without the view owning the source object.

### `@StateObject` vs `@ObservedObject`

```swift
@StateObject private var sessionMonitor = ClaudeSessionMonitor()
@StateObject private var activityCoordinator = NotchActivityCoordinator.shared
@ObservedObject var viewModel: NotchViewModel
```

`@StateObject` ties the object's lifetime to the view — SwiftUI creates it once and keeps it alive as long as the view is in the hierarchy. `@ObservedObject` observes an object whose lifetime is managed externally. The session monitor is owned by this view, so `@StateObject` is correct. The view model is passed in from `NotchWindowController`, which owns it, so `@ObservedObject` is correct.

### `Task { }` for async focus check

```swift
Task {
    let shouldPlaySound = await shouldPlayNotificationSound(for: newlyWaitingSessions)
    if shouldPlaySound {
        await MainActor.run {
            NSSound(named: soundName)?.play()
        }
    }
}
```

`Task { }` creates a new unstructured Swift concurrency task on the current actor (main actor, since this is called inside a SwiftUI view modifier that runs on the main thread). `await MainActor.run { }` ensures the `NSSound.play()` call returns to the main thread, as AppKit sound APIs are not thread-safe.

---

## 11. Canvas-Based Pixel Art Icons

**File:** `ClaudeIsland/UI/Views/NotchHeaderView.swift`, `ClaudeIsland/UI/Components/StatusIcons.swift`

### `Canvas { context, size in }`

SwiftUI's `Canvas` view provides immediate-mode 2D drawing. Unlike `Shape`, which renders a single path, `Canvas` can issue multiple fill/stroke calls in a single draw pass. It is GPU-accelerated and does not create a SwiftUI view for each drawn element, making it efficient for pixel-art icons drawn as arrays of rectangles.

```swift
Canvas { context, canvasSize in
    let scale = size / 52.0
    let path = Path { p in p.addRect(...) }
    context.fill(path, with: .color(color))
}
```

`context.fill(_:with:)` fills a `Path` with a `GraphicsContext.Shading`. The shading `.color(color)` accepts a SwiftUI `Color`, which is resolved to the display color space at draw time.

### `CGAffineTransform` for scaling

```swift
Path { p in p.addRect(...) }
    .applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: offset, y: 0))
```

`Path.applying(_:)` applies a `CGAffineTransform` to all points in the path. Scaling by `size / originalViewBoxHeight` makes the icon vector-scale to any target size. `translatedBy` centers the icon horizontally in the canvas frame.

### `Timer.publish(every:on:in:).autoconnect()` for crab animation

```swift
private let legTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()
```

Combine's `Timer.publish` creates a publisher that fires on the specified `RunLoop`. `.autoconnect()` subscribes automatically when the first subscriber appears and cancels when the last subscriber disappears, managing timer lifecycle without manual start/stop. The `.common` run loop mode ensures the timer fires even during scroll events (as opposed to `.default`, which is blocked during tracking).

The timer advances `legPhase` through a 4-frame walking cycle. Since the crab legs are redrawn each time `legPhase` changes (triggering a view update), this produces a flipbook animation inside the Canvas.

---

## 12. ProcessingSpinner — Timer-Driven Animation

**File:** `ClaudeIsland/UI/Components/ProcessingSpinner.swift`

```swift
private let timer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

var body: some View {
    Text(symbols[phase % symbols.count])
        .onReceive(timer) { _ in
            phase = (phase + 1) % symbols.count
        }
}
```

The spinner cycles through six Unicode symbols (`·`, `✢`, `✳`, `∗`, `✻`, `✽`) at 150ms intervals. This gives 6.67 frames per second — slow enough to be readable, fast enough to communicate activity. The approach uses a timer rather than SwiftUI's `withAnimation` because the symbol changes are discrete (not interpolable), making a physics-based animation inapplicable.

`RunningIcon` in `StatusIcons.swift` uses a different technique — `withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false))` applied to `rotationEffect(.degrees(rotation))` — for a continuous rotation that is more CPU-efficient than a timer because SwiftUI handles the interpolation internally on the render thread.

---

## 13. Chat View — Inverted Scroll

**File:** `ClaudeIsland/UI/Views/ChatView.swift`

### Inverted `ScrollView` pattern

```swift
ScrollView(.vertical, showsIndicators: false) {
    LazyVStack(spacing: 16) {
        Color.clear.frame(height: 1).id("bottom")
        ForEach(history.reversed()) { item in
            MessageItemView(...)
                .scaleEffect(x: 1, y: -1)
        }
    }
}
.scaleEffect(x: 1, y: -1)
```

The entire `ScrollView` is flipped vertically with `scaleEffect(x: 1, y: -1)`. This makes the bottom of the content appear at the top of the scroll container, so the most recent message is at the visual bottom without needing to scroll. Each child view is individually counter-flipped with the same transform so text and images render right-side-up. This technique avoids the need to programmatically scroll to the bottom on every update — the visual bottom is always in the default (unscrolled) position.

The items are rendered in `history.reversed()` order so that they appear newest-first at the bottom.

An invisible `Color.clear` anchor with `id("bottom")` is placed first in the stack (which, after the flip, appears at the visual bottom). `ScrollViewReader.proxy.scrollTo("bottom", anchor: .bottom)` uses this to programmatically scroll when new messages arrive while autoscroll is paused.

### `onScrollGeometryChange` — scroll position detection

```swift
.onScrollGeometryChange(for: Bool.self) { geometry in
    geometry.contentOffset.y < 50
} action: { wasAtBottom, isNowAtBottom in
    if wasAtBottom && !isNowAtBottom {
        pauseAutoscroll()
    } else if !wasAtBottom && isNowAtBottom && isAutoscrollPaused {
        resumeAutoscroll()
    }
}
```

`onScrollGeometryChange` (macOS 14+) fires the `action` closure only when the computed `Bool` value changes, avoiding continuous callbacks. When `contentOffset.y < 50` (near the unscrolled position, which is the visual bottom in the inverted layout), autoscroll is active. This detects user scroll intent without polling.

### `@FocusState` for auto-focus

```swift
@FocusState private var isInputFocused: Bool

DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
    if canSendMessages {
        isInputFocused = true
    }
}
```

`@FocusState` is SwiftUI's mechanism for programmatically managing keyboard focus. Setting `isInputFocused = true` moves focus to the `TextField` decorated with `.focused($isInputFocused)`. The 300ms delay allows the panel's open animation to complete before focus is requested, avoiding a visual glitch where the keyboard shifts layout during animation.

### `LinearGradient` fade overlays

```swift
LinearGradient(
    colors: [fadeColor.opacity(0.7), fadeColor.opacity(0)],
    startPoint: .top,
    endPoint: .bottom
)
.frame(height: 24)
.offset(y: 24)
.allowsHitTesting(false)
```

A gradient from opaque black to transparent is placed over the message list header and footer to create the "content fades behind the input bar" effect. `.allowsHitTesting(false)` ensures the overlay does not intercept clicks meant for the message list beneath it. `.offset(y: 24)` pushes the gradient outside the header's own frame so it overlaps the messages below.

---

## 14. Markdown Renderer

**File:** `ClaudeIsland/UI/Components/MarkdownRenderer.swift`

### `swift-markdown` library (`import Markdown`)

The app uses Apple's `swift-markdown` package for parsing. `Document(parsing: text, options:)` returns an AST (Abstract Syntax Tree) of `Markup` nodes. The options `.parseBlockDirectives` and `.parseSymbolLinks` enable extended syntax beyond CommonMark.

### Document caching with `NSLock`

```swift
private final class DocumentCache: @unchecked Sendable {
    private var cache: [String: Document] = [:]
    private let lock = NSLock()

    func document(for text: String) -> Document {
        lock.lock()
        defer { lock.unlock() }
        ...
    }
}
```

Markdown parsing is expensive for long messages. `DocumentCache` memoizes parsed `Document` values by raw text. `NSLock` provides mutual exclusion because the cache may be read from multiple threads (SwiftUI renders on background threads). `@unchecked Sendable` opts out of the compiler's actor isolation checking — the manual lock provides the safety guarantee the compiler cannot verify.

### `SwiftUI.Text` concatenation for inline rendering

```swift
func asText() -> SwiftUI.Text {
    var result = SwiftUI.Text("")
    for child in children {
        result = result + renderInline(child)
    }
    return result
}
```

SwiftUI `Text` supports `+` concatenation to build attributed strings. Each inline span (`Strong`, `Emphasis`, `InlineCode`, `Link`, `Strikethrough`) is converted to a `Text` with the appropriate modifier (`.bold()`, `.italic()`, `.font(.monospaced)`, etc.) and concatenated. This produces a single `Text` view with mixed styling, which SwiftUI renders as a single attributed string — enabling proper line wrapping across style boundaries, which a `HStack` of separate `Text` views would not achieve.

---

## 15. Screen Selection

**File:** `ClaudeIsland/Core/ScreenSelector.swift`, `ClaudeIsland/UI/Components/ScreenPickerRow.swift`

### `NSScreen.screens`

`NSScreen.screens` returns an array of all currently connected displays in the order macOS assigns them. The `refreshScreens()` method re-reads this on every call, since the array is not live-updating — it must be re-queried after `NSApplication.didChangeScreenParametersNotification`.

### `NSDeviceDescriptionKey("NSScreenNumber")` → `CGDirectDisplayID`

```swift
screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
```

`deviceDescription` is an `[NSDeviceDescriptionKey: Any]` dictionary. The `"NSScreenNumber"` key is an undocumented but stable key that returns the `CGDirectDisplayID` — the integer that CoreGraphics and IOKit use to identify a display. This ID is used to match saved screen preferences to connected displays.

### Triggering window recreation via notification

```swift
NotificationCenter.default.post(
    name: NSApplication.didChangeScreenParametersNotification,
    object: nil
)
```

When the user selects a different screen in the picker, the app posts the same notification that macOS uses for real screen changes. This reuses the existing `ScreenObserver` → `WindowManager.setupNotchWindow()` path to recreate the window on the newly selected screen without duplicating logic.

### UserDefaults persistence

`selectionMode` (raw string) and `savedIdentifier` (JSON-encoded struct) are stored in `UserDefaults.standard`. `JSONEncoder`/`JSONDecoder` are used for the `ScreenIdentifier` struct because `UserDefaults` natively supports only property list types; encoding to `Data` allows any `Codable` type to be persisted.

---

## 16. Sound Selection and Playback

**File:** `ClaudeIsland/Core/Settings.swift`, `ClaudeIsland/Core/SoundSelector.swift`, `ClaudeIsland/UI/Components/SoundPickerRow.swift`

### `NSSound(named:)?.play()`

```swift
NSSound(named: soundName)?.play()
```

`NSSound(named:)` loads a system sound by name. The sound names (`"Pop"`, `"Ping"`, `"Tink"`, etc.) map to audio files in `/System/Library/Sounds/`. The optional chaining `?.play()` handles the case where the named sound does not exist gracefully. `play()` is asynchronous — it returns immediately and plays on a background audio thread.

### `UserDefaults` for sound preference

```swift
static var notificationSound: NotificationSound {
    get {
        guard let rawValue = defaults.string(forKey: Keys.notificationSound),
              let sound = NotificationSound(rawValue: rawValue) else {
            return .pop
        }
        return sound
    }
    set {
        defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
    }
}
```

`NotificationSound` is a `String` enum with `rawValue` being the sound's display name (which doubles as the `NSSound` name). Storing `rawValue` in `UserDefaults` means the preference survives app updates without a migration, as long as enum case names remain stable.

---

## 17. Session State Model

**File:** `ClaudeIsland/Models/SessionState.swift`, `ClaudeIsland/Models/SessionPhase.swift`

### `Identifiable` and `stableId`

```swift
var stableId: String {
    if let pid = pid {
        return "\(pid)-\(sessionId)"
    }
    return sessionId
}
```

SwiftUI's `ForEach` uses `Identifiable.id` to track elements for animations and diffing. Using `stableId` (combining PID and session ID) rather than just `sessionId` ensures that if a session is replaced (same sessionId, new process), SwiftUI sees it as a new element and animates its insertion rather than treating it as an update to an existing element.

### `SessionPhase` as an explicit state machine

`SessionPhase` is an enum with a `canTransition(to:)` method that encodes the valid transition graph. This is the state machine pattern from the Rule of Representation: the valid transitions are data (a lookup table in the switch statement), not imperative logic scattered across the codebase. Callers call `phase.transition(to: next)` which returns `nil` if the transition is invalid, preventing silent state corruption.

The `waitingForApproval` case carries an associated `PermissionContext` value, making the permission data inseparable from the phase that needs it — there is no separate "permission pending" flag that could get out of sync.

### `nonisolated` on value type methods

Methods on `SessionState`, `ToolTracker`, `SubagentState`, and `SessionPhase` are marked `nonisolated` to allow them to be called from any concurrency context. Since these are value types (`struct`, `enum`), each call site has its own copy — there is no shared mutable state, so concurrency is safe without actor isolation.

---

## 18. Activity Coordinator

**File:** `ClaudeIsland/Core/NotchActivityCoordinator.swift`

### `@MainActor` singleton

`NotchActivityCoordinator` is a `@MainActor` singleton accessed via `NotchActivityCoordinator.shared`. The `@MainActor` attribute ensures all mutations happen on the main thread, which is required because `@Published` properties that drive SwiftUI updates must be mutated on the main thread.

### Swift Concurrency `Task` for auto-hide timer

```swift
activityTask = Task { [weak self] in
    try? await Task.sleep(for: .seconds(self?.activityDuration ?? 3))
    guard let self = self, !Task.isCancelled else { return }
    if self.expandingActivity.type == currentType {
        self.hideActivity()
    }
}
```

`Task.sleep(for:)` is the structured concurrency equivalent of `DispatchQueue.asyncAfter`. The task is stored in `activityTask` and cancelled via `activityTask?.cancel()` when a new activity starts or the activity is manually hidden. `Task.isCancelled` is checked after the sleep to avoid executing stale hide logic. This avoids the `DispatchWorkItem` pattern's weakness of needing manual cancellation tracking — the task's cancellation is handled by the structured concurrency runtime.

### `withAnimation(.smooth)` from a non-View context

```swift
func showActivity(type: NotchActivityType, value: CGFloat = 0, duration: TimeInterval = 0) {
    withAnimation(.smooth) {
        expandingActivity = ExpandingActivity(show: true, type: type, value: value)
    }
}
```

`withAnimation` can be called from any context that modifies `@Published` state, not just from within a SwiftUI `View`. The animation is applied to any SwiftUI view that has a `.animation(_:value:)` modifier watching `expandingActivity`. The `.smooth` curve is Apple's built-in perceptually smooth spring (added in macOS 14).

---

## 19. Single-Instance Enforcement and Activation Policy

**File:** `ClaudeIsland/App/AppDelegate.swift`

### `NSWorkspace.shared.runningApplications`

```swift
let runningApps = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == bundleID
}
if runningApps.count > 1 {
    if let existingApp = runningApps.first(where: { $0.processIdentifier != getpid() }) {
        existingApp.activate()
    }
    return false
}
```

`NSWorkspace.shared.runningApplications` returns all currently running `NSRunningApplication` objects. Filtering by `bundleIdentifier` finds other instances of the same app. `getpid()` (POSIX) returns the current process's PID, allowing the new instance to identify and activate the already-running instance before terminating itself. `existingApp.activate()` brings the existing instance to the foreground.

---

## 20. Event Re-posting via CGEvent

**File:** `ClaudeIsland/UI/Window/NotchWindow.swift`, `ClaudeIsland/Core/NotchViewModel.swift`

### `CGEvent(mouseEventSource:mouseType:mouseCursorPosition:mouseButton:)` + `.post(tap:)`

```swift
let cgPoint = CGPoint(x: screenLocation.x, y: screenHeight - screenLocation.y)
if let cgEvent = CGEvent(mouseEventSource: nil, mouseType: mouseType,
                          mouseCursorPosition: cgPoint, mouseButton: mouseButton) {
    cgEvent.post(tap: .cghidEventTap)
}
```

When the notch panel closes because the user clicked outside it, or when the panel needs to forward a click through to the application behind it, a synthetic mouse event is posted via CoreGraphics. `CGEvent` is the CoreGraphics event type — it operates below AppKit's `NSEvent` level and can inject events into the HID (Human Interface Device) event stream.

The coordinate conversion `screenHeight - screenLocation.y` is required because AppKit/SwiftUI use a coordinate system with the origin at the bottom-left (Y increases upward), while CoreGraphics uses a coordinate system with the origin at the top-left (Y increases downward).

`tap: .cghidEventTap` injects the event at the HID tap point, which is the earliest point in the event processing pipeline, ensuring it reaches whichever application is under the cursor.

Accessibility permission is required for event posting. Without it, `CGEvent.post` silently fails.

---

## 21. Launch-at-Login via ServiceManagement

**File:** `ClaudeIsland/UI/Views/NotchMenuView.swift`

### `SMAppService.mainApp.register()` / `.unregister()`

```swift
try SMAppService.mainApp.register()
try SMAppService.mainApp.unregister()
```

`SMAppService` (Service Management framework, macOS 13+) is the modern API for registering an app to launch at login. It replaces the deprecated `LSSharedFileList` and `SMLoginItemSetEnabled` approaches. `mainApp` refers to the application itself (as opposed to a login item helper bundle). Registration adds the app to the user's login items, visible in System Settings → General → Login Items. `SMAppService.mainApp.status == .enabled` reads the current registration state.

---

## 22. Accessibility Permission Check

**File:** `ClaudeIsland/UI/Views/NotchMenuView.swift`

### `AXIsProcessTrusted()`

```swift
AccessibilityRow(isEnabled: AXIsProcessTrusted())
```

`AXIsProcessTrusted()` (ApplicationServices framework) returns `true` if the app has been granted accessibility permissions in System Settings → Privacy & Security → Accessibility. This permission is required for `NSEvent.addGlobalMonitorForEvents` to receive mouse events from other applications. The menu UI uses this to show the current permission state and provide a direct link to the settings pane.

```swift
if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
    NSWorkspace.shared.open(url)
}
```

`NSWorkspace.shared.open(_:)` opens the URL in the appropriate application. The `x-apple.systempreferences:` URL scheme opens System Settings to a specific pane. `NSApplication.didBecomeActiveNotification` is observed to refresh the permission status display when the user returns from System Settings after potentially granting permission.

---

## 23. Hardware Identity via IOKit

**File:** `ClaudeIsland/App/AppDelegate.swift`

### `IOServiceGetMatchingService` / `IORegistryEntryCreateCFProperty`

```swift
let platformExpert = IOServiceGetMatchingService(
    kIOMainPortDefault,
    IOServiceMatching("IOPlatformExpertDevice")
)
defer { IOObjectRelease(platformExpert) }

if let uuid = IORegistryEntryCreateCFProperty(
    platformExpert,
    kIOPlatformUUIDKey as CFString,
    kCFAllocatorDefault,
    0
)?.takeRetainedValue() as? String {
    ...
}
```

`IOKit` provides access to the hardware registry. `IOServiceMatching("IOPlatformExpertDevice")` creates a matching dictionary for the root platform device node. `IOServiceGetMatchingService` returns a handle to that node. `IORegistryEntryCreateCFProperty` reads the `IOPlatformUUID` property — the hardware UUID that is unique to each Mac and stable across reboots and OS reinstalls.

`takeRetainedValue()` consumes the +1 reference count on the `CFTypeRef` returned by the IOKit C API, bridging it into Swift's ARC system. `defer { IOObjectRelease(platformExpert) }` releases the IOKit service handle, preventing a kernel object leak.

The hardware UUID is used as a stable anonymous identifier for Mixpanel analytics, replacing the need for a random UUID that would change on app reinstall.

---

## Summary: Key Architectural Patterns

| Concern | Mechanism | Why |
|---|---|---|
| Window transparency | `NSPanel` with `isOpaque=false`, `backgroundColor=.clear` | Pixel-level alpha compositing through the window |
| Always-on-top | `level = .mainMenu + 3` | Draw above menu bar in compositor z-order |
| Click-through | `ignoresMouseEvents`, `hitTest` override | Pass clicks to applications/menu bar behind the panel |
| Multi-space visibility | `.canJoinAllSpaces`, `.stationary` | Panel persists across Space switches |
| Notch shape | `Shape` + `Path.addQuadCurve` + `animatableData` | Animated Bézier clip path |
| Hover detection | Global `NSEvent` monitor → Combine → throttled sink | System-wide mouse tracking without app focus |
| Screen change | `NSApplication.didChangeScreenParametersNotification` | Window recreation on display configuration change |
| Notch detection | `NSScreen.safeAreaInsets.top`, `auxiliaryTopLeft/RightArea` | Hardware-authoritative notch geometry |
| SwiftUI hosting | `NSHostingView` subclass with `hitTest` override | AppKit window with SwiftUI content and custom hit testing |
| State reactivity | `@MainActor ObservableObject` + `@Published` + Combine | Thread-safe main-actor state with automatic SwiftUI invalidation |
| Inverted chat scroll | `scaleEffect(y: -1)` on `ScrollView` + per-item counter-flip | Always-at-bottom layout without programmatic scroll management |
| Pixel icons | `Canvas` + `CGAffineTransform` scaling | Efficient scalable pixel art without per-pixel views |
| Markdown | `swift-markdown` AST → `Text` concatenation | Mixed-style text in a single flow layout element |
| Launch at login | `SMAppService.mainApp.register()` | Modern macOS 13+ login item API |
| Hardware ID | `IOKit` `IOPlatformUUID` | Stable anonymous identity across reinstalls |
