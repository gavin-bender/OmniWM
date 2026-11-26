// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import OmniWMSystemGestures
import Synchronization

/// Translates real AX windows. Session ownership lasts until workspace placement takes over.
@MainActor
final class LiveWorkspaceSlide {
    struct Member {
        let token: WindowToken
        let window: AXWindowRef
        let layout: CGRect
        let original: CGRect
        let parkOrigin: CGPoint
        let minimumHeight: CGFloat
        let incoming: Bool
    }

    struct HostedMember {
        let token: WindowToken
        let layout: CGRect
        let original: CGRect
        let wasVisible: Bool
        let incoming: Bool
    }

    private weak var hostedManager: ShellAppWindowManager?
    private var hostedMembers: [HostedMember]

    weak var railManager: TabRailManager?
    var outgoingRails: [TabRailInfo] = []
    var incomingRails: [TabRailInfo] = []

    typealias PositionWriter = @MainActor (Member, CGRect, Bool) -> Bool

    let members: [Member]
    private let viewport: CGRect
    private var dockSlide: DockWorkspaceSlide?
    var followsDisplayLink: Bool { dockSlide != nil }
    private var minimumHeights: [Int: CGFloat] = [:]
    private var lastFrames: [Int: CGRect] = [:]

    init(
        members: [Member], viewport: CGRect, dockDisplay: CGRect? = nil,
        hostedManager: ShellAppWindowManager? = nil, hostedMembers: [HostedMember] = [],
        writeDockPosition: @escaping PositionWriter = { member, frame, verify in
            // AppKit can animate AX position writes for enhanced-UI apps. The
            // physical move from the parking strip must finish before the reveal.
            let pid = member.token.pid
            let scope = AppAXEnhancedUIWriteScope(axApp: AXUIElementCreateApplication(pid), pid: pid, tracing: false)
            defer { _ = scope.restore() }
            return AXWindowService.setFrame(member.window, frame: frame, components: .position, verify: verify).failureReason == nil
        }
    ) {
        self.hostedManager = hostedManager
        self.hostedMembers = hostedMembers
        self.members = members
        self.viewport = viewport
        if let dockDisplay {
            dockSlide = DockWorkspaceSlide(members: members, display: dockDisplay, writePosition: writeDockPosition)
        }
    }

    /// AX constrains title bars to the top of the screen. Only the part below that edge
    /// can be presented without covering the neighboring workspace.
    static func displayedFrame(
        layout: CGRect, offset: CGVector, viewport: CGRect, parkOrigin: CGPoint, minimumHeight: CGFloat = 1
    ) -> CGRect {
        let translated = layout.offsetBy(dx: offset.dx, dy: offset.dy)
        let intersection = translated.intersection(viewport)
        guard !intersection.isNull, intersection.width >= 1, intersection.height >= 1 else {
            return CGRect(origin: parkOrigin, size: layout.size)
        }
        var frame = translated
        if offset.dy > 0 && frame.maxY > viewport.maxY {
            frame.size.height = viewport.maxY - translated.minY
            if frame.height.rounded() < minimumHeight {
                return CGRect(origin: parkOrigin, size: layout.size)
            }
        }
        return CGRect(x: frame.minX.rounded(), y: frame.minY.rounded(),
                      width: frame.width.rounded(), height: max(1, frame.height.rounded()))
    }

    static func stagingOrigin(
        for base: CGRect, targetX: CGFloat, incomingDY: CGFloat, screens: [CGRect]
    ) -> CGPoint? {
        guard incomingDY != 0, !screens.isEmpty,
              screens.allSatisfy({ $0.intersection(base).width <= FrameTolerance.frameWrite }),
              abs(base.minX - targetX) > FrameTolerance.frameWrite else { return nil }
        let desktop = screens.reduce(CGRect.null) { $0.union($1) }
        let y = incomingDY > 0 ? desktop.minY - base.height - 1 : desktop.maxY + 1
        return CGPoint(x: base.minX, y: y)
    }

