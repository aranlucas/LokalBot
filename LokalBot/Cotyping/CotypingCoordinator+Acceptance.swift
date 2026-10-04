import Foundation

/// Acceptance, session presentation, insertion bookkeeping, and teardown.
extension CotypingCoordinator {
    // MARK: - Acceptance (called synchronously from the accept tap)

    func acceptFromTap(_ scope: CotypingAcceptScope) -> Bool {
        guard isRunning, !discardRevokedMemoryContext() else { return false }
        if let activeVisibleContext,
           !CotypingVisibleContext.Policy(settings: settingsProvider()).permits(activeVisibleContext.target) {
            clearSuggestion()
            state = .idle
            return false
        }
        guard CotypingAcceptanceOwnershipPolicy.shouldOwnAcceptKey(
                  overlayIsVisible: overlay.isVisible,
                  hasSession: session != nil),
              var current = session else { return false }
        // The visible ghost must match the session tail — a mismatch means the
        // overlay is showing stale text and accepting would insert the wrong thing.
        guard overlay.acceptanceText == current.remainingText else {
            clearSuggestion()
            state = .idle
            return false
        }
        let live = CotypingAXHelper.resolveAcceptanceSnapshot(
            cachedField: focusTracker.focus.field)
        guard CotypingAcceptanceSnapshotPolicy.canAccept(
            markedTextState: live.markedTextState,
            composingInputModeActive: inputSourceMonitor.isComposingIMEActive,
            hasLiveContent: live.hasLiveContent,
            selectionLength: live.field?.selectionLength) else {
            clearSuggestion()
            state = .idle
            return false
        }

        // Replacements delete existing host text, so they share one exact-field
        // and exact-trigger validation path. A same-PID match is not sufficient.
        if case .continuation = current.kind {
            // Continue through the normal append-only acceptance path below.
        } else {
            guard let plan = CotypingReplacementAcceptancePlanner.plan(
                for: current,
                liveField: live.field),
                  inserter.replace(
                      deletingCharacters: plan.deletingCharacters,
                      with: plan.replacementText) else {
                clearSuggestion()
                return false
            }
            if case .correction = current.kind { acceptedWordCount += 1 }
            clearSuggestion()
            state = .idle
            return true
        }

        // Continuation: never insert into the wrong field (mouse-moved focus).
        guard CotypingSessionReconciler.isAcceptanceContinuation(
            of: current,
            liveField: live.field,
            pendingInsertionConsumedCount: pendingInsertionConsumedCount) else {
            clearSuggestion()
            return false
        }
        let remaining = current.remainingText
        guard !remaining.isEmpty else { clearSuggestion(); return false }

        let settings = settingsProvider()
        let liveField = live.field ?? current.field
        // Shared with the Settings rehearsal: one plan decides how much a
        // keypress takes and how it is spaced.
        guard let acceptance = CotypingContinuationAcceptance.plan(
            session: current,
            scope: scope,
            precedingText: liveField.precedingText,
            trailingText: liveField.trailingText,
            options: .init(settings: settings)) else { return false }
        let acceptedChunk = acceptance.acceptedChunk
        let insertionText = acceptance.insertionText
        let forwardDeleteCount = acceptance.forwardDeleteCount
        let inserted: Bool
        if insertionText.isEmpty {
            inserted = true
        } else if forwardDeleteCount > 0 {
            inserted = CotypingSyntheticEditPolicy.allowsForwardDeletion(forwardDeleteCount)
                && inserter.replaceForward(
                    deletingCharacters: forwardDeleteCount,
                    with: insertionText)
        } else {
            // The consuming event tap must remain constant-time and must never
            // touch the pasteboard or walk an app's AX menu tree. Composing
            // input sources fail open above; direct-input continuations use one
            // synthetic Unicode event pair regardless of text length or lines.
            inserted = inserter.insert(insertionText)
        }
        guard inserted else {
            clearSuggestion()
            state = .idle
            return false
        }
        lastAcceptanceAt = Date()
        noteAcceptance(field: liveField, inserted: insertionText, charsAccepted: acceptedChunk.count)
        recordAcceptedText(acceptedChunk, field: liveField, settings: settings)

        acceptedWordCount += CotypingAcceptanceChunker.acceptedWordCount(in: acceptedChunk)
        current = current.advanced(by: acceptedChunk.count)
        session = current

        if current.isExhausted {
            pendingInsertionConsumedCount = nil
            lastAcceptedTail = AcceptedSuggestionTail(text: acceptedChunk, precedingText: liveField.precedingText)
            clearSuggestion()
            state = .idle
            scheduleGenerationAfterHostPublishDelay(baseline: liveField)
        } else {
            // Re-anchor the ghost after the host commits the insert (AX lag).
            pendingInsertionConsumedCount = current.consumedCount
            let remainingText = current.remainingText
            if !overlay.advanceInline(
                to: remainingText,
                insertedText: insertionText,
                isRightToLeft: CotypingTextDirectionDetector.isRightToLeft(liveField.precedingText),
                emphasisLength: acceptEmphasisLength(for: remainingText)) {
                showOverlay(text: remainingText, field: live.field ?? current.field)
            }
            syncAcceptInterception()
            extendSuggestionIfNeeded()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(30))
                guard let self, self.overlay.isVisible, let liveSession = self.session,
                      liveSession.remainingText == remainingText else { return }
                guard !self.isAwaitingPostInsertionSync else { return }
                let focus = await self.focusTracker.refreshNow()
                if let field = focus.field {
                    let placement = self.placement(for: field)
                    if self.overlay.shouldHoldInlineReanchor(
                        text: remainingText,
                        caretRect: field.caretRect,
                        style: field.fieldStyle,
                        placement: placement,
                        millisecondsSinceLastAcceptance: self.millisecondsSinceLastAcceptance(),
                        inputFrameRect: field.inputFrameRect,
                        isRightToLeft: CotypingTextDirectionDetector.isRightToLeft(field.precedingText)) {
                        return
                    }
                    self.showOverlay(text: remainingText, field: field, placement: placement)
                    self.syncAcceptInterception()
                }
            }
        }
        return true
    }

    /// Escape while a suggestion is showing. The suggestion goes away and,
    /// unless the user chose otherwise, the key stops here, so it does not
    /// also close a dialog or leave a mode in the app, and the field stays
    /// quiet for a few seconds. Called synchronously from the accept tap.
    func dismissFromTap() -> Bool {
        guard isRunning, let current = session, overlay.isVisible else { return false }
        // A composing input method needs its own Escape.
        let takesKey = settingsProvider().cotypingEscapeBehavior == .pause
            && !inputSourceMonitor.isComposingIMEActive
        cancelPendingGenerationWork()
        clearSuggestion()
        state = .idle
        if takesKey {
            escapePause = (
                fieldAnchor: CotypingFieldIdentity.suggestionAnchor(for: current.field),
                until: Date().addingTimeInterval(CotypingEscapeBehavior.pauseSeconds))
        }
        return takesKey
    }

    /// Whether Escape put this field on hold. The hold ends on its own, and it
    /// never follows the user to another field.
    func isPausedByEscape(in field: CotypingField, now: Date = Date()) -> Bool {
        guard let pause = escapePause else { return false }
        guard now < pause.until else {
            escapePause = nil
            return false
        }
        return pause.fieldAnchor == CotypingFieldIdentity.suggestionAnchor(for: field)
    }

    func recordAcceptedText(_ text: String, field: CotypingField, settings: AppSettings) {
        acceptedSuggestionBatch.append(
            field: field, acceptedText: text,
            learningEnabled: settings.cotypingUseLocalLearning && activeMemoryContext.selection.items.isEmpty
                && activeVisibleContext == nil)
    }

    /// Atomically presents a suggestion. The invariant *session exists ⟺
    /// overlay visible ⟺ state == .ready ⟺ accept tap armed* is established
    /// here (and torn down in `clearSuggestion`) — never by hand at call sites.
    func present(
        _ newSession: CotypingSession,
        overlayText: String,
        acceptanceText: String? = nil
    ) {
        pendingInsertionConsumedCount = nil
        session = newSession
        showOverlay(text: overlayText, field: newSession.field, acceptanceText: acceptanceText)
        markReady(acceptanceText ?? overlayText)
        noteSuggestionShown(newSession)
    }

    /// The published tail of `present` — also used by the advance paths, which
    /// keep the existing overlay window and only re-arm interception + state.
    func markReady(_ text: String) {
        syncAcceptInterception()
        lastSuggestion = text
        state = .ready(text: text)
    }

    func clearSuggestion() {
        if let completed = acceptedSuggestionBatch.complete() {
            stats.suggestionCompleted()
            if let record = completed.learningRecord {
                learningStore.recordCompletedSuggestion(
                    field: record.field,
                    acceptedText: record.acceptedText)
            }
        }
        session = nil
        cancelSuggestionExtension()
        pendingInsertionConsumedCount = nil
        overlay.hide()
        syncAcceptInterception()
    }

    private func syncAcceptInterception() {
        inputMonitor.setAcceptActive(
            CotypingAcceptanceOwnershipPolicy.shouldOwnAcceptKey(
                overlayIsVisible: overlay.isVisible,
                hasSession: session != nil))
    }

    func millisecondsSinceLastAcceptance() -> Int? {
        lastAcceptanceAt.map { Int(Date().timeIntervalSince($0) * 1000) }
    }

    private var isAwaitingPostInsertionSync: Bool {
        pendingInsertionConsumedCount != nil
    }
}
