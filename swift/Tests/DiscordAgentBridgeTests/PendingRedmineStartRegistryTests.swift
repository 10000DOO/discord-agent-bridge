import Foundation
import Testing
@testable import DiscordAgentBridge

struct PendingRedmineStartRegistryTests {
    @Test func setGetRemove() async {
        let reg = PendingRedmineStartRegistry()
        await reg.put(42, channelId: "c1")
        #expect(await reg.get(channelId: "c1") == 42)
        await reg.remove(channelId: "c1")
        #expect(await reg.get(channelId: "c1") == nil)
    }
}