    func update(source: CGVector, destination: CGVector) -> Bool {
        railManager?.presentSwipeRails(outgoingRails, offset: source, viewport: viewport)
        railManager?.presentSwipeRails(incomingRails, offset: destination, viewport: viewport)
        if let manager = hostedManager {
            for member in hostedMembers {
                let offset = member.incoming ? destination : source
                let frame = member.layout.offsetBy(dx: offset.dx, dy: offset.dy)
                let visible = viewport.intersects(frame)
                guard let window = manager.windows[member.token] else { return false }
                if visible, window.frame != frame {
                    manager.setFrame(frame, for: member.token)
                }
                if window.isVisible != visible {
                    manager.setHidden(!visible, for: member.token)
                }
            }
        }
        if let dockSlide {
            return dockSlide.update(members, source: source, destination: destination)
        }
        for member in members {
            var frame = Self.displayedFrame(
                layout: member.layout, offset: member.incoming ? destination : source,
                viewport: viewport, parkOrigin: member.parkOrigin,
                minimumHeight: minimumHeights[member.window.windowId] ?? member.minimumHeight
            )
            let previous = lastFrames[member.window.windowId] ?? member.original
            // Park at the current size before expanding. Otherwise a clipped window can
            // become full height at its old on-screen position for one compositor frame.
            if frame.origin == member.parkOrigin && previous.origin != member.parkOrigin {
                frame.size = previous.size
            }
            guard frame != previous else { continue }
            // Remember before submission so rollback covers a partial size/position write.
            lastFrames[member.window.windowId] = frame
            let result = AXWindowService.setFrame(
                member.window, frame: frame, currentFrameHint: previous,
                components: previous.size == frame.size ? .position : .all, verify: false
            )
            // Some apps silently enforce a minimum they do not expose through AXMinSize.
            // Read the accepted size after a clipped resize and stop asking for rejected sizes.
            if frame.origin != member.parkOrigin, frame.height < member.layout.height,
               previous.size != frame.size, let accepted = try? AXWindowService.frame(member.window),
               accepted.height > frame.height + FrameTolerance.frameWrite
            {
                minimumHeights[member.window.windowId] = max(member.minimumHeight, accepted.height)
                let parked = CGRect(origin: member.parkOrigin, size: accepted.size)
                let parking = AXWindowService.setFrame(
                    member.window, frame: parked, currentFrameHint: accepted, components: .position, verify: false
                )
                lastFrames[member.window.windowId] = parked
                if parking.failureReason != nil { return false }
            } else if result.failureReason != nil {
                return false
            }
        }
        return true
    }

    func finishHostedWindows(committed: Bool) {
        guard let manager = hostedManager else { return }
        for member in hostedMembers {
            let visible = committed ? member.incoming : member.wasVisible
            if !visible { manager.setHidden(true, for: member.token) }
            manager.setFrame(committed ? member.layout : member.original, for: member.token)
            if visible { manager.setHidden(false, for: member.token) }
        }
        hostedMembers.removeAll()
    }

    func adoptPlacedWindows(in controller: WMController, destination: WorkspaceSwipePresentation.Workspace) {
        for member in members where member.incoming {
            guard let entry = controller.workspaceManager.entry(for: member.token),
                  entry.workspaceId == destination.id, entry.axRef == member.window,
                  let actual = try? AXWindowService.frame(member.window),
                  actual.approximatelyEqual(to: member.layout, tolerance: FrameTolerance.frameWrite)
            else { continue }
            let ax = controller.axManager
            ax.unsuppressFrameWrites([(member.token.pid, member.window.windowId)])
            ax.clearParkPending(for: member.window.windowId, pid: member.token.pid)
            ax.markWindowActive(member.window.windowId)
            if entry.hiddenState?.workspaceInactive == true {
                controller.withRuntimeFrameJobCancellationSuppressed {
                    controller.workspaceManager.setHiddenState(nil, for: member.token)
                }
            }
            ax.confirmFrameWrite(for: member.window.windowId, frame: actual)
        }
    }

    var translatedMembers: [Member] {
        guard let dockSlide else { return [] }
        return members.filter { dockSlide.owns(UInt32($0.window.windowId)) }
    }

    func beginLanding() -> Task<Void, Never>? {
        dockSlide?.beginLanding(members)
    }

