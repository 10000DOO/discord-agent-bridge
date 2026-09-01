import Testing
@testable import dab

// A reconnect re-fires READY, and the boot sequence behind it (slash-command registration,
// resumeAll, updater/poller tasks) must not run again — during the zstd reconnect loop that
// cost us a bot token it re-registered 17 slash commands every 20 seconds.
struct BootSequenceOnceTests {
    @Test func firstReadyClaimsBootSequenceAndLaterOnesDoNot() async {
        let identity = BotGatewayIdentity()
        #expect(await identity.claimBootSequence())
        #expect(await identity.claimBootSequence() == false)
        #expect(await identity.claimBootSequence() == false)
    }

    // A reconnect loop can fire READY faster than the boot sequence finishes, so the guard has to
    // hold when two of them overlap.
    @Test func concurrentReadiesClaimOnlyOnce() async {
        let identity = BotGatewayIdentity()
        let claimed = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 {
                group.addTask { await identity.claimBootSequence() }
            }
            var count = 0
            for await didClaim in group where didClaim { count += 1 }
            return count
        }
        #expect(claimed == 1)
    }
}
