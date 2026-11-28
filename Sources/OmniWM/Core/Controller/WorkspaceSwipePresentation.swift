// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

@MainActor
final class WorkspaceSwipePresentation {
    weak var refreshController: LayoutRefreshController?
    var preparation: Preparation?
    private(set) var flights: [Monitor.ID: Flight] = [:]
    private weak var gestureFlight: Flight?
    var pendingSlideResets: [WindowToken: AXWindowRef] = [:]
    var retiredSlideWindows: [WindowToken: AXWindowRef] = [:]
    var slideAuditTask: Task<Void, Never>?
    private var captureFreeContact: (flight: Flight, animateAfter: TimeInterval)?
    private static let repeatedSwipeInterval: TimeInterval = 0.25
    private var lastLiveRelease: [Monitor.ID: TimeInterval] = [:]
    private var chainMonitorId: Monitor.ID?
    private var latestSerial = 0
    private var latestGestureMonitorId: Monitor.ID?
    private var focusOwed = false
    var previews: [Monitor.ID: WorkspaceSwipePreview] = [:]
    var unclaimedPreview: WorkspaceSwipePreview?
    let previewFactory: (@MainActor (WMController) -> WorkspaceSwipePreview)?
    let mediaTimeProvider: () -> TimeInterval
    var handoffWindowInfo: @MainActor (Set<UInt32>) async throws -> [UInt32: WindowServerInfo]? = {
        try await SkyLight.shared.queryWindowInfoDeferred(windowIds: $0)
    }

    var handoffSleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    init(
        refreshController: LayoutRefreshController,
        previewSurface: WorkspaceSwipePreview? = nil,
        previewFactory: (@MainActor (WMController) -> WorkspaceSwipePreview)? = nil,
        mediaTimeProvider: @escaping () -> TimeInterval = CACurrentMediaTime
    ) {
        self.refreshController = refreshController
        unclaimedPreview = previewSurface
        self.previewFactory = previewFactory
        self.mediaTimeProvider = mediaTimeProvider
    }

    var controller: WMController? {
        refreshController?.controller
    }

    var flight: Flight? {
        gestureFlight.flatMap { isCurrent($0) ? $0 : nil }
    }

    var hasPresentation: Bool {
        !flights.isEmpty || captureFreeContact != nil
    }

    func hasDisplayWork(_ displayId: CGDirectDisplayID) -> Bool {
        flights.values.contains { hasDisplayWork($0, displayId) }
    }

    private func hasDisplayWork(_ flight: Flight, _ displayId: CGDirectDisplayID) -> Bool {
        flight.preparation.monitor.displayId == displayId
            && (!flight.committing || flight.animatesAfterCommit && !flight.motionFinished)
            && (flight.motion.target != nil || flight.carry != nil || flight.liveSlide?.followsDisplayLink == true)
    }

    func prepare(monitorId: Monitor.ID, timestamp: TimeInterval) -> Bool {
        gestureFlight = nil
        captureFreeContact = nil
        guard let controller, controller.motionPolicy.animationsEnabled else { return false }
        let mediaTime = mediaTimeProvider()
        let existing = flights[monitorId]
        if let existing, existing.committing || existing.motion.target == 1 {
            chainMonitorId = monitorId
            return false
        }
        chainMonitorId = nil
        if let existing, !existing.committing,
           existing.motion.target != nil, existing.motion.catchMotion(
               cumulativeUnits: 0, timestamp: timestamp, animationTime: mediaTime
           )
        {
            existing.progress = existing.motion.progress(at: mediaTime)
            existing.phase = .tracking
            gestureFlight = existing
            trace("caught", progress: existing.progress)
            return true
        }
        if let existing { cancel(existing, reason: "new-contact") }
        preparation = nil
        guard let preparation = makePreparation(monitorId: monitorId) else {
            stopPreparing()
            trace("fallback-geometry")
            return false
        }
        self.preparation = preparation
        if controller.settings.captureFreeWorkspaceSwipes { return false }
        let surface = previewSurface(controller, for: monitorId)
        surface.captureSource(monitor: preparation.monitor, workingFrame: preparation.frame)
        surface.warm(
            source: preparation.source.items,
            destination: (preparation.previous?.items ?? []) + (preparation.next?.items ?? []),
            monitor: preparation.monitor, workingFrame: preparation.frame
        )
        return false
    }

