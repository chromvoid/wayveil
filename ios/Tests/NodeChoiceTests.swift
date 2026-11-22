import XCTest

final class NodeChoiceTests: XCTestCase {
    private let now: TimeInterval = 2_000_000_000

    func testCandidatesSavedFirstPausedLastDoublingResetEpisodeAndCatalog() {
        let pauses = memoryPauses()
        let catalog = NodeCatalog(label: "Access", expiresAt: 0, nodes: [node("a"), node("b"), node("c")], device: "device")
        func order(saved: String = "b", in catalog: NodeCatalog = catalog, at time: TimeInterval? = nil) -> [String] {
            let found = NodeCandidates(nodes: catalog.candidates(saved: saved, pinned: false, validAfter: 0), saved: saved, pinned: false)
            return NodeChoice.startPlan(found, pauses: pauses, now: time ?? now).nodes.map(\.id)
        }
        XCTAssertEqual(order(), ["b", "a", "c"])
        pauses.fail("b", now: now)
        XCTAssertEqual(order(), ["a", "c", "b"])
        XCTAssertEqual(order(at: now + NodeChoice.pause), ["b", "a", "c"])
        // With every node paused the one whose pause ends first goes first, the saved one too.
        pauses.fail("a", now: now + 60)
        pauses.fail("c", now: now + 30)
        XCTAssertEqual(order(), ["b", "c", "a"])
        XCTAssertEqual(order(saved: "a"), ["b", "c", "a"])

        let lengths = (0..<8).map { _ -> TimeInterval in
            pauses.fail("x", now: now)
            XCTAssertEqual(pauses["x"].map { $0.until - now }, pauses["x"]?.length)
            return pauses["x"]?.length ?? 0
        }
        XCTAssertEqual(lengths, [600, 1200, 2400, 4800, 9600, 19_200, 21_600, 21_600])
        XCTAssertTrue(pauses.paused("x", now: now + 21_599))
        XCTAssertFalse(pauses.paused("x", now: now + 21_600))

        // Ten minutes of healthy work on a node clear its pause.
        let failover = NodeFailover(pauses: pauses)
        failover.track(now: 0, node: "b", connected: true, reconnecting: false, network: true)
        failover.track(now: 599, node: "b", connected: true, reconnecting: false, network: true)
        XCTAssertNotNil(pauses["b"])
        failover.track(now: 600, node: "b", connected: true, reconnecting: false, network: true)
        XCTAssertNil(pauses["b"])
        // Another healthy node gets its own ten minutes.
        let moved = NodeFailover(pauses: pauses)
        pauses.fail("b", now: now)
        moved.track(now: 0, node: "a", connected: true, reconnecting: false, network: true)
        moved.track(now: 300, node: "b", connected: true, reconnecting: false, network: true)
        moved.track(now: 899, node: "b", connected: true, reconnecting: false, network: true)
        XCTAssertNotNil(pauses["b"])
        moved.track(now: 900, node: "b", connected: true, reconnecting: false, network: true)
        XCTAssertNil(pauses["b"])
        // A reconnect in between starts the ten minutes anew.
        let interrupted = NodeFailover(pauses: pauses)
        pauses.fail("b", now: now)
        interrupted.track(now: 0, node: "b", connected: true, reconnecting: false, network: true)
        interrupted.track(now: 300, node: "b", connected: false, reconnecting: true, network: true)
        interrupted.track(now: 400, node: "b", connected: true, reconnecting: false, network: true)
        interrupted.track(now: 999, node: "b", connected: true, reconnecting: false, network: true)
        XCTAssertNotNil(pauses["b"])
        interrupted.track(now: 1000, node: "b", connected: true, reconnecting: false, network: true)
        XCTAssertNil(pauses["b"])

        // A node is paused at most once in an episode, however often it fails there.
        failover.track(now: 700, node: "a", connected: false, reconnecting: true, network: true)
        failover.pause("a", wallNow: now)
        failover.pause("a", wallNow: now)
        XCTAssertEqual(pauses["a"]?.length, 1200)
        failover.track(now: 710, node: "a", connected: false, reconnecting: false, network: false)
        failover.pause("a", wallNow: now)
        XCTAssertEqual(pauses["a"]?.length, 1200)
        failover.track(now: 720, node: "a", connected: true, reconnecting: false, network: true)
        failover.track(now: 730, node: "a", connected: false, reconnecting: true, network: true)
        failover.pause("a", wallNow: now)
        XCTAssertEqual(pauses["a"]?.length, 2400)

        // A node gone from the fresh catalog leaves the queue, the saved one too.
        let fresh = NodeCatalog(label: "Access", expiresAt: 0, nodes: [node("a"), node("c")], device: "device")
        let freshPauses = memoryPauses()
        let found = NodeCandidates(nodes: fresh.candidates(saved: "b", pinned: false, validAfter: 0), saved: "b", pinned: false)
        XCTAssertEqual(NodeChoice.startPlan(found, pauses: freshPauses, now: now).nodes.map(\.id), ["a", "c"])
        XCTAssertEqual(NodeChoice.failoverPlan(found, current: "b", pauses: freshPauses, now: now).nodes.map(\.id), ["a", "c"])
        XCTAssertEqual(NodeChoice.failoverPlan(found, current: "a", pauses: freshPauses, now: now).nodes.map(\.id), ["c"])
    }

