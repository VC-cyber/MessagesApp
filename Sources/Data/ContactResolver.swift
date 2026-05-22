//
//  ContactResolver.swift
//  BetterMessages
//
//  Reads the macOS AddressBook databases (potentially multiple — one per
//  Source, e.g. iCloud + On-My-Mac) and builds a `[Handle: Contact]` lookup
//  table. Mirrors the Python `build_name_map()` in the reference scripts.
//
//  Path pattern:
//    ~/Library/Application Support/AddressBook/Sources/<UUID>/AddressBook-v22.abcddb
//
//  Schema bits we care about:
//    ZABCDRECORD       (Z_PK, ZFIRSTNAME, ZLASTNAME)
//    ZABCDPHONENUMBER  (ZOWNER → ZABCDRECORD.Z_PK, ZFULLNUMBER)
//    ZABCDEMAILADDRESS (ZOWNER → ZABCDRECORD.Z_PK, ZADDRESS)
//
//  Merging:
//    Multiple Source DBs can list the same person (the iCloud one will
//    typically have everything; the local one might add a few). We merge
//    by display name — two records with the same first+last name combine
//    their handle sets.
//

import Foundation
import GRDB

public struct ResolvedContacts: Sendable {

    /// Lookup map: normalized handle -> contact. A single contact can appear
    /// multiple times in the values (one per handle it owns).
    public let byHandle: [Handle: Contact]

    /// All unique contacts, sorted by display name.
    public let allContacts: [Contact]

    public init(byHandle: [Handle: Contact], allContacts: [Contact]) {
        self.byHandle = byHandle
        self.allContacts = allContacts
    }

    /// Lookup convenience. Returns nil for unknown handles — callers should
    /// fall back to the raw handle string for display.
    public func contact(for handle: Handle) -> Contact? {
        byHandle[handle]
    }

    /// Resolve a raw handle string. Returns the contact name if known, the
    /// raw string if not.
    public func name(forRawHandle raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "(unknown)" }
        if let c = byHandle[Handle(raw: raw)] {
            return c.displayName
        }
        return raw
    }
}

public enum ContactResolver {

    /// Glob the default AddressBook Sources directory for v22 databases.
    public static func defaultDatabaseURLs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sourcesRoot = home.appending(path: "Library/Application Support/AddressBook/Sources",
                                         directoryHint: .isDirectory)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: sourcesRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        return entries.compactMap { dir -> URL? in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            let candidate = dir.appending(path: "AddressBook-v22.abcddb",
                                          directoryHint: .notDirectory)
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }
    }

    /// Build the lookup. Silently skips Source DBs that fail to open
    /// (matches Python reference's tolerant behavior — one broken Source
    /// shouldn't kill contact resolution for the rest).
    public static func resolve(databaseURLs: [URL]? = nil) -> ResolvedContacts {
        let urls = databaseURLs ?? defaultDatabaseURLs()

        // contactsByName accumulates handle sets per display-name.
        var contactsByName: [String: Set<Handle>] = [:]

        for dbURL in urls {
            var config = Configuration()
            config.readonly = true
            guard let queue = try? DatabaseQueue(path: dbURL.path, configuration: config) else {
                continue
            }
            // SQL mirrors the Python reference — left-join phones AND emails;
            // we'll get one row per (person, phone, email) cross-product, which
            // is fine since we deduplicate via Set<Handle>.
            let rows: [Row] = (try? queue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT r.ZFIRSTNAME, r.ZLASTNAME, p.ZFULLNUMBER, e.ZADDRESS
                    FROM ZABCDRECORD r
                    LEFT JOIN ZABCDPHONENUMBER p ON p.ZOWNER = r.Z_PK
                    LEFT JOIN ZABCDEMAILADDRESS e ON e.ZOWNER = r.Z_PK
                """)
            }) ?? []

            for row in rows {
                let first: String? = row["ZFIRSTNAME"]
                let last: String? = row["ZLASTNAME"]
                let phone: String? = row["ZFULLNUMBER"]
                let email: String? = row["ZADDRESS"]

                let nameParts = [first, last].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let displayName = nameParts.joined(separator: " ")
                guard !displayName.isEmpty else { continue }

                if let phone, !phone.isEmpty {
                    let h = Handle(raw: phone)
                    // Drop handles whose normalization produced nothing useful.
                    if !h.normalized.isEmpty && h.normalized != " " {
                        contactsByName[displayName, default: []].insert(h)
                    }
                }
                if let email, !email.isEmpty {
                    let h = Handle(raw: email)
                    if !h.normalized.isEmpty {
                        contactsByName[displayName, default: []].insert(h)
                    }
                }
            }
        }

        // Materialize contacts and the reverse map.
        var contacts: [Contact] = []
        var byHandle: [Handle: Contact] = [:]
        for (name, handles) in contactsByName {
            let c = Contact(displayName: name, handles: handles)
            contacts.append(c)
            for h in handles {
                // Last-writer wins for collision: if two distinct contacts
                // claim the same handle, the second one shows up. In practice
                // this is vanishingly rare and almost always means duplicate
                // entries for the same person across Sources.
                byHandle[h] = c
            }
        }
        contacts.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        return ResolvedContacts(byHandle: byHandle, allContacts: contacts)
    }
}