    func ownsTranslation(for id: Int) -> Bool {
        dockSlide?.owns(UInt32(id)) == true
    }

    func restore(keepingIncomingPlacement: Bool, retryPark: (Member) -> Void) -> [Member] {
        finishHostedWindows(committed: keepingIncomingPlacement)
        var unparked: [Member] = []
        let unresolved = dockSlide?.restore(keepingIncomingPlacement: keepingIncomingPlacement, unparked: &unparked) ?? []
        for member in unparked { retryPark(member) }
        dockSlide = nil
        for member in members {
            guard let last = lastFrames[member.window.windowId] else { continue }
            _ = AXWindowService.setFrame(
                member.window, frame: member.original, currentFrameHint: last,
                components: last.size == member.original.size ? .position : .all, verify: false
            )
        }
        lastFrames.removeAll()
        return members.filter { unresolved.contains(UInt32($0.window.windowId)) }
    }
}

extension WorkspaceSwipePresentation {
    func beginLiveSlide(_ flight: Flight, tracksGesture: Bool = true) -> Bool {
        guard let controller, let refreshController, flights[flight.preparation.monitor.id] == nil, participantsAreCurrent(flight) else { return false }

        let monitor = flight.preparation.monitor
        let hideSide = refreshController.preferredHideSide(for: monitor)
        var members: [LiveWorkspaceSlide.Member] = []
        var hosted: [LiveWorkspaceSlide.HostedMember] = []
        for (workspace, incoming) in [(flight.preparation.source, false), (flight.destination, true)] {
            for item in workspace.items {
                guard let entry = controller.workspaceManager.entry(for: item.handle) else { return false }
                if let metadata = entry.target.hostedMetadata {
                    // AppKit moves attached windows with their parent.
                    guard metadata.role.parent == nil else { continue }
                    guard let window = controller.shellAppWindowManager.windows[item.token] else { return false }
                    hosted.append(.init(token: item.token, layout: item.frame, original: window.frame,
                                        wasVisible: window.isVisible, incoming: incoming))
                    continue
                }
                guard AXIsProcessTrusted(), let window = entry.axRef,
                      let original = try? AXWindowService.frame(window) else { return false }
                let constraints = refreshController.destinationConstraints(for: item.token, on: monitor)
                let isFixed = constraints.isFixed || (flight.axis == .vertical && AXWindowService.sizeSettable(window) == false)
                let minimumHeight = isFixed ? original.height : constraints.minSize.height
                guard let parkOrigin = refreshController.liveFrameHideOrigin(
                    for: original, monitor: monitor, side: hideSide, reason: .workspaceInactive
                ) else { return false }
                members.append(.init(token: item.token, window: window, layout: item.frame, original: original,
                                     parkOrigin: parkOrigin, minimumHeight: minimumHeight, incoming: incoming))
            }
        }
        auditRetiredSlides()
        guard members.allSatisfy({ pendingSlideResets[$0.token] == nil }) else { return false }
        for member in members { retiredSlideWindows[member.token] = nil }
        flight.liveSlide = LiveWorkspaceSlide(
            members: members, viewport: flight.preparation.frame, dockDisplay: flight.axis == .vertical ? monitor.frame : nil,
            hostedManager: controller.shellAppWindowManager, hostedMembers: hosted
        )
        flight.liveSlide?.railManager = controller.tabRailManager
        flight.liveSlide?.outgoingRails = flight.preparation.source.items.compactMap(\.tabRail)
        flight.liveSlide?.incomingRails = flight.destination.items.compactMap(\.tabRail)
        install(flight, after: nil, tracksGesture: tracksGesture)
        if (flight.isKeyboard || flight.liveSlide?.followsDisplayLink == true || flight.motion.target != nil),
           !activateDisplayLink(for: flight) {
            cancel(flight, reason: "display-link-unavailable")
            return false
        }
        present(flight, at: mediaTimeProvider())
        if flight.isKeyboard, isCurrent(flight) {
            focusIncomingWindow(for: flight)
            flight.motion.animateToDestination(startTime: mediaTimeProvider(), motion: controller.motionPolicy.snapshot())
            flight.phase = .settling
        }
        return isCurrent(flight)
    }