    func testLatencyWinsOnlyNotablyFasterOpenDirectNodes() async {
        let saved = node("saved", server: "192.0.2.1", endpoints: [endpoint("hy2", "hysteria2", "192.0.2.1")])
        let other = node("other", server: "other.example.com", endpoints: [endpoint("reality", "vless_reality", "192.0.2.2")])
        let found = NodeCandidates(nodes: [saved, other], saved: "saved", pinned: false)
        let addresses = ["other.example.com": Set(["192.0.2.2"])]
        func first(_ latencies: [String: Int], pauses: NodePauses = memoryPauses(), nodes: [CatalogNode]? = nil) -> String {
            let candidates = NodeCandidates(nodes: nodes ?? found.nodes, saved: "saved", pinned: false)
            return NodeChoice.startPlan(candidates, pauses: pauses, now: now,
                measurement: NodeMeasurement(latencies: latencies, addresses: addresses)).nodes[0].id
        }
        XCTAssertEqual(first(["saved": 220, "other": 50]), "other")
        XCTAssertEqual(first(["saved": 60, "other": 50]), "saved")
        // 40%: a gain of 80 ms out of 200 wins, 79 ms does not.
        XCTAssertEqual(first(["saved": 200, "other": 120]), "other")
        XCTAssertEqual(first(["saved": 200, "other": 121]), "saved")
        // 50 ms: a gain of 50 ms out of 100 wins, 49 ms out of 99 does not, though it is more than 40%.
        XCTAssertEqual(first(["saved": 100, "other": 50]), "other")
        XCTAssertEqual(first(["saved": 99, "other": 50]), "saved")
        // A failed measurement is unknown: such a node neither wins nor loses.
        XCTAssertEqual(first(["other": 50]), "saved")
        XCTAssertEqual(first(["saved": 220]), "saved")
        let paused = memoryPauses()
        paused.fail("other", now: now)
        XCTAssertEqual(first(["saved": 220, "other": 50], pauses: paused), "saved")
        let relayed = node("other", server: "other.example.com", endpoints: [
            endpoint("cdn", "vless_xhttp_cdn", "edge.example.ru"), endpoint("relay", "vless_reality", "198.51.100.7")])
        XCTAssertEqual(first(["saved": 220, "other": 50], nodes: [saved, relayed]), "saved")

        // The measurement times TCP to port 443 of the node's address, the first IPv4 address of a name.
        let dialed = Dialed()
        let measuredAt = Date().timeIntervalSince1970
        let measured = await NodeChoice.measure([saved, other], resolve: { host in
            host == "other.example.com" ? ["2001:db8::2", "192.0.2.2"] : []
        }, dial: { address, port in
            await dialed.add("\(address):\(port)")
            return address == "192.0.2.1" ? 0.2195 : address == "192.0.2.2" ? 0.05 : nil
        })
        XCTAssertEqual(measured.latencies, ["saved": 220, "other": 50])
        XCTAssertGreaterThanOrEqual(measured.resolvedAt, measuredAt)
        XCTAssertLessThanOrEqual(measured.resolvedAt, Date().timeIntervalSince1970)
        XCTAssertEqual(measured.addresses, addresses.mapValues { $0.union(["2001:db8::2"]) })
        let dials = await dialed.values
        XCTAssertEqual(Set(dials), ["192.0.2.1:443", "192.0.2.2:443"])
        let failed = await NodeChoice.measure([saved, other], resolve: { _ in [] }, dial: { _, _ in nil })
        XCTAssertTrue(failed.latencies.isEmpty)
        // A measurement that does not end within the timeout, 2 s on the device, is unknown.
        XCTAssertEqual(NodeChoice.latencyTimeout, 2)
        let began = Date()
        let slow = await NodeChoice.measure([saved, other], timeout: 0.2, resolve: { _ in ["192.0.2.2"] }, dial: { address, _ in
            guard address == "192.0.2.2" else { return 0.2195 }
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return 0.05
        })
        XCTAssertEqual(slow.latencies, ["saved": 220])
        XCTAssertLessThan(Date().timeIntervalSince(began), 1)
    }

