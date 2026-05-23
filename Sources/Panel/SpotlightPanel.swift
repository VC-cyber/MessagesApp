import SwiftUI

/// The compact, Spotlight-style search surface. Hosted inside `SpotlightNSPanel`
/// by `PanelController`. Composes design-agent's existing components.
///
/// Layout: single column. Hero search field at top, results list below.
/// No sidebar — that's the browse window's job.
struct SpotlightPanel: View {
    @Bindable var viewModel: SearchViewModel
    @Bindable var recentSearches: RecentSearchesStore
    let dismiss: () -> Void

    @State private var selectedResultID: Int64?
    @State private var suggestionIndex: Int = 0

    /// Whether the help-syntax sheet is currently overlaid on the panel.
    /// Triggered by the `?` button in the footer or `⌘/`.
    @State private var showHelp: Bool = false

    /// Example queries that crossfade through the placeholder slot while
    /// the search field is empty and unfocused. Each example demonstrates
    /// a different filter category so a user idling over the panel learns
    /// the grammar by osmosis.
    ///
    /// The "Try:" prefix makes it unambiguously a hint, not the user's
    /// own text. We keep the list small (5 entries, ~20s cycle) so a user
    /// hovering on the panel briefly sees variety without being
    /// overwhelmed.
    static let placeholderExamples: [String] = [
        "Try: cactus from:Mom",
        "Try: type:image last:30d",
        "Try: reactions:>=3",
        "Try: vacation+flight",
        "Try: chat:family last:1y",
    ]

    /// Parsed view of the current query — recomputed on every render. The
    /// parser is microseconds-fast and this keeps every derived view (chips,
    /// recognized-tokens hint, suggestion eligibility) in lockstep without
    /// any separate state to sync.
    private var parsedQuery: MessageSearch.ParsedQuery {
        MessageSearch.parseQuery(viewModel.query, contacts: nil)
    }

    /// Per-token chip representation. Each chip's label is the literal token
    /// substring (e.g. `chat:amme`) so removing a chip can scrub the matching
    /// substring from `viewModel.query` deterministically.
    ///
    /// **Design note**: tokens stay as literal text inside the search field
    /// AND as chips outside it. This is intentional — chips give a glanceable
    /// "what is this search actually doing" summary; the literal text keeps
    /// the field round-trippable (paste a query out, paste it back in).
    /// See `docs/design-notes.md` § "Inline filter feedback".
    private var filters: [SearchField.ActiveFilter] {
        var out: [SearchField.ActiveFilter] = []
        for token in parsedQuery.tokens {
            let literal = "\(token.prefix.rawValue)\(quoteIfNeeded(token.value))"
            let category: FilterCategory
            switch token.prefix.category {
            case .chat: category = .chat
            case .person: category = .person
            case .date: category = .dateRange
            case .reaction: category = .reaction
            case .type: category = .type
            }
            out.append(.init(category: category, label: literal))
        }
        return out
    }

    /// Quote a value if it contains whitespace (so the chip label reads
    /// faithfully as the on-the-wire token text).
    private func quoteIfNeeded(_ value: String) -> String {
        value.contains(where: { $0.isWhitespace }) ? "\"\(value)\"" : value
    }

    /// Remove the token whose label matches `chipLabel` from the query. We
    /// scan token-by-token rather than doing a string `.replacingOccurrences`
    /// so we don't accidentally clobber a matching substring inside free text.
    private func removeFilter(label chipLabel: String) {
        let parsed = MessageSearch.parseQuery(viewModel.query, contacts: nil)
        for token in parsed.tokens {
            let literal = "\(token.prefix.rawValue)\(quoteIfNeeded(token.value))"
            guard literal == chipLabel else { continue }
            var newQuery = viewModel.query
            newQuery.removeSubrange(token.range)
            // Collapse the double-space we may have left behind.
            viewModel.query = newQuery.replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return
        }
    }

    /// The current autocomplete context derived from the query. When `nil`,
    /// the suggestions popover hides and arrow keys go back to the result
    /// list (or stay in the text field as caret motion — SwiftUI handles).
    private var autocompleteContext: AutocompleteContext? {
        QueryAutocomplete.analyze(query: viewModel.query)
    }

    /// The suggestions for the current context, if any.
    private var suggestions: [QuerySuggestion] {
        guard let ctx = autocompleteContext else { return [] }
        return QuerySuggestionsProvider.suggestions(
            for: ctx,
            contacts: viewModel.allContacts,
            chats: viewModel.allChats
        )
    }