    @discardableResult
    func begin(
        axis: WorkspaceSwipeAxis, cumulative: Double, timestamp: TimeInterval,
        recognitionMovement: SwipeEvent? = nil, directTouch: Bool = false
    ) -> Bool {
        guard let controller, controller.motionPolicy.animationsEnabled else { return false }
        let (preparation, predecessor) = beginPreparation()
        guard let preparation,
              let isNext = TrackpadGestureIntent.isNextWorkspace(
                  axis: axis, displacement: cumulative, naturalDirection: controller.settings.gestures.invertDirection
              ),
              let destination = (isNext ? preparation.next : preparation.previous)
              ?? createdDestination(isNext: isNext, from: preparation),
              destination.id != preparation.source.id
        else {
            guard let predecessor else { return false }
            return refuseOrFallBack(from: predecessor, axis: axis, cumulative: cumulative)
        }
        if controller.settings.captureFreeWorkspaceSwipes {
            predecessor?.queuedShortcut = nil
            let flight = Flight(preparation: preparation, destination: destination, axis: axis, cumulative: cumulative,
                                isNext: isNext, timestamp: timestamp, recognitionMovement: recognitionMovement,
                                directTouch: directTouch, captureFree: true)
            let monitorId = preparation.monitor.id
            // Start an isolated drag immediately. For overlapping swipes, wait for the
            // preceding placement to finish, then join the gesture at its current position.
            let animateAfter = lastLiveRelease[monitorId].map { $0 + Self.repeatedSwipeInterval } ?? timestamp
            captureFreeContact = (flight, animateAfter)
            _ = update(cumulative: cumulative, timestamp: timestamp)
            return true
        }
        let preview = previewSurface(controller, for: preparation.monitor.id)
        if let predecessor,
           let handled = handOff(from: predecessor, into: preparation, toward: destination, using: preview)
        {
            return handled
        }
        if self.preparation == nil {
            self.preparation = preparation
            preview.warm(
                source: preparation.source.items, destination: destination.items,
                monitor: preparation.monitor, workingFrame: preparation.frame
            )
        }
        let flight = Flight(
            preparation: preparation,
            destination: destination,
            axis: axis,
            cumulative: cumulative,
            isNext: isNext,
            timestamp: timestamp,
            recognitionMovement: recognitionMovement
        )
        guard participantsAreCurrent(flight) else {
            if predecessor != nil { preview.stop() }
            trace("fallback-participants")
            return false
        }
        guard predecessor != nil || show(preview, for: flight) else {
            trace("fallback-preview-unavailable")
            return false
        }
        install(flight, after: predecessor)
        controller.surfaceReconciler.reconcileNow()
        present(flight, at: mediaTimeProvider())
        return true
    }

    @discardableResult
    func update(cumulative: Double, timestamp: TimeInterval) -> Bool {
        if let contact = captureFreeContact {
            let tracked = contact.flight
            tracked.motion.update(cumulativeUnits: cumulative * tracked.inputSign, timestamp: timestamp)
            if timestamp >= contact.animateAfter, flights[tracked.preparation.monitor.id] == nil,
               participantsAreCurrent(tracked) {
                // A rejected window set should not run AX discovery on every input frame.
                captureFreeContact = (tracked, .infinity)
                if beginLiveSlide(tracked) { captureFreeContact = nil }
            }
            return true
        }
        guard let flight, !flight.committing, flight.motion.target == nil else { return false }
        guard participantsAreCurrent(flight), controller?.motionPolicy.animationsEnabled == true else {
            if flight.liveSlide != nil, controller?.motionPolicy.animationsEnabled == true {
                flight.motion.update(cumulativeUnits: cumulative * flight.inputSign, timestamp: timestamp)
                liveRendererInterrupted(flight, reason: "live-participants-changed")
            } else {
                cancel(flight, reason: "invalidated")
            }
            return true
        }
        flight.motion.update(cumulativeUnits: cumulative * flight.inputSign, timestamp: timestamp)
        if flight.liveSlide?.followsDisplayLink != true { present(flight, at: mediaTimeProvider()) }
        return true
    }

