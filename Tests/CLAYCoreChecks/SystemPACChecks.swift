import Foundation
@_spi(Checks) import CLAYCore

private final class PACPreferencesFixture: SystemPACBackend, SystemPACSession {
    enum Failure: Error { case commit, apply, unexpected(String, Int) }
    static let primary = SystemPACService(id: "wifi", name: "Wi-Fi", isPrimary: true)
    static let secondary = SystemPACService(id: "wired", name: "Ethernet", isPrimary: false)
    static let marker = "ProxyAutoConfigURLString"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clay-system-pac-" + UUID().uuidString)
    var choices = [primary, secondary]
    var persisted: [String: [String: Any]] = ["wifi": [:], "wired": [:]]
    var active = Set<String>()
    var writes: [String] = []
    var journalBeforeWrite = false
    var failCommit = false
    var failApply = false
    var delayApply = false
    var interactive: Bool?

    deinit { try? FileManager.default.removeItem(at: directory) }

    func withLocked<T>(interactive: Bool, _ body: (any SystemPACSession) throws -> T) throws -> T {
        self.interactive = interactive
        return try body(self)
    }
    func services() -> [SystemPACService] { choices }
    func preferences(serviceID: String) throws -> [String: Any]? { persisted[serviceID] }
    func commit(_ values: [String: Any], serviceID: String) throws {
        journalBeforeWrite = FileManager.default.fileExists(atPath: directory.appendingPathComponent("backup-v1.plist").path)
        writes.append(serviceID)
        if failCommit { throw Failure.commit }
        persisted[serviceID] = values
    }
    func apply() throws {
        if failApply { throw Failure.apply }
        if delayApply { return }
        active = Set(persisted.values.compactMap { values in
            guard (values["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true else { return nil }
            return values[Self.marker] as? String
        })
    }
    func activePACURLs(serviceID: String) -> Set<String> { active }
    func effectivePACURLs() -> Set<String> { active }
}

extension CoreTests {
    @MainActor func testSystemPACRecovery() throws {
        let older = URL(string: "http://127.0.0.1:7788/first.pac")!
        let newer = URL(string: "http://127.0.0.1:7789/second.pac")!
        let marker = PACPreferencesFixture.marker
        let original = "https://original.example.test/proxy.pac"
        let external = "https://external.example.test/proxy.pac"

        func require(_ condition: Bool, _ description: String, line: Int = #line) throws {
            guard condition else { throw PACPreferencesFixture.Failure.unexpected(description, line) }
        }
        func simulate(_ body: (PACPreferencesFixture, SystemPACManager) throws -> Void) throws {
            let fixture = PACPreferencesFixture()
            let manager = SystemPACManager(backend: fixture, journalDirectory: fixture.directory)
            try body(fixture, manager)
        }
        func expectRecovery(_ write: () throws -> Void) throws {
            do {
                try write()
                throw PACPreferencesFixture.Failure.unexpected("write should require explicit recovery", #line)
            } catch SystemPACError.recoveryRequired {}
        }

        try simulate { fixture, manager in
            let baseline: [String: Any] = [marker: original, "HTTPEnable": 1, "HTTPSEnable": 1, "SOCKSEnable": 1,
                                           "ProxyAutoDiscoveryEnable": 1, "HTTPProxy": "proxy.example.test", "ExceptionsList": ["localhost"]]
            fixture.persisted["wired"] = baseline
            let service = try manager.enable(url: older, serviceID: "wired")
            try require(service == PACPreferencesFixture.secondary && fixture.writes == ["wired"], "only the chosen service is changed")
            try require(fixture.journalBeforeWrite, "rollback journal written first")
            let permissions = try FileManager.default.attributesOfItem(atPath: fixture.directory.appendingPathComponent("backup-v1.plist").path)[.posixPermissions] as? NSNumber
            try require(permissions?.intValue == 0o600, "rollback journal is user-private")
            let adjusted = fixture.persisted["wired"] ?? [:]
            try require(adjusted[marker] as? String == older.absoluteString && adjusted["ProxyAutoConfigEnable"] as? Int == 1, "PAC URL and enable flag set")
            for key in ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoDiscoveryEnable"] {
                try require(adjusted[key] as? Int == 0, "existing conflicting proxy disabled")
            }
            try require(adjusted["HTTPProxy"] as? String == baseline["HTTPProxy"] as? String, "dormant proxy address preserved")
            try require(adjusted["ExceptionsList"] as? [String] == ["localhost"], "proxy exception list preserved")
            let outcome = try manager.restore(interactive: false)
            try require(outcome == .restored && fixture.interactive == false, "restore uses caller's interaction policy")
            try require(NSDictionary(dictionary: fixture.persisted["wired"] ?? [:]).isEqual(to: baseline), "restore exact original settings, including absent keys")
            let pending = try manager.pendingRecovery()
            try require(pending == nil && !manager.needsListener(at: older), "restoration relinquishes ownership")
        }

        try simulate { fixture, manager in
            fixture.persisted["wifi"] = ["HTTPEnable": 1, "SOCKSEnable": 1]
            let selected = try manager.enable(url: older)
            try require(selected == PACPreferencesFixture.primary, "default selects the primary network service")
            fixture.persisted["wifi"]?["HTTPEnable"] = 2
            fixture.persisted["wifi"]?["ProxyAutoConfigEnable"] = 0
            fixture.persisted["wifi"]?["ExceptionsList"] = ["other.example.test"]
            let outcome = try manager.restore()
            try require(outcome == .restored, "URL ownership survives edits to other settings")
            let restored = fixture.persisted["wifi"] ?? [:]
            try require(restored["HTTPEnable"] as? Int == 2 && restored["ProxyAutoConfigEnable"] as? Int == 0, "overlapping external edits preserved")
            try require(restored["ExceptionsList"] as? [String] == ["other.example.test"], "unrelated external edits preserved")
            try require(restored["SOCKSEnable"] as? Int == 1 && restored[marker] == nil, "remaining CLAY-owned changes are restored")
        }

        try simulate { fixture, manager in
            fixture.delayApply = true
            try manager.enable(url: older)
            try require(manager.managedService == PACPreferencesFixture.primary && !manager.isEffective(url: older),
                        "committed preferences do not prove system PAC has taken effect")
            fixture.delayApply = false
            try fixture.apply()
            try require(manager.isEffective(url: older) && !manager.isEffective(url: newer),
                        "status follows the exact owned URL in the effective settings")
            fixture.active = [external]
            try require(!manager.isEffective(url: older) && manager.needsListener(at: older),
                        "an inactive system PAC is reported without discarding ownership or the recovery journal")
            try require(fixture.writes.count == 1, "status checks never change configured values")
            try manager.restore()
        }

        try simulate { fixture, manager in
            try manager.enable(url: older)
            fixture.persisted["wifi"] = [marker: external, "ProxyAutoConfigEnable": 1, "HTTPEnable": 1]
            let outcome = try manager.restore()
            try require(outcome == .externallyChanged && fixture.writes.count == 1, "external takeover avoids writes")
            try require(fixture.persisted["wifi"]?[marker] as? String == external && fixture.active.contains(external), "external URL takes effect")
            try require(!manager.needsListener(at: older), "external takeover releases local endpoint")
        }

        for failureBeforeCommit in [true, false] {
            try simulate { fixture, manager in
                fixture.persisted["wifi"] = [marker: original, "ProxyAutoConfigEnable": 1, "HTTPEnable": 1]
                try manager.enable(url: older)
                fixture.failCommit = failureBeforeCommit
                fixture.failApply = !failureBeforeCommit
                try expectRecovery { try manager.update(url: newer) }
                try require(manager.needsListener(at: older) && manager.needsListener(at: newer), "ambiguous update retains both endpoints")
                try require(fixture.persisted["wifi"]?[marker] as? String == (failureBeforeCommit ? older.absoluteString : newer.absoluteString), "fixture simulates either persisted endpoint")
                let restart = SystemPACManager(backend: fixture, journalDirectory: fixture.directory)
                let pending = try restart.pendingRecovery()
                try require(pending == PACPreferencesFixture.primary && fixture.writes.count == 2, "relaunch detects pending recovery without writing")
                try require(restart.needsListener(at: older) && restart.needsListener(at: newer), "persisted journal remembers both ownership markers")
                fixture.failCommit = false; fixture.failApply = false
                let outcome = try restart.restore()
                try require(outcome == .restored, "recovery works for either installed URL")
                try require(fixture.persisted["wifi"]?[marker] as? String == original && fixture.active == [original], "original address restored to persistent and live configuration")
            }
        }

        try simulate { fixture, manager in
            try manager.enable(url: older)
            try manager.update(url: newer)
            try require(!manager.needsListener(at: older) && manager.needsListener(at: newer), "confirmed update releases old listener")
            fixture.failApply = true
            do {
                _ = try manager.restore()
                throw PACPreferencesFixture.Failure.unexpected("restore apply should fail", #line)
            } catch PACPreferencesFixture.Failure.apply {}
            try require(fixture.persisted["wifi"]?.isEmpty == true && fixture.active == [newer.absoluteString], "simulated restore commits but remains live")
            try require(manager.needsListener(at: newer), "failed apply keeps ownership and listener")
            fixture.failApply = false
            let outcome = try manager.restore()
            try require(outcome == .restored && fixture.active.isEmpty && fixture.writes.count == 3, "retry applies committed restore without rewriting settings")
        }

        for externallyChanged in [false, true] {
            try simulate { fixture, manager in
                try manager.enable(url: older)
                if externallyChanged {
                    fixture.persisted["wifi"] = [marker: external, "ProxyAutoConfigEnable": 1, "HTTPEnable": 1]
                }
                let expectedWrites = externallyChanged ? 1 : 2
                fixture.delayApply = true
                do {
                    _ = try manager.restore()
                    throw PACPreferencesFixture.Failure.unexpected("restore should wait for the effective PAC to change", #line)
                } catch SystemPACError.restorationPending {}
                let pending = try manager.pendingRecovery()
                try require(pending == PACPreferencesFixture.primary && manager.needsListener(at: older),
                            "successful Apply with a stale PAC retains the journal and listener")
                try require(fixture.active == [older.absoluteString] && fixture.writes.count == expectedWrites,
                            "restore never overwrites an external PAC while propagation is pending")
                fixture.delayApply = false
                try fixture.apply()
                let outcome = try manager.restore()
                try require(outcome == (externallyChanged ? .externallyChanged : .restored), "settled retry reports the original restore outcome")
                try require(fixture.writes.count == expectedWrites && !manager.needsListener(at: older),
                            "retry releases the listener without rewriting preferences")
                let cleared = try manager.pendingRecovery()
                try require(cleared == nil, "retry clears the journal only after the owned URL is inactive")
            }
        }

        try simulate { fixture, manager in
            fixture.choices = [PACPreferencesFixture.secondary]
            do {
                _ = try manager.enable(url: older)
                throw PACPreferencesFixture.Failure.unexpected("expected service selection", #line)
            } catch SystemPACError.chooseService {}
            let pending = try manager.pendingRecovery()
            try require(fixture.writes.isEmpty && pending == nil, "no silent service fallback or writes")
            fixture.failCommit = true
            try expectRecovery { try manager.enable(url: older, serviceID: "wired") }
            fixture.failCommit = false
            let outcome = try manager.restore()
            try require(fixture.writes.count == 1 && outcome == .noBackup, "uninvolved settings remain intact after failed initial commit")
        }
    }
}