    func testLatencyWinnerStartsOnDirectTransportsInItsFirstAttemptOnly() throws {
        let saved = node("saved", server: "192.0.2.1", endpoints: [endpoint("hy2", "hysteria2", "192.0.2.1"),
            endpoint("cdn", "vless_xhttp_cdn", "edge.example.ru")])
        let winner = node("fast", server: "fast.example.com", endpoints: [
            endpoint("hy2", "hysteria2", "fast.example.com"), endpoint("reality", "vless_reality", "203.0.113.5"),
            endpoint("cdn", "vless_xhttp_cdn", "edge.example.ru"), endpoint("relay", "vless_reality", "198.51.100.7"),
            endpoint("cdn-own", "vless_xhttp_cdn", "fast.example.com")])
        let found = NodeCandidates(nodes: [saved, winner], saved: "saved", pinned: false)
        let plan = NodeChoice.startPlan(found, pauses: memoryPauses(), now: now, measurement: NodeMeasurement(
            latencies: ["saved": 220, "fast": 50], addresses: ["fast.example.com": ["203.0.113.5"]]))
        XCTAssertTrue(plan.won)
        XCTAssertEqual(plan.nodes.map(\.id), ["fast", "saved"])
        XCTAssertEqual(plan.attempts.map { $0.node.id }, ["fast", "saved", "saved"])
        XCTAssertEqual(try configuredEndpoints(plan.attempts[0].node), ["hy2", "reality"])
        XCTAssertEqual(try configuredEndpoints(plan.attempts[1].node), ["hy2"])
        XCTAssertEqual(try configuredEndpoints(plan.attempts[2].node), ["hy2", "cdn"])
        XCTAssertEqual(plan.attempts[0].full, winner)

        // A normal restart or ticket renewal restores the full set of the selected node.
        let active = ActiveNode(plan.attempts[0].node, full: plan.attempts[0].full)
        XCTAssertTrue(active.narrowed)
        XCTAssertEqual(try configuredEndpoints(active.whole), ["hy2", "reality", "cdn", "relay", "cdn-own"])
        var renewedTicket = winner
        renewedTicket.endpoints = winner.endpoints.map { endpoint in
            guard case .object(var fields) = endpoint else { return endpoint }
            fields["password"] = .string("renewed")
            return .object(fields)
        }
        let renewed = active.renewed(renewedTicket)
        XCTAssertEqual(try configuredEndpoints(renewed.node), ["hy2", "reality"])
        XCTAssertEqual(renewed.whole, renewedTicket)
        XCTAssertFalse(ActiveNode(renewed.whole).narrowed)
        let failover = NodeChoice.failoverPlan(found, current: "fast", pauses: memoryPauses(), now: now)
        XCTAssertEqual(try failover.nodes.map(configuredEndpoints), [["hy2", "cdn"]])
        XCTAssertEqual(try failover.attempts.map { try configuredEndpoints($0.node) }, [["hy2"], ["hy2", "cdn"]])
        XCTAssertNil(NodeChoice.directNode(node("relayed", server: "192.0.2.9",
            endpoints: [endpoint("relay", "vless_reality", "198.51.100.7")]), addresses: [:]))
        XCTAssertEqual(NodeChoice.directNode(node("plain", server: "192.0.2.9"), addresses: [:])?.id, "plain")
    }

    func testFailoverThresholdsNetworkAndSavedCatalog() {
        let failover = NodeFailover(pauses: memoryPauses())
        failover.track(now: 0, node: "a", connected: false, reconnecting: true, network: true)
        XCTAssertFalse(failover.due(now: 44))
        XCTAssertTrue(failover.due(now: 45))
        // A tunnel that works again starts the count anew.
        failover.track(now: 46, node: "a", connected: true, reconnecting: false, network: true)
        XCTAssertFalse(failover.due(now: 100))
        failover.track(now: 100, node: "a", connected: false, reconnecting: true, network: true)
        XCTAssertFalse(failover.due(now: 144))
        XCTAssertTrue(failover.due(now: 145))
        // Without a network the count stands and starts anew once the network is back.
        failover.track(now: 140, node: "a", connected: false, reconnecting: true, network: false)
        failover.track(now: 300, node: "a", connected: false, reconnecting: true, network: false)
        XCTAssertFalse(failover.due(now: 300))
        failover.track(now: 310, node: "a", connected: false, reconnecting: true, network: true)
        XCTAssertFalse(failover.due(now: 354))
        XCTAssertTrue(failover.due(now: 355))
        // A move to another node gives it the full threshold.
        failover.switched(now: 360)
        XCTAssertFalse(failover.due(now: 404))
        XCTAssertTrue(failover.due(now: 405))
        // With the saved catalog the threshold is 3 minutes, and a controller that answers again restarts the count.
        failover.track(now: 500, node: "a", connected: true, reconnecting: false, network: true)
        failover.catalog(now: 500, found: NodeCandidates(nodes: [node("a")], saved: "a", pinned: false, cached: true))
        failover.track(now: 510, node: "a", connected: false, reconnecting: true, network: true)
        XCTAssertFalse(failover.due(now: 555))
        XCTAssertFalse(failover.due(now: 689))
        XCTAssertTrue(failover.due(now: 690))
        failover.catalog(now: 700, found: NodeCandidates(nodes: [node("a")], saved: "a", pinned: false))
        XCTAssertFalse(failover.due(now: 744))
        XCTAssertTrue(failover.due(now: 745))
    }