    @discardableResult
    func release(timestamp: TimeInterval, allowFlick: Bool) -> Bool {
        if let contact = captureFreeContact {
            captureFreeContact = nil
            let monitor = contact.flight.preparation.monitor.id
            lastLiveRelease[monitor] = timestamp
            guard contact.flight.motion.release(timestamp: timestamp, allowFlick: allowFlick,
                                                animationTime: mediaTimeProvider()),
                  contact.flight.motion.target == 1 else { return true }
            // Finish any older live ownership before ordinary workspace navigation.
            if let previous = flights[monitor] {
                if !previous.committing, previous.motion.target == 1 { commit(previous) }
                if isCurrent(previous) { cancel(previous, reason: "rapid-switch") }
            }
            if controller?.workspaceManager.activeWorkspaceOrFirst(on: monitor)?.id == contact.flight.preparation.source.id {
                controller?.workspaceNavigationHandler.switchWorkspaceBySwipe(isNext: contact.flight.isNext, monitorId: monitor)
            }
            scheduleSlideAudit()
            return true
        }
        guard let flight, !flight.committing else { return false }
        guard flight.motion.release(
            timestamp: timestamp, allowFlick: allowFlick, animationTime: mediaTimeProvider(),
            motion: controller?.motionPolicy.snapshot() ?? .enabled
        ) else {
            cancel(flight, reason: "invalid-release")
            return true
        }
        if flight.liveSlide != nil { lastLiveRelease[flight.preparation.monitor.id] = timestamp }
        flight.phase = .settling
        if !activateDisplayLink(for: flight) {
            if flight.liveSlide != nil { liveRendererInterrupted(flight, reason: "display-link-unavailable") }
            else { cancel(flight, reason: "display-link-unavailable") }
            return true
        }
        if flight.motion.target == 1 { focusIncomingWindow(for: flight) }
        prefetchChainTargets(after: flight)
        return true
    }

    /// Release window ownership independently of the user's decision to switch.
    func liveRendererInterrupted(_ flight: Flight, reason: String) {
        guard isCurrent(flight), let slide = flight.liveSlide, !flight.committing else { return }
        if flight.motion.target == 1 {
            // An AX renderer can fail halfway through a write. Restore its windows
            // before ordinary layout performs the committed switch.
            finishLiveSlide(slide)
            flight.liveSlide = nil
            commit(flight)
        } else {
            let keepContact = self.flight === flight && flight.motion.target == nil
            cancel(flight, reason: reason)
            if keepContact { captureFreeContact = (flight, .infinity) }
        }
    }

    func activateDisplayLink(for flight: Flight) -> Bool {
        if refreshController?
            .displayLinkActivationForTests?(flight.preparation.monitor.displayId) == true { return true }
        guard let link = refreshController?.getOrCreateDisplayLink(for: flight.preparation.monitor.displayId) else {
            return false
        }
        link.add(to: .main, forMode: .common)
        return true
    }

    func otherGestureRecognized(on monitorId: Monitor.ID) {
        noteNewestGesture(on: monitorId)
        guard chainMonitorId == nil else {
            chainMonitorId = nil
            return
        }
        cancel(reason: "other-gesture")
    }

    func noteSwitchWithoutPresentation(on monitorId: Monitor.ID) {
        noteNewestGesture(on: monitorId)
    }

    func forgetNewestGesture(onDisplay displayId: CGDirectDisplayID) {
        guard latestGestureMonitorId?.displayId == displayId else { return }
        let survivor = flights.values.max { $0.serial < $1.serial }
        latestGestureMonitorId = survivor?.preparation.monitor.id
        if let survivor { latestSerial = survivor.serial }
    }

    private func noteNewestGesture(on monitorId: Monitor.ID) {
        latestSerial += 1
        latestGestureMonitorId = monitorId
    }

