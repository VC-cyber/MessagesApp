//
//  SearchViewModel.swift
//  BetterMessages
//
//  Observable view model that the UI (design-agent's territory) binds to.
//  Pure state holder + async search trigger; no SwiftUI views in this file.
//
//  Design contract
//  ---------------
//  - `query` is the user-typed phrase (supports `a+b` co-occurrence).
//  - `selectedContact` is the optional person filter.
//  - `dateRange` is the optional date filter.
//  - `results` is the current result set (sorted **descending** by date —
//    newest first, matching Spotlight expectations).
//  - Call `searchSoon()` to schedule a debounced search (typical for typing).
//  - Call `search()` to run immediately (Enter, submit, programmatic refresh).
//
//  Result accuracy
//  ---------------
//  Search is **exhaustive** — every matching message is returned. No silent
//  truncation. For typing latency we use a generation counter to discard
//  superseded results; the underlying `MessageSearch` engine still runs to
//  completion for each search but we ignore its output once a newer search
//  has started.
//
//  Lifecycle
//  ---------
//  - The DB and contacts list are loaded on `init`. If either fails (e.g. no
//    Full Disk Access), `setupError` carries the message and `results` stays
//    empty.
//  - We DO NOT throw from init — the UI needs to present the error gracefully.
//

import Foundation
import Observation

@Observable
@MainActor
public final class SearchViewModel {

    // MARK: - Bindable state

    public var query: String = ""
    public var selectedContact: Contact?
    public var dateRange: ClosedRange<Date>?
    /// When true, the phrase match is case-sensitive (GLOB + byte-exact INSTR
    /// instead of the default ASCII-folding LIKE + 3-variant INSTR). Driven
    /// by the `Aa` toggle in the search field.
    public var caseSensitive: Bool = false

    public private(set) var results: [MessageSearch.Result] = []
    public private(set) var allContacts: [Contact] = []
    public private(set) var allChats: [ChatInfo] = []
    public private(set) var isSearching: Bool = false
    public private(set) var errorMessage: String?
    public private(set) var setupError: String?

    /// The open ChatDatabase, exposed so panel reveal logic can use it for
    /// participant lookups. nil if the DB failed to open at init time.
    public private(set) var database: ChatDatabase?

    // MARK: - Engine (loaded lazily on init; nil if setup failed)

    private var engine: MessageSearch?

    /// Monotonic counter — incremented on every search request. A search whose
    /// generation is no longer the latest discards its result when it
    /// completes (the user has moved on to a newer query).
    private var searchGeneration: Int = 0

    /// The pending debounced search, if any. Cancelled when a newer debounced
    /// request comes in or when `search()` is called directly.
    private var debounceTask: Task<Void, Never>?

    public init() {
        do {
            let db = try ChatDatabase()
            let contacts = ContactResolver.resolve()
            self.engine = MessageSearch(database: db, contacts: contacts)
            self.allContacts = contacts.allContacts
            self.database = db
            // Enumerate chats once at startup so autocomplete has data ready.
            // Errors here are non-fatal — the search still works, autocomplete
            // for chat names just won't surface suggestions.
            if let chats = try? ChatListing.allChats(database: db, contacts: contacts) {
                self.allChats = chats
            }
        } catch let err as ChatDatabase.OpenError {
            self.setupError = String(describing: err)
        } catch {
            self.setupError = "Failed to open chat.db: \(error)"
        }
    }

    /// Schedule a debounced search — calling this repeatedly within the debounce
    /// window only fires one search (the last one). Use this for "search as
    /// you type" — it stops us hammering the DB on every keystroke without
    /// silently dropping the user's intent.
    public func searchSoon(debounceMilliseconds: Int = 150) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(debounceMilliseconds))
            guard !Task.isCancelled, let self else { return }
            await self.search()
        }
    }

    /// Run the search immediately using current `query`, `selectedContact`,
    /// and `dateRange`. Cancels any pending debounced search.
    public func search() async {
        debounceTask?.cancel()
        guard let engine else { return }

        searchGeneration += 1
        let myGen = searchGeneration

        let phrase = query
        let person = selectedContact
        let range = dateRange
        let caseSensitive = self.caseSensitive

        isSearching = true
        errorMessage = nil

        let outcome: Result<[MessageSearch.Result], Error> = await Task.detached(priority: .userInitiated) {
            do {
                let res = try engine.search(
                    phrase: phrase,
                    person: person,
                    dateRange: range,
                    caseSensitive: caseSensitive
                )
                return .success(res)
            } catch {
                return .failure(error)
            }
        }.value

        // Discard if a newer search has started. The engine call already ran
        // to completion (it's synchronous), but we don't apply stale results.
        guard searchGeneration == myGen else { return }

        switch outcome {
        case .success(let res):
            self.results = res
        case .failure(let err):
            self.results = []
            self.errorMessage = "\(err)"
        }
        self.isSearching = false
    }
}