    func retrySlideResets() {
        for (token, window) in pendingSlideResets {
            if controller?.workspaceManager.entry(for: token)?.axRef != window ||
                omniwm_dock_slide_restore_translation(UInt32(window.windowId)) {
                pendingSlideResets[token] = nil
            }
        }
    }

    @discardableResult
    func finishLiveSlide(_ slide: LiveWorkspaceSlide, keepingIncomingPlacement: Bool = false) -> Bool {
        let translated = slide.translatedMembers
        let unresolved = slide.restore(keepingIncomingPlacement: keepingIncomingPlacement) { member in
            guard let controller, let refreshController,
                  let entry = controller.workspaceManager.entry(for: member.token), let window = entry.axRef,
                  sameAXWindowIdentity(window, member.window), let monitor = controller.workspaceManager.monitor(for: entry.workspaceId),
                  controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id != entry.workspaceId
            else { return }
            controller.axManager.markParkPending(for: entry.windowId, pid: entry.pid)
            refreshController.hideWindow(entry, monitor: monitor, side: refreshController.preferredHideSide(for: monitor),
                                         reason: .workspaceInactive)
        }
        guard !translated.isEmpty else { return unresolved.isEmpty }
        for member in translated { retiredSlideWindows[member.token] = member.window }
        for member in unresolved { pendingSlideResets[member.token] = member.window }
        scheduleSlideAudit()
        return unresolved.isEmpty
    }

    func scheduleSlideAudit() {
        guard !retiredSlideWindows.isEmpty else { return }
        slideAuditTask?.cancel()
        slideAuditTask = Task { [weak self] in
            // Start the quiet interval at the last placement, not the last compositor
            // gesture. An app can update its drawing position after several later switches.
            for delay in [80, 200, 650] {
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                self?.auditRetiredSlides()
            }
        }
    }

    func auditRetiredSlides() {
        for (token, window) in retiredSlideWindows {
            guard controller?.workspaceManager.entry(for: token)?.axRef == window else {
                retiredSlideWindows[token] = nil
                pendingSlideResets[token] = nil
                continue
            }
            var base = CGRect.zero
            var matrix = CGAffineTransform.identity
            guard omniwm_dock_slide_geometry(UInt32(window.windowId), &base, &matrix) else { continue }
            guard matrix.a == 1, matrix.b == 0, matrix.c == 0, matrix.d == 1 else {
                // A different effect has acquired this window.
                retiredSlideWindows[token] = nil
                pendingSlideResets[token] = nil
                continue
            }
            if !omniwm_dock_slide_at_position(matrix, base.origin) {
                pendingSlideResets[token] = window
            }
        }
        retrySlideResets()
    }

    func movingLiveWindow(_ id: UInt32) -> Bool {
        flights.values.contains { flight in
            !flight.committing && flight.liveSlide?.members.contains { $0.window.windowId == Int(id) } == true
        }
    }
}

/// Owns only translations installed by this flight. A foreign scaling effect (such as
/// picture-in-picture) keeps the workspace on the ordinary Accessibility renderer.
@MainActor
private final class DockWorkspaceSlide {
    private var bases: [UInt32: CGRect] = [:]
    private var positions: [UInt32: CGPoint] = [:]
    private var ownedWindows: Set<UInt32> = []
    private var landing: DockSlideLanding?

    private let display: CGRect
    private var needsStaging = true
    private var stagedIncoming: [LiveWorkspaceSlide.Member] = []
    private var pendingStages: [UInt32: (targetX: CGFloat, deadline: ContinuousClock.Instant)] = [:]

    private let writePosition: LiveWorkspaceSlide.PositionWriter