    func tick(displayId: CGDirectDisplayID, timestamp: TimeInterval) {
        for flight in flights.values where hasDisplayWork(flight, displayId) {
            guard participantsAreCurrent(flight), controller?.motionPolicy.animationsEnabled == true else {
                if flight.liveSlide != nil, controller?.motionPolicy.animationsEnabled == true {
                    liveRendererInterrupted(flight, reason: "live-participants-changed")
                } else {
                    cancel(flight, reason: "invalidated")
                }
                continue
            }
            // Keep the source stationary until WindowServer observes the last
            // staging move. Keyboard input has no drag position to catch up to.
            if flight.isKeyboard, let slide = flight.liveSlide, slide.isStaging, flight.phase == .settling {
                present(flight, at: timestamp)
                if isCurrent(flight), flight.liveSlide === slide, !slide.isStaging {
                    revealIncomingWindows(for: flight)
                    focusIncomingWindow(for: flight)
                    flight.motion.startDestinationSpring(at: timestamp, motion: controller?.motionPolicy.snapshot() ?? .enabled)
                }
                continue
            }
            // Hand the last few points to the real window placement. The toggle-based
            // compositor would otherwise expose old frames while chasing a subpixel spring.
            if flight.liveSlide?.followsDisplayLink == true, flight.phase == .settling,
               let target = flight.motion.target,
               abs(target - flight.progress) * flight.stride <= 3,
               abs(target - flight.motion.progress(at: timestamp)) * flight.stride <= 3 {
                if target == 1 { commit(flight) } else { cancel(flight, reason: "cancelled") }
                continue
            }
            present(flight, at: timestamp)
            if isCurrent(flight), flight.motion.target != nil, flight.motion.isComplete(at: timestamp) {
                if flight.committing {
                    finishKeyboardMotion(flight)
                } else if flight.motion.target == 1 {
                    commit(flight)
                } else {
                    cancel(flight, reason: "cancelled")
                }
            }
        }
    }

    func stopPreparing(warm: Bool = false) {
        chainMonitorId = nil
        guard flight == nil else { return }
        preparation = nil
        for (monitorId, preview) in previews where flights[monitorId] == nil {
            preview.stop()
        }
        if warm {
            refreshController?.collectUnusedWorkspacesIfIdle()
            warmPreviews()
        }
    }
}

extension WorkspaceSwipePresentation {
    private func beginPreparation() -> (Preparation?, predecessor: Flight?) {
        guard let chainMonitorId else { return (preparation, nil) }
        self.chainMonitorId = nil
        if let existing = flights[chainMonitorId] {
            return (makePreparation(monitorId: chainMonitorId, chainedSource: existing.destination), existing)
        }
        return (preparation ?? makePreparation(monitorId: chainMonitorId), nil)
    }

    private func show(_ preview: WorkspaceSwipePreview, for flight: Flight) -> Bool {
        let preparation = flight.preparation
        guard preview.begin(
            source: preparation.source.items,
            destination: flight.destination.items,
            monitor: preparation.monitor,
            workingFrame: preparation.frame
        ) else { return false }
        preview.prepare(
            source: preparation.source.items,
            destination: flight.destination.items,
            monitor: preparation.monitor,
            workingFrame: preparation.frame
        )
        return true
    }

    func install(_ flight: Flight, after predecessor: Flight?, tracksGesture: Bool = true) {
        let monitor = flight.preparation.monitor
        refreshController?.stopScrollAnimation(for: monitor.displayId)
        refreshController?.stopDwindleAnimation(for: monitor.displayId)
        if let predecessor {
            flight.chained = true
            flight.carry = { predecessor.residual(at: $0) }
            _ = activateDisplayLink(for: flight)
        }
        noteNewestGesture(on: monitor.id)
        flight.serial = latestSerial
        flights[monitor.id] = flight
        if tracksGesture { gestureFlight = flight }
        trace(predecessor == nil ? "began" : "chained", for: flight)
    }

    func cancel(reason: String) {
        if captureFreeContact != nil {
            captureFreeContact = nil
            return
        }
        guard let flight else {
            stopPreparing()
            return
        }
        cancel(flight, reason: reason)
    }

    func cancelAll(reason: String) {
        captureFreeContact = nil
        lastLiveRelease.removeAll()
        focusOwed = false
        for flight in Array(flights.values) {
            cancel(flight, reason: reason, settlingFocus: false)
        }
        stopPreparing()
        auditRetiredSlides()
    }

    // A renderer can release its window transforms before the workspace switch commits.
    // Transfer the bars only once the active workspace is known, before uncovering it.
    private func settleTabRails(for flight: Flight) {
        guard let controller else { return }
        let rails = flight.preparation.source.items.compactMap(\.tabRail) + flight.destination.items.compactMap(\.tabRail)
        guard !rails.isEmpty else { return }
        controller.surfaceReconciler.finishSwipeRails(rails)
    }