    func testAnotherNodeStartsItsOwnCountAndEpisode() {
        let pauses = memoryPauses()
        let failover = NodeFailover(pauses: pauses)
        failover.catalog(now: 0, found: NodeCandidates(nodes: [node("nl-01"), node("us-01"), node("de-01")], saved: "nl-01", pinned: false))
        failover.track(now: 0, node: "nl-01", connected: false, reconnecting: true, network: true)
        failover.pause("us-01", wallNow: now)
        XCTAssertTrue(failover.due(now: 45))
        // A renewal, a failover or any other operation moved the reconnecting tunnel to us-01 at 50 s.
        failover.track(now: 50, node: "us-01", connected: false, reconnecting: true, network: true)
        XCTAssertFalse(failover.due(now: 50))
        XCTAssertFalse(failover.due(now: 94))
        XCTAssertTrue(failover.due(now: 95))
        failover.pause("us-01", wallNow: now)
        XCTAssertEqual(pauses["us-01"]?.length, 1200)
        // With the saved catalog the node moved to gets the full 3 minutes.
        failover.catalog(now: 100, found: nil)
        failover.track(now: 200, node: "de-01", connected: false, reconnecting: true, network: true)
        XCTAssertFalse(failover.due(now: 379))
        XCTAssertTrue(failover.due(now: 380))
    }

    func testFailoverNetworkCancellationRetriesWithoutAThresholdOrAnotherPause() {
        for cached in [false, true] {
            for recovered in [false, true] {
                let pauses = memoryPauses()
                let failover = NodeFailover(pauses: pauses)
                let found = NodeCandidates(nodes: [node("failed"), mixedNode("next")], saved: "failed", pinned: false, cached: cached)
                failover.catalog(now: 0, found: found)
                failover.track(now: 0, node: "failed", connected: false, reconnecting: true, network: true)
                let threshold = cached ? NodeChoice.failoverOfflineAfter : NodeChoice.failoverAfter
                let cancelledAt = threshold + 2
                XCTAssertTrue(failover.due(now: threshold))
                failover.pause("failed", wallNow: now)
                failover.beginSwitch()
                let plan = NodeChoice.failoverPlan(found, current: "failed", pauses: pauses, now: now)
                var generation = 0
                var reconnecting = true
                var launched = 0, ended = 0, taken = 0
                var prepared: (() -> Void)?
                NodeStarts<String>(plan, failover: failover, pausing: true, wallNow: { self.now }, network: { true },
                    allowed: { _ in generation == 0 && reconnecting },
                    launch: { _, ready, done in
                        prepared = { guard ready() else { return }; launched += 1; done("core") }
                    }, take: { _, _ in taken += 1 }, stop: { _ in XCTFail("No core started") }, end: {
                        ended += 1
                        failover.switched(now: cancelledAt, retrying: generation != 0 && reconnecting)
                    }).run()
                XCTAssertNotNil(prepared)
                if recovered {
                    reconnecting = false
                } else {
                    generation += 1
                    // Losing the network or sleeping must not erase an already due round.
                    failover.track(now: cancelledAt, node: "failed", connected: false, reconnecting: true, network: false)
                }
                prepared?()
                XCTAssertEqual(launched, 0)
                XCTAssertEqual(taken, 0)
                XCTAssertEqual(ended, 1)
                XCTAssertEqual(pauses["failed"], NodePause(until: now + 600, length: 600))
                failover.track(now: cancelledAt, node: "failed", connected: false, reconnecting: true, network: true)
                if recovered {
                    XCTAssertFalse(failover.attempting)
                    XCTAssertFalse(failover.due(now: cancelledAt + threshold - 1))
                    XCTAssertTrue(failover.due(now: cancelledAt + threshold))
                } else {
                    XCTAssertTrue(failover.attempting)
                    XCTAssertTrue(failover.due(now: cancelledAt))
                    // A controller response or failure during preparation must not add a threshold either.
                    failover.catalog(now: cancelledAt, found: cached ? candidates(found.nodes) : nil)
                    XCTAssertTrue(failover.due(now: cancelledAt))
                    failover.pause("failed", wallNow: now + 2)
                    XCTAssertEqual(pauses["failed"], NodePause(until: now + 600, length: 600))
                    NodeStarts<String>(plan, failover: failover, pausing: true, wallNow: { self.now }, network: { true },
                        allowed: { _ in true }, launch: { _, ready, done in
                            guard ready() else { return }; launched += 1; done("core")
                        }, take: { _, _ in taken += 1; failover.switched(now: cancelledAt) },
                        stop: { _ in XCTFail("The catalog still offers the node") }, end: { XCTFail("The retry came up") }).run()
                    XCTAssertEqual(launched, 1)
                    XCTAssertEqual(taken, 1)
                    XCTAssertFalse(failover.attempting)
                }
            }
        }
    }