    init?(members: [LiveWorkspaceSlide.Member], display: CGRect, writePosition: @escaping LiveWorkspaceSlide.PositionWriter) {
        self.writePosition = writePosition
        self.display = ScreenCoordinateSpace.toWindowServer(rect: display)
        guard !members.isEmpty, omniwm_dock_slide_available() else { return nil }
        for member in members {
            let id = UInt32(member.window.windowId)
            var base = CGRect.zero
            var matrix = CGAffineTransform.identity
            guard omniwm_dock_slide_geometry(id, &base, &matrix),
                  base.width >= 1, base.height >= 1,
                  base.width.rounded() == base.width, base.height.rounded() == base.height,
                  (base.width / (base.width / base.height)).rounded(.towardZero) == base.height,
                  omniwm_dock_slide_at_position(matrix, base.origin) else { return nil }
            bases[id] = base
        }
    }

    func update(_ members: [LiveWorkspaceSlide.Member], source: CGVector, destination: CGVector) -> Bool {
        if needsStaging {
            needsStaging = false
            guard stageIncoming(members, incomingDY: destination.dy - source.dy) else { return false }
        }
        var moves: [OmniWMDockSlideMove] = []
        for member in members {
            let id = UInt32(member.window.windowId)
            guard var base = bases[id] else { return false }
            var currentBase = CGRect.zero
            var currentMatrix = CGAffineTransform.identity
            guard omniwm_dock_slide_geometry(id, &currentBase, &currentMatrix) else { return false }
            if let stage = pendingStages[id] {
                // AX can acknowledge its move a frame before WindowServer changes the
                // base. Keep this surface offscreen while the other windows start moving.
                let clampedX = max(display.minX, min(stage.targetX, display.maxX - base.width))
                if currentBase != base, currentBase.size == base.size,
                   min(abs(currentBase.minX - stage.targetX), abs(currentBase.minX - clampedX)) <= FrameTolerance.frameWrite,
                   let previous = positions[id] {
                    let shifted = CGPoint(x: previous.x + currentBase.minX - base.minX,
                                          y: previous.y + currentBase.minY - base.minY)
                    if [shifted, previous, currentBase.origin].contains(where: { omniwm_dock_slide_at_position(currentMatrix, $0) }) {
                        base = currentBase
                        bases[id] = currentBase
                        positions[id] = CGPoint(x: -currentMatrix.tx, y: -currentMatrix.ty)
                        pendingStages[id] = nil
                    }
                }
                if pendingStages[id] != nil {
                    guard ContinuousClock.now < stage.deadline else { return false }
                    continue
                }
            }
            guard currentBase == base else { return false }
            let atBase = omniwm_dock_slide_at_position(currentMatrix, base.origin)
            guard atBase || positions[id].map({ omniwm_dock_slide_at_position(currentMatrix, $0) }) == true else {
                return false
            }
            let offset = member.incoming ? destination : source
            let frame = ScreenCoordinateSpace.toWindowServer(rect: member.layout.offsetBy(dx: offset.dx, dy: offset.dy))
            let target = CGPoint(x: frame.minX.rounded(), y: frame.minY.rounded())
            let previous = atBase ? base.origin : (positions[id] ?? base.origin)
            guard target != previous else { continue }
            // The toggle service briefly clears a translation when updating it. Stop
            // sending moves once a window has completely passed the same display edge.
            if positions[id] != nil,
               (max(previous.y, target.y) + base.height <= display.minY ||
                min(previous.y, target.y) >= display.maxY) { continue }
            moves.append(.init(window: id, baseWidth: Float(base.width), baseHeight: Float(base.height),
                               target: target, resetFirst: !atBase, apply: target != base.origin))
        }
        guard !moves.isEmpty else { return true }
        ownedWindows.formUnion(moves.map(\.window))
        guard omniwm_dock_slide_submit(moves, moves.count) else { return false }
        for move in moves {
            positions[move.window] = move.apply ? move.target : nil
        }
        return true
    }