    /// Reveal the given result in Messages.app and dismiss the panel.
    ///
    /// Routing:
    /// - **GUID-based path** (`MessagesGUIDReveal`) — preferred. Uses
    ///   `sms://open?groupid=...` to open 1:1 or group chats, AX-scrolls the
    ///   bubble into view, then synthesizes ⌘F + ⌘V + ↵ for the highlight.
    /// - **Legacy fallback** (`MessagesReveal`) — only if the message or chat
    ///   GUID is missing (shouldn't normally happen post-plumbing).
    private func reveal(_ result: MessageSearch.Result) {
        // Opening a result is the strongest "this search was useful" signal —
        // commit it to recents so the user can re-run it later from the
        // empty state.
        recentSearches.record(viewModel.query)
        if let messageGUID = result.message.guid,
           let chatGUID = result.chatGUID {
            // GUID path runs async; fire-and-forget so the panel can dismiss
            // immediately instead of overlaying Messages.app during the scroll.
            Task { @MainActor in
                _ = await MessagesGUIDReveal.reveal(
                    messageGUID: messageGUID,
                    chatGUID: chatGUID,
                    body: result.message.body,
                    senderName: result.senderName,
                    isFromMe: result.message.isFromMe,
                    messageDate: result.message.date
                )
            }
        } else {
            _ = MessagesReveal.reveal(result)
        }
        dismiss()
    }

    /// The result currently highlighted (selected or, if none, the first).
    /// Used by the Enter key to know which row to open.
    private var currentSelection: MessageSearch.Result? {
        if let id = selectedResultID,
           let hit = viewModel.results.first(where: { $0.message.id == id }) {
            return hit
        }
        return viewModel.results.first
    }