    func testRenewalDropsACoreWhoseNodeTheCatalogTookOffWhileItStarted() {
        let failover = NodeFailover(pauses: memoryPauses())
        failover.catalog(now: 0, found: NodeCandidates(nodes: [node("nl-01"), node("us-01")], saved: "nl-01", pinned: false))
        var launched: [String] = [], taken: [String] = [], stopped: [String] = [], ended = 0
        var pending: ((String?) -> Void)?
        // A ticket renewal of nl-01: its new core starts first, us-01 follows if it does not come up.
        func renew() {
            NodeStarts<String>(NodePlan(nodes: [node("nl-01"), node("us-01")]), failover: failover, pausing: true, wallNow: { self.now },
                network: { true }, allowed: { _ in true }, launch: { attempt, ready, done in
                    guard ready() else { return }; launched.append(attempt.node.id); pending = done
                },
                take: { _, core in taken.append(core) }, stop: { stopped.append($0) }, end: { ended += 1 }).run()
        }
        renew()
        pending?("nl-01 core")
        XCTAssertEqual(taken, ["nl-01 core"])
        // A fresh catalog without a ready node comes while the next renewal's core starts: the core is stopped and
        // the tunnel stays on its running core, as when a node is still activating.
        launched = []
        taken = []
        renew()
        failover.catalog(now: 10, found: NodeCandidates(nodes: [], saved: "nl-01", pinned: false))
        pending?("nl-01 core")
        XCTAssertEqual(launched, ["nl-01"])
        XCTAssertEqual(stopped, ["nl-01 core"])
        XCTAssertTrue(taken.isEmpty)
        XCTAssertEqual(ended, 1)
    }

    func testSavedRelayYieldsToAnotherNodesDirectTransportWithoutPause() {
        let pauses = memoryPauses()
        let found = candidates([mixedNode("nl-01"), mixedNode("us-01")])
        let result = start(NodeChoice.startPlan(found, pauses: pauses, now: now), pauses: pauses) { attempt in
            attempt.node.id == "us-01" ? "direct" : attempt.direct ? nil : "relay"
        }
        XCTAssertEqual(result.attempts.map { $0.node.id }, ["nl-01", "us-01"])
        XCTAssertEqual(result.chosen?.node.id, "us-01")
        XCTAssertEqual(result.chosen?.direct, true)
        XCTAssertNil(pauses["nl-01"])
    }

    func testRelayFallbackSkipsDirectPassForThirtyMinutesAcrossConnections() {
        let pauses = memoryPauses()
        let memory = NodeDirectPass()
        let found = candidates([mixedNode("nl-01"), mixedNode("us-01")])
        func connect(at time: TimeInterval) -> (attempts: [NodeAttempt], chosen: NodeAttempt?) {
            let plan = NodeChoice.startPlan(found, pauses: pauses, now: time, skipDirect: memory.skipped(now: time))
            return start(plan, pauses: pauses, memory: memory, at: time) { $0.direct ? nil : "relay" }
        }
        let first = connect(at: now)
        XCTAssertEqual(first.attempts.map { $0.node.id }, ["nl-01", "us-01", "nl-01"])
        XCTAssertEqual(first.attempts.map(\.direct), [true, true, false])
        XCTAssertEqual(first.chosen?.node.id, "nl-01")
        XCTAssertTrue(memory.skipped(now: now + 1799))
        let next = connect(at: now + 1799)
        XCTAssertEqual(next.attempts.map { $0.node.id }, ["nl-01"])
        XCTAssertEqual(next.chosen?.direct, false)
        // Success in a skipped full pass does not extend the original thirty minutes.
        let expired = connect(at: now + 1800)
        XCTAssertEqual(expired.attempts.map(\.direct), [true, true, false])
        XCTAssertNil(pauses["nl-01"])
        XCTAssertNil(pauses["us-01"])
    }