    func cancel(_ flight: Flight, reason: String, keepingPreview: Bool = false, settlingFocus: Bool = true) {
        let monitorId = flight.preparation.monitor.id
        guard flights[monitorId] === flight else { return }
        flight.landingTask?.cancel()
        flight.landingTask = nil
        if let slide = flight.liveSlide {
            let committed = flight.committing && controller?.workspaceManager.activeWorkspace(on: monitorId)?.id == flight.destination.id
            finishLiveSlide(slide, keepingIncomingPlacement: committed)
        }
        flight.liveSlide = nil
        flights[monitorId] = nil
        restoreFocusIfSlideAborted(flight)
        flight.handoff?.cancel()
        flight.settlement?.onChange = nil
        controller?.axManager.workspaceFrameSettlements.removeAll { $0 === flight.settlement }
        if !keepingPreview {
            settleTabRails(for: flight)
            previews[monitorId]?.stop()
        }
        if preparation?.monitor.id == monitorId { preparation = nil }
        trace(reason, progress: flight.progress)
        controller?.surfaceReconciler.noteWorldChanged()
        refreshController?.stopDisplayLinkIfIdle(for: flight.preparation.monitor.displayId)
        if settlingFocus, flight.serial == latestSerial, !flight.committing, reason != "chained",
           focusOwed || flights.values.contains(where: { $0.preparation.monitor.id != monitorId })
        {
            settleOwedFocus(on: flight.preparation.monitor)
        }
        if ["completed", "placement-failed", "handoff-unconfirmed", "cancelled"].contains(reason) {
            refreshController?.collectUnusedWorkspacesIfIdle()
            warmPreviews()
        }
    }

    func checkSettlement() {
        for flight in Array(flights.values) {
            guard flight.committing, let settlement = flight.settlement, settlement.isSettled else { continue }
            if settlement.tokens.contains(where: {
                refreshController?.hasPendingRevealTransaction(for: $0.windowId) == true
            }) { continue }
            confirmHandoff(flight)
        }
    }

    func didSubmitPlacement() {
        guard let flight else { return }
        didSubmitPlacement(flight)
    }

    func didSubmitPlacement(_ flight: Flight) {
        guard isCurrent(flight), flight.committing else { return }
        flight.settlement?.seal()
    }

    func commit(_ flight: Flight) {
        let monitor = flight.preparation.monitor
        guard let controller, let refreshController,
              controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
              == flight.preparation.source.id
        else {
            cancel(flight, reason: "superseded")
            return
        }
        // An interrupted spring has no final image to preserve. During a normal
        // landing keep each window at its last visible position until it is placed.
        if let slide = flight.liveSlide, slide.followsDisplayLink, abs(1 - flight.progress) > 0.025 {
            let released = finishLiveSlide(slide)
            flight.liveSlide = nil
            guard released else {
                cancel(flight, reason: "transform-release-failed")
                return
            }
        }
        let takesFocus = flight.serial == latestSerial || latestGestureMonitorId == monitor.id
        flight.phase = .committing
        previews[monitor.id]?.freezeSource()
        let settlement =
            AXFrameSettlement(tokens: Set(controller.workspaceManager.entries(in: flight.destination.id).map(\.token)))
        flight.settlement = settlement
        settlement.onChange = { [weak self] in self?.checkSettlement() }
        controller.axManager.workspaceFrameSettlements.append(settlement)
        controller.workspaceNavigationHandler.saveNiriViewportState(for: flight.preparation.source.id)
        if let slide = flight.liveSlide, let landing = slide.beginLanding() {
            flight.landingTask = Task { [weak self, weak flight] in
                await landing.value
                guard !Task.isCancelled, let self, let flight, isCurrent(flight), flight.liveSlide === slide else { return }
                finishLiveSlide(slide, keepingIncomingPlacement: true)
                flight.liveSlide = nil
            }
        }
        guard controller.workspaceManager.setActiveWorkspace(
            flight.destination.id, on: monitor.id, updateInteractionMonitor: takesFocus
        ) else {
            flight.phase = .settling
            cancel(flight, reason: "commit-failed")
            return
        }
        if flight.captureFree { settleTabRails(for: flight) }
        flight.liveSlide?.finishHostedWindows(committed: true)
        if let slide = flight.liveSlide {
            slide.adoptPlacedWindows(in: controller, destination: flight.destination)
            if !slide.followsDisplayLink { flight.liveSlide = nil }
        }
        trace(takesFocus ? "committed" : "committed-background", progress: flight.progress, for: flight)
        let placementSubmitted: LayoutRefreshController.PostLayoutAction = { [weak self, weak flight] in
            guard let self, let flight else { return }
            didSubmitPlacement(flight)
        }
        let placementInvalidated: LayoutRefreshController.PostLayoutAction = { [weak self, weak flight] in
            guard let self, let flight, isCurrent(flight) else { return }
            cancel(flight, reason: "placement-invalidated")
        }
        if takesFocus {
            focusOwed = false
            controller.workspaceNavigationHandler.commitWorkspaceTransitionFocusHandoff(
                targetWorkspaceId: flight.destination.id, monitor: monitor, startScrollAnimation: false,
                previouslyFronted: flight.earlyFocus?.target,
                placementSubmitted: placementSubmitted, placementInvalidated: placementInvalidated
            )
        } else {
            focusOwed = flights.values.contains { $0.serial > flight.serial }
            refreshController.stopScrollAnimation(for: monitor.displayId)
            refreshController.commitWorkspaceTransition(
                postLayout: placementSubmitted, postLayoutInvalidated: placementInvalidated
            )
            if !focusOwed { keepFocusOffHiddenWorkspace(flight.preparation.source.id) }
        }
        flight.phase = .waitingForPlacement
        refreshController.stopDisplayLinkIfIdle(for: monitor.displayId)
    }