    /// Apply the highlighted suggestion to the query. Hides the popover
    /// implicitly by completing the token (no partial prefix left).
    private func acceptSuggestion(_ suggestion: QuerySuggestion) {
        guard let ctx = autocompleteContext else { return }
        let (newQuery, _) = QueryAutocomplete.apply(
            suggestion: suggestion.value,
            to: viewModel.query,
            in: ctx
        )
        // Trailing space — user wants to keep typing the next filter.
        viewModel.query = newQuery + " "
        suggestionIndex = 0
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchField(
                text: $viewModel.query,
                caseSensitive: $viewModel.caseSensitive,
                placeholder: "Search messages",
                rotatingExamples: SpotlightPanel.placeholderExamples
            )
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.lg)
            .padding(.bottom, filters.isEmpty ? Space.md : Space.xs)
            .onSubmit {
                // Enter handling:
                // - Popover open → accept the highlighted suggestion.
                // - Else if a result is highlighted → reveal in Messages.app.
                // - Else → run the search immediately (skip debounce) and
                //   record the query as a recent (the user committed to
                //   it by pressing Enter, even if no result was opened).
                if !suggestions.isEmpty {
                    let idx = max(0, min(suggestionIndex, suggestions.count - 1))
                    acceptSuggestion(suggestions[idx])
                } else if let pick = currentSelection {
                    reveal(pick)
                } else {
                    recentSearches.record(viewModel.query)
                    Task { await viewModel.search() }
                }
            }
            // Keyboard navigation. We must consume these so they don't
            // bubble to the text field (where ↑/↓ would move caret/cursor).
            .onKeyPress(.upArrow) {
                if !suggestions.isEmpty {
                    suggestionIndex = max(0, suggestionIndex - 1)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.downArrow) {
                if !suggestions.isEmpty {
                    suggestionIndex = min(suggestions.count - 1, suggestionIndex + 1)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.tab) {
                if !suggestions.isEmpty {
                    let idx = max(0, min(suggestionIndex, suggestions.count - 1))
                    acceptSuggestion(suggestions[idx])
                    return .handled
                }
                return .ignored
            }
            // Active filter chips — derived from the parsed query, NOT a
            // separate state slot. The user sees the same tokens twice (as
            // literal text in the field, and as removable chips here) — the
            // chips are the "what filters are active" affordance, the literal
            // text keeps the query round-trippable (copy-paste-share).
            if !filters.isEmpty {
                activeFiltersRow
                    .padding(.horizontal, Space.lg)
                    .padding(.bottom, Space.sm)
                    .transition(.opacity)
            }

            // Suggestions take over the content area while the user is
            // actively typing a recognized token (`chat:am`, `from:m`, …).
            // Once the token is accepted or the user moves on, results return.
            // This is the standard search-autocomplete pattern (Spotlight,
            // browser address bar) — inline, not a floating modal.
            if !suggestions.isEmpty {
                Divider().opacity(0.3)
                inlineSuggestionsList
                    .transition(.opacity)
            } else if let setupError = viewModel.setupError {
                accessDeniedState(message: setupError)
            } else if viewModel.isSearching {
                loadingState
            } else if viewModel.results.isEmpty {
                emptyState
            } else {
                Divider().opacity(0.3)
                resultsList
            }

            footer
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 360, idealHeight: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        // The help overlay sits on top of the panel content. Tapping a
        // token snippet inside the sheet inserts it into the query, fires
        // the search, and dismisses — turning the cheatsheet into a
        // launchpad as well as a reference.
        .overlay {
            if showHelp {
                HelpSheet(
                    onClose: { withAnimation(.bmDefault) { showHelp = false } },
                    onInsert: { example in
                        viewModel.query = example
                        Task { await viewModel.search() }
                        withAnimation(.bmDefault) { showHelp = false }
                    }
                )
                .padding(Space.sm)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                .zIndex(1)
            }
        }
        .onChange(of: viewModel.query) { _, _ in
            // Debounce — 150ms after last keystroke. Search is exhaustive and
            // can take a moment on broad queries; debouncing keeps typing
            // responsive without truncating results.
            viewModel.searchSoon()
            // Reset selection any time the query changes — otherwise a stale
            // index might point past the end of a now-shorter suggestion list.
            suggestionIndex = 0
        }
        .onChange(of: viewModel.caseSensitive) { _, _ in
            // Toggling the Aa pill must re-run the search — both code paths
            // (case-sensitive GLOB vs default LIKE+INSTR) produce different
            // result sets for the same query string.
            viewModel.searchSoon()
        }
        .onExitCommand {
            // Escape: close the help sheet if open, otherwise dismiss the
            // panel. Layered escape matches Spotlight/Raycast behavior.
            if showHelp {
                withAnimation(.bmDefault) { showHelp = false }
            } else {
                dismiss()
            }
        }
        // ⌘/ — the keyboard convention for "open help". Toggles the sheet
        // so users who learn the shortcut don't have to mouse over to the
        // ? button every time.
        .background {
            Button("Toggle help") {
                withAnimation(.bmDefault) { showHelp.toggle() }
            }
            .keyboardShortcut("/", modifiers: [.command])
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    /// Horizontally-scrolling row of `FilterChip` pills, one per recognized
    /// token. Sits between the search field and the results, becomes visible
    /// only when at least one token is recognized.
    private var activeFiltersRow: some View {
        GlassEffectContainer(spacing: 18) {
            HStack(spacing: Space.xs) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                ForEach(filters) { filter in
                    FilterChip(
                        category: filter.category,
                        label: filter.label,
                        onDismiss: {
                            withAnimation(.bmGlassMorph) {
                                removeFilter(label: filter.label)
                            }
                        }
                    )
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.6).combined(with: .opacity),
                            removal: .scale(scale: 0.6).combined(with: .opacity)
                        )
                    )
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: Space.xs) {
                ForEach(viewModel.results, id: \.message.id) { result in
                    SpotlightResultRow(
                        result: result,
                        isSelected: selectedResultID == result.message.id,
                        onTap: { selectedResultID = result.message.id }
                    )
                    // Double-click → open the chat in Messages.app and dismiss.
                    // `simultaneousGesture` so the row's single-click selection
                    // still fires for the first of the two clicks.
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded { reveal(result) }
                    )
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
        }
    }

    /// Inline autocomplete — sits in the content area while the user is typing
    /// a recognized token. Reuses the existing `QuerySuggestionsPopover` view
    /// (its visual styling is fine; it just doesn't need to be floating).
    private var inlineSuggestionsList: some View {
        QuerySuggestionsPopover(
            suggestions: suggestions,
            selectedIndex: suggestionIndex,
            onSelect: acceptSuggestion,
            onHover: { suggestionIndex = $0 }
        )
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var loadingState: some View {
        VStack(spacing: Space.md) {
            ProgressView()
                .controlSize(.large)
            Text("Searching…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.xl)
    }

    private var emptyState: some View {
        VStack(spacing: Space.lg) {
            if viewModel.query.isEmpty {
                // Empty-field state: show the magnifier, the recents
                // (if any), and the quick-filter suggestions. Recents
                // come first because they're personalized — a returning
                // user immediately sees something they've done before,
                // not a generic affordance.
                VStack(spacing: Space.xs) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Search your messages")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !recentSearches.entries.isEmpty {
                    RecentSearchesList(
                        entries: recentSearches.entries,
                        onSelect: applyRecentSearch,
                        onRemove: { recentSearches.remove($0) }
                    )
                }

                EmptyStateSuggestions(onSelect: applyQuickFilter)
            } else {
                // Non-empty field but no results — the search ran and
                // produced nothing. Keep this terse; the next commit will
                // add intelligent "try this instead" rescue suggestions.
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No matches.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.xl)
    }

    /// Re-run a saved query. We set `query` verbatim (no trailing space —
    /// the user committed to this exact string before) and fire the search
    /// immediately. The query is also re-recorded which moves it to the
    /// top of the list (the implicit "use again to bump" behavior).
    private func applyRecentSearch(_ query: String) {
        viewModel.query = query
        recentSearches.record(query)
        Task { await viewModel.search() }
    }

    /// Apply a quick-filter pill to the query field and fire the search.
    ///
    /// Implementation: we just set `viewModel.query` to the token (with a
    /// trailing space so the user can keep typing free text after it if
    /// they want — feels natural since the autocomplete popover does the
    /// same thing on accept). The `.onChange(of: query)` handler kicks off
    /// the debounced search automatically, but we also call `search()`
    /// directly so the user doesn't have to wait the debounce window for a
    /// pill they just clicked.
    private func applyQuickFilter(_ suggestion: EmptyStateSuggestion) {
        viewModel.query = suggestion.token + " "
        Task { await viewModel.search() }
    }

    private func accessDeniedState(message: String) -> some View {
        VStack(spacing: Space.md) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.orange)
            Text("Full Disk Access required")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Grant Full Disk Access") {
                openFullDiskAccessSettingsAndRevealApp()
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            Text("Drag Better Messages from Finder into the Full Disk Access list, then relaunch.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.xl)
    }

    private var footer: some View {
        HStack(spacing: Space.md) {
            footerHint(icon: "return", text: "Preview")
            footerHint(icon: "arrow.up.arrow.down", text: "Navigate")
            footerHint(icon: "escape", text: "Dismiss")
            Spacer()
            Text("\(viewModel.results.count) results")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            helpToggleButton
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .background(.thinMaterial)
    }

    /// `?` button in the footer — opens the help sheet. Sits to the right
    /// of the result count so it's discoverable without competing with the
    /// keyboard-hint glyphs on the left.
    private var helpToggleButton: some View {
        Button {
            withAnimation(.bmDefault) { showHelp.toggle() }
        } label: {
            // `.tertiary` is a HierarchicalShapeStyle while Color.accentColor
            // is a Color — use a Color-typed adapter for the off state so
            // the ternary type-checks.
            Image(systemName: showHelp ? "questionmark.circle.fill" : "questionmark.circle")
                .font(.caption)
                .foregroundStyle(showHelp ? Color.accentColor : Color.secondary.opacity(0.6))
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.plain)
        .help("Search syntax (⌘/)")
    }

    private func footerHint(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(.tertiary)
    }
}

/// Compact result row tailored for the spotlight panel. Distinct from the
/// browse window's `ResultRow` because the panel has tighter density.
private struct SpotlightResultRow: View {
    let result: MessageSearch.Result
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: Space.md) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.xs) {
                        Text(result.senderName)
                            .font(.subheadline.weight(.semibold))
                        if !result.partnerName.isEmpty, result.partnerName != result.senderName {
                            Text("· \(result.partnerName)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        // Reaction cluster sits on the trailing edge, BEFORE the
                        // timestamp — keeps timestamp at the far edge as the
                        // anchor element, with reactions clustering toward it.
                        if !result.reactions.isEmpty {
                            ReactionCluster(reactions: result.reactions)
                        }
                        Text(timestamp)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    // Body line: real text if we have any, otherwise a typed
                    // placeholder so attachment-only messages aren't blank.
                    // (`messageType` is .text for plain-text rows — only the
                    // empty-body non-text case shows the placeholder, so rows
                    // with both body AND attachment still display the text.)
                    if result.message.body.isEmpty && result.messageType != .text {
                        Label(result.messageType.displayLabel,
                              systemImage: result.messageType.sfSymbol)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(result.message.body)
                            .font(.callout)
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .background(
                RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var avatar: some View {
        AvatarView(
            imageData: result.senderAvatar,
            initials: initials,
            size: 28,
            tint: .secondary.opacity(0.4)
        )
    }

    private var initials: String {
        let parts = result.senderName.split(separator: " ").prefix(2)
        return parts.compactMap(\.first).map(String.init).joined()
    }

    private var timestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: result.message.date)
    }
}