    func testLatencyWinnerFailurePausesForTenMinutesAndLeavesTheFullPass() {
        let pauses = memoryPauses()
        let found = candidates([mixedNode("saved"), mixedNode("fast")])
        let plan = NodeChoice.startPlan(found, pauses: pauses, now: now,
            measurement: NodeMeasurement(latencies: ["saved": 220, "fast": 50]))
        let result = start(plan, pauses: pauses) { $0.direct ? nil : "relay" }
        XCTAssertTrue(plan.won)
        XCTAssertEqual(result.attempts.map { $0.node.id }, ["fast", "saved", "saved"])
        XCTAssertEqual(result.attempts.map(\.direct), [true, true, false])
        XCTAssertEqual(pauses["fast"], NodePause(until: now + 600, length: 600))
        XCTAssertNil(pauses["saved"])
        XCTAssertEqual(result.chosen?.node.id, "saved")
    }

    func testDirectOnlyNodeFailureDoesNotPauseBeforeTheNextDirectNode() {
        let pauses = memoryPauses()
        let found = candidates([node("plain"), mixedNode("other")])
        let plan = NodeChoice.startPlan(found, pauses: pauses, now: now)
        let result = start(plan, pauses: pauses) { $0.node.id == "other" ? "direct" : nil }
        XCTAssertEqual(result.attempts.map { $0.node.id }, ["plain", "other"])
        XCTAssertTrue(result.attempts.allSatisfy(\.direct))
        XCTAssertEqual(result.chosen?.node.id, "other")
        XCTAssertNil(pauses["plain"])
        XCTAssertEqual(plan.attempts.filter { $0.node.id == "plain" }.map(\.direct), [true, false])
    }

    func testFullPassFailurePausesEvenADirectOnlyNodeRetriedWithTheSameSet() {
        let pauses = memoryPauses()
        let found = candidates([node("plain"), mixedNode("other")])
        let result = start(NodeChoice.startPlan(found, pauses: pauses, now: now), pauses: pauses) { attempt in
            if attempt.direct { XCTAssertNil(pauses[attempt.node.id]) }
            return !attempt.direct && attempt.node.id == "other" ? "relay" : nil
        }
        XCTAssertEqual(result.attempts.map { $0.node.id }, ["plain", "other", "plain", "other"])
        XCTAssertEqual(result.attempts.map(\.direct), [true, true, false, false])
        XCTAssertEqual(result.attempts[0].node, result.attempts[2].node)
        XCTAssertEqual(pauses["plain"], NodePause(until: now + 600, length: 600))
        XCTAssertNil(pauses["other"])
        XCTAssertEqual(result.chosen?.node.id, "other")
    }

    func testPinnedAndSingleCatalogNodeStartOnceWithTheFullSet() {
        let pauses = memoryPauses()
        let whole = mixedNode("only")
        for pinned in [false, true] {
            let found = NodeCandidates(nodes: [whole], saved: whole.id, pinned: pinned)
            let plan = NodeChoice.startPlan(found, pauses: pauses, now: now)
            XCTAssertTrue(plan.directSkipped)
            let result = start(plan, pauses: pauses) { _ in nil }
            XCTAssertEqual(result.attempts, [NodeAttempt(node: whole)])
            XCTAssertNil(result.chosen)
        }
    }