    /// AX moves the physical window underneath its compositor translation. A horizontal
    /// move from the parking strip at landing would briefly apply that distance twice.
    /// Move the physical window once, while its entire surface is beyond the desktop.
    private func stageIncoming(_ members: [LiveWorkspaceSlide.Member], incomingDY: CGFloat) -> Bool {
        guard incomingDY != 0 else { return true }
        let screens = NSScreen.screens.map { ScreenCoordinateSpace.toWindowServer(rect: $0.frame) }
        for member in members where member.incoming {
            let id = UInt32(member.window.windowId)
            let target = member.original.offsetBy(dx: member.layout.minX - member.original.minX, dy: 0)
            let targetX = ScreenCoordinateSpace.toWindowServer(rect: target).minX
            guard let base = bases[id], let hidden = LiveWorkspaceSlide.stagingOrigin(
                for: base, targetX: targetX, incomingDY: incomingDY, screens: screens
            ) else { continue }
            var move = OmniWMDockSlideMove(window: id, baseWidth: Float(base.width), baseHeight: Float(base.height),
                                           target: hidden, resetFirst: false, apply: true)
            ownedWindows.insert(id)
            guard omniwm_dock_slide_submit(&move, 1) else { return false }
            var observed = CGRect.zero
            var matrix = CGAffineTransform.identity
            guard omniwm_dock_slide_geometry(id, &observed, &matrix), observed == base,
                  omniwm_dock_slide_at_position(matrix, hidden) else { return false }
            stagedIncoming.append(member)
            positions[id] = hidden
            guard writePosition(member, target, false) else { return false }
            pendingStages[id] = (targetX, ContinuousClock.now + WorkspaceSwipePresentation.handoffTimeout)
        }
        return true
    }

    func owns(_ window: UInt32) -> Bool { ownedWindows.contains(window) }

    func beginLanding(_ members: [LiveWorkspaceSlide.Member]) -> Task<Void, Never> {
        let targets = members.compactMap { member -> DockSlideLanding.Target? in
            let id = UInt32(member.window.windowId)
            guard ownedWindows.contains(id), let original = bases[id] else { return nil }
            let expected = member.incoming ? member.layout : CGRect(origin: member.parkOrigin, size: member.original.size)
            return .init(id: id, original: original.origin, target: ScreenCoordinateSpace.toWindowServer(rect: expected).origin,
                         incoming: member.incoming)
        }
        let landing = DockSlideLanding()
        self.landing = landing
        let display = self.display
        return Task.detached(priority: .high) { await landing.run(targets, display: display) }
    }

    func restore(keepingIncomingPlacement: Bool, unparked: inout [LiveWorkspaceSlide.Member]) -> Set<UInt32> {
        landing?.stop()
        landing = nil
        if !keepingIncomingPlacement {
            for member in stagedIncoming {
                if !writePosition(member, member.original, true) { unparked.append(member) }
            }
        }
        stagedIncoming.removeAll()
        let unresolved = ownedWindows.filter { !omniwm_dock_slide_restore_translation($0) }
        ownedWindows.removeAll()
        return unresolved
    }
}

/// WindowServer can acknowledge an app's physical move while the main actor is still
/// submitting other windows. Retire that window's relative translation at acknowledgement.
private final class DockSlideLanding: Sendable {
    struct Target: Sendable {
        let id: UInt32
        let original: CGPoint
        let target: CGPoint
        let incoming: Bool
    }

    private let stopped = Mutex(false)

    func stop() {
        stopped.withLock { $0 = true }
    }

    func run(_ targets: [Target], display: CGRect) async {
        var remaining = targets
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(250)
        while !remaining.isEmpty, clock.now < deadline {
            remaining.removeAll { window in
                stopped.withLock { stopped in
                    // Serialize the check and the write with teardown. A previous
                    // landing must never clear the next gesture's translation.
                    guard !stopped else { return true }
                    var actual = CGRect.zero
                    var matrix = CGAffineTransform.identity
                    guard omniwm_dock_slide_geometry(window.id, &actual, &matrix) else { return false }
                    let atTarget = abs(actual.minX - window.target.x) <= FrameTolerance.frameWrite &&
                        abs(actual.minY - window.target.y) <= FrameTolerance.frameWrite
                    let moved = actual.origin != window.original
                    let visible = actual.intersection(display).width > FrameTolerance.frameWrite
                    guard atTarget || (moved && visible == window.incoming) else { return false }
                    return omniwm_dock_slide_at_position(matrix, actual.origin) ||
                        omniwm_dock_slide_restore_translation(window.id)
                }
            }
            if !remaining.isEmpty {
                do { try await Task.sleep(for: .microseconds(500)) } catch { return }
            }
        }
    }
}
