//
//  DashboardViewModel.swift
//  BetterMessages
//
//  Owns the Dashboard window's state and orchestrates loads against
//  `DashboardLoader`. One instance lives for the lifetime of the dashboard
//  scene; it survives close/reopen so we don't repeatedly reopen chat.db.
//
//  Loading model:
//    - When `window` flips, we kick off a fresh async load.
//    - A generation counter guards against late returns: if the user
//      switched windows again before the previous load finished, we discard
//      the stale `DashboardStats`.
//    - `setupError` captures DB-open failures (most commonly FDA not granted)
//      so the view can render a friendly empty state instead of an opaque
//      "no data" screen.
//

import Foundation
import Observation

@MainActor
@Observable
public final class DashboardViewModel {

    /// Currently displayed window.
    public var window: DashboardLoader.Window = .last30Days {
        didSet {
            guard window != oldValue else { return }
            reload()
        }
    }

    /// Latest loaded stats, or nil while loading the first time.
    public private(set) var stats: DashboardStats?

    /// True iff a load is currently in flight.
    public private(set) var isLoading: Bool = false

    /// DB open / contacts load failure. Sticky — once set, the user has to
    /// fix permissions and relaunch.
    public private(set) var setupError: String?

    /// Most recent successful load timestamp — useful for a "Last updated"
    /// hint in the UI.
    public private(set) var lastLoadedAt: Date?

    private var database: ChatDatabase?
    private var contacts: ResolvedContacts?
    private var generation: Int = 0

    public init() {}

    /// Open the chat.db + AddressBook once and trigger the first load. Safe
    /// to call multiple times — subsequent calls are no-ops if setup already
    /// succeeded.
    public func bootstrapIfNeeded() {
        guard database == nil, setupError == nil else { return }
        do {
            let db = try ChatDatabase()
            let contacts = ContactResolver.resolve()
            self.database = db
            self.contacts = contacts
            reload()
        } catch let err as ChatDatabase.OpenError {
            setupError = String(describing: err)
        } catch {
            setupError = error.localizedDescription
        }
    }

    /// Kick off a load with the current `window`. Cancels in-flight loads via
    /// the generation counter — slow returns are discarded.
    public func reload() {
        guard let database, let contacts else { return }
        let myGen = generation &+ 1
        generation = myGen
        isLoading = true
        let window = self.window

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let stats = try DashboardLoader.loadSync(
                    database: database,
                    contacts: contacts,
                    window: window
                )
                await self?.apply(stats: stats, generation: myGen)
            } catch {
                await self?.fail(message: error.localizedDescription, generation: myGen)
            }
        }
    }

    /// Apply a result on the main actor, but only if it's still current.
    private func apply(stats: DashboardStats, generation: Int) {
        guard generation == self.generation else { return }
        self.stats = stats
        self.lastLoadedAt = Date()
        self.isLoading = false
    }

    private func fail(message: String, generation: Int) {
        guard generation == self.generation else { return }
        self.setupError = message
        self.isLoading = false
    }
}