    func testFailoverUsesTwoPassesEvenWithOneCandidateAndRefreshesOnlyAddresses() async {
        let pauses = memoryPauses()
        let a = node("a", server: "a.example", endpoints: [endpoint("direct", "hysteria2", "192.0.2.1"),
            endpoint("relay", "vless_reality", "198.51.100.1")])
        let b = mixedNode("b")
        let resolved = Dialed()
        let fresh = NodeMeasurement(latencies: ["a": 50], addresses: ["a.example": ["192.0.2.1"]], resolvedAt: now)
        let reused = await NodeChoice.resolveAddresses([a], measurement: fresh, now: now + 1799, resolve: { host in
            await resolved.add(host); return ["192.0.2.1"]
        })
        XCTAssertEqual(reused, fresh)
        let freshNames = await resolved.values
        XCTAssertTrue(freshNames.isEmpty)
        let refreshed = await NodeChoice.resolveAddresses([a], measurement: fresh, now: now + 1800, resolve: { host in
            await resolved.add(host); return ["192.0.2.1"]
        })
        XCTAssertEqual(refreshed.addresses, fresh.addresses)
        XCTAssertTrue(refreshed.latencies.isEmpty)
        let staleNames = await resolved.values
        XCTAssertEqual(staleNames, ["a.example"])
        let missing = await NodeChoice.resolveAddresses([a], measurement: NodeMeasurement(), now: now, resolve: { _ in ["192.0.2.1"] })
        XCTAssertEqual(missing.addresses, fresh.addresses)
        // An hour of wall time, including sleep, expires addresses when the production clock is used.
        let beforeSleep = NodeMeasurement(addresses: fresh.addresses, resolvedAt: Date().timeIntervalSince1970 - 3600)
        let afterSleep = await NodeChoice.resolveAddresses([a], measurement: beforeSleep, resolve: { _ in ["192.0.2.2"] })
        XCTAssertEqual(afterSleep.addresses, ["a.example": ["192.0.2.2"]])
        let began = Date()
        let timedOut = await NodeChoice.resolveAddresses([a], measurement: NodeMeasurement(), now: now, timeout: 0.05,
            resolve: { _ in try? await Task.sleep(nanoseconds: 30_000_000_000); return [] })
        XCTAssertTrue(timedOut.addresses.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(began), 1)
        for remaining in [[a], [a, b]] {
            let found = candidates([node("failed")] + remaining)
            let plan = NodeChoice.failoverPlan(found, current: "failed", pauses: pauses, now: now, measurement: refreshed)
            let result = start(plan, pauses: pauses) { $0.direct ? nil : "relay" }
            XCTAssertEqual(result.attempts.map { $0.node.id }, remaining.map(\.id) + ["a"])
            XCTAssertEqual(result.attempts.map(\.direct), remaining.map { _ in true } + [false])
            XCTAssertEqual(result.chosen?.node.id, "a")
            XCTAssertNil(pauses["a"])
            let skipped = NodeChoice.failoverPlan(found, current: "failed", pauses: pauses, now: now, skipDirect: true)
            XCTAssertTrue(skipped.attempts.allSatisfy { !$0.direct })
        }
    }

    func testDirectSuccessAndDirectTicketRenewalResetProcessMemoryAndNetworkChangeDoesToo() {
        let pauses = memoryPauses()
        let memory = NodeDirectPass()
        let whole = mixedNode("saved")
        let plan = NodeChoice.startPlan(candidates([whole, mixedNode("other")]), pauses: pauses, now: now)
        func rememberRelay() {
            _ = start(plan, pauses: pauses, memory: memory) { $0.direct ? nil : "relay" }
            XCTAssertTrue(memory.skipped(now: now))
        }
        rememberRelay()
        _ = start(plan, pauses: pauses, memory: memory) { _ in "direct" }
        XCTAssertFalse(memory.skipped(now: now))
        rememberRelay()
        // A normal full-set restart for a renewed ticket chose the direct endpoint.
        let renewal = start(NodePlan(nodes: [whole]), pauses: pauses, memory: memory) { _ in "direct" }
        XCTAssertEqual(renewal.chosen?.direct, false)
        XCTAssertFalse(memory.skipped(now: now))
        memory.onNetwork("wifi/1")
        rememberRelay()
        memory.onNetwork("wifi/1")
        XCTAssertTrue(memory.skipped(now: now))
        memory.onNetwork("cellular/2")
        XCTAssertFalse(memory.skipped(now: now))
    }

    func testTicketRenewalRestoresTheFullSetAfterAnOrdinaryDirectPassStart() throws {
        let pauses = memoryPauses()
        let whole = mixedNode("saved")
        let plan = NodeChoice.startPlan(candidates([whole, mixedNode("other")]), pauses: pauses, now: now)
        let result = start(plan, pauses: pauses) { _ in "direct" }
        let chosen = try XCTUnwrap(result.chosen)
        XCTAssertFalse(plan.won)
        let active = ActiveNode(chosen.node, full: chosen.full)
        XCTAssertTrue(active.narrowed)
        var ticket = whole
        ticket.endpoints = whole.endpoints.map { value in
            guard case .object(var fields) = value else { return value }
            fields["password"] = .string("new-ticket")
            return .object(fields)
        }
        let renewed = active.renewed(ticket)
        XCTAssertEqual(try configuredEndpoints(renewed.node), ["direct"])
        let restarted = start(NodePlan(nodes: [renewed.whole]), pauses: pauses) { _ in "direct" }
        XCTAssertEqual(restarted.chosen?.node, ticket)
        XCTAssertNil(restarted.chosen?.full)
        XCTAssertEqual(try configuredEndpoints(XCTUnwrap(restarted.chosen?.node)), ["direct", "relay"])
    }