    func isLandingWindow(_ id: Int) -> Bool {
        flights.values.contains { $0.committing && $0.liveSlide?.ownsTranslation(for: id) == true }
    }

    func focusIncomingWindow(for flight: Flight) {
        guard let controller, isCurrent(flight), flight.serial == latestSerial,
              flight.liveSlide?.followsDisplayLink == true, flight.earlyFocus == nil,
              controller.intentLedger.activeManagedRequest == nil,
              controller.workspaceManager.systemModalFocusToken == nil,
              let source = controller.workspaceManager.nativeManagedFocusToken,
              controller.workspaceManager.workspace(for: source) == flight.preparation.source.id,
              let target = controller.workspaceManager.resolveWorkspaceFocusToken(in: flight.destination.id),
              let item = flight.destination.items.first(where: { $0.token == target }),
              let entry = controller.workspaceManager.entry(for: item.handle),
              controller.nativeWindowHasFocus(source)
        else { return }
        flight.earlyFocus = (source, target, controller.intentLedger.newestFocusIntentId())
        if !controller.performWindowFronting(entry) { flight.earlyFocus = nil }
    }

    func isEarlyFocusTarget(_ token: WindowToken) -> Bool {
        flights.values.contains { flight in
            guard !flight.committing, let early = flight.earlyFocus, early.target == token else { return false }
            return controller?.intentLedger.newestFocusIntentId() == early.intent
        }
    }

    private func restoreFocusIfSlideAborted(_ flight: Flight) {
        guard let early = flight.earlyFocus, let controller, flight.serial == latestSerial,
              controller.workspaceManager.activeWorkspace(on: flight.preparation.monitor.id)?.id == flight.preparation.source.id,
              controller.workspaceManager.workspace(for: early.source) == flight.preparation.source.id,
              controller.isManagedWindowDisplayable(early.source),
              controller.intentLedger.newestFocusIntentId() == early.intent,
              controller.nativeWindowHasFocus(early.target)
        else { return }
        controller.focusWindow(early.source)
    }

    // Incoming windows leave their parking strip before the active workspace changes.
    // WindowServer reports this intentional move through the normal park-repair path.
    func isPresentingIncomingWindow(_ token: WindowToken) -> Bool {
        flights.values.contains { flight in
            !flight.committing && flight.liveSlide?.members.contains { $0.incoming && $0.token == token } == true
        }
    }

    private func keepFocusOffHiddenWorkspace(_ workspaceId: WorkspaceDescriptor.ID) {
        guard let controller, let monitorId = latestGestureMonitorId,
              let monitor = controller.workspaceManager.monitor(byId: monitorId),
              let token = controller.workspaceManager.nativeManagedFocusToken,
              controller.workspaceManager.entry(for: token)?.workspaceId == workspaceId
        else { return }
        settleOwedFocus(on: monitor)
    }

    private func settleOwedFocus(on monitor: Monitor) {
        focusOwed = false
        guard let controller, let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        else { return }
        trace("focus-owed")
        _ = controller.workspaceManager.setInteractionMonitor(monitor.id)
        controller.workspaceNavigationHandler.commitWorkspaceTransitionFocusHandoff(
            targetWorkspaceId: workspace.id, monitor: monitor, startScrollAnimation: false
        )
    }
}