    func testPinAndTunnelRecoveryDuringPreparationCancelLaunchWithoutPausing() {
        let found = candidates([mixedNode("saved"), mixedNode("other")])
        for change in ["pin-other", "pin-same", "recovered"] {
            let pauses = memoryPauses()
            let failover = NodeFailover(pauses: pauses)
            failover.catalog(now: 0, found: found)
            let plan = NodeChoice.startPlan(found, pauses: pauses, now: now)
            var pinnedTo: String?
            var reconnecting = true
            var launched = 0, taken = 0, ended = 0
            var prepared: (() -> Void)?
            NodeStarts<String>(plan, failover: failover, pausing: true, wallNow: { self.now }, network: { true },
                allowed: { NodeChoice.startAllowed($0, found: found, pinnedTo: pinnedTo,
                    leaving: change == "recovered", reconnecting: reconnecting) },
                launch: { _, ready, done in
                    prepared = { guard ready() else { return }; launched += 1; done("core") }
                }, take: { _, _ in taken += 1 }, stop: { _ in XCTFail("No core should have started") },
                end: { ended += 1 }).run()
            XCTAssertNotNil(prepared)
            if change == "recovered" { reconnecting = false }
            else { pinnedTo = change == "pin-other" ? "other" : "saved" }
            prepared?()
            XCTAssertEqual(launched, 0, change)
            XCTAssertEqual(taken, 0, change)
            XCTAssertEqual(ended, 1, change)
            XCTAssertNil(pauses["saved"])
        }
    }

    private func mixedNode(_ id: String) -> CatalogNode {
        node(id, endpoints: [endpoint("direct", "hysteria2", "192.0.2.10"), endpoint("relay", "vless_reality", "198.51.100.1")])
    }

    private func candidates(_ nodes: [CatalogNode]) -> NodeCandidates {
        NodeCandidates(nodes: nodes, saved: nodes.first?.id ?? "", pinned: false)
    }

    private func start(_ plan: NodePlan, pauses: NodePauses, memory: NodeDirectPass? = nil, at time: TimeInterval? = nil,
                       succeeds: @escaping (NodeAttempt) -> String?) -> (attempts: [NodeAttempt], chosen: NodeAttempt?) {
        let failover = NodeFailover(pauses: pauses)
        failover.catalog(now: 0, found: candidates(plan.nodes))
        var attempts: [NodeAttempt] = []
        var chosen: NodeAttempt?
        NodeStarts<String>(plan, failover: failover, pausing: true, wallNow: { time ?? self.now }, network: { true },
            allowed: { _ in true }, launch: { attempt, ready, done in
                guard ready() else { return }
                attempts.append(attempt)
                done(succeeds(attempt))
            }, take: { attempt, endpoint in
                chosen = attempt
                memory?.connected(attempt, in: plan, endpoint: endpoint, addresses: plan.addresses, now: time ?? self.now)
            }, stop: { _ in XCTFail("The catalog did not change") }, end: {}).run()
        return (attempts, chosen)
    }

    private func memoryPauses() -> NodePauses {
        var stored: Data?
        return NodePauses(read: { stored }, write: { stored = $0 })
    }

    private func node(_ id: String, server: String = "192.0.2.10", endpoints: [JSONValue] = []) -> CatalogNode {
        CatalogNode(id: id, name: id, profile: ConnectionProfile(name: id, server: server, port: 443, password: "ticket",
            obfsPassword: "", serverName: "tls.example.com", certificate: ""), expiresAt: Int64(now) + 600, endpoints: endpoints)
    }

    private func endpoint(_ id: String, _ kind: String, _ server: String) -> JSONValue {
        .object(["id": .string(id), "kind": .string(kind), "server": .string(server), "server_port": .number(443),
                 "password": .string("ticket")])
    }

    // The endpoint IDs of the core's configuration for a start on node.
    private func configuredEndpoints(_ node: CatalogNode) throws -> [String] {
        let rules = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("routing/default-rules.json")
        let config = try TunnelConfiguration.make(profile: XCTUnwrap(node.profile),
            base: RoutingDocument.parse(Data(contentsOf: rules)), endpoints: node.endpoints)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        return try XCTUnwrap(object["endpoints"] as? [[String: Any]]).compactMap { $0["id"] as? String }
    }
}

private actor Dialed {
    private(set) var values: [String] = []
    func add(_ value: String) { values.append(value) }
}
