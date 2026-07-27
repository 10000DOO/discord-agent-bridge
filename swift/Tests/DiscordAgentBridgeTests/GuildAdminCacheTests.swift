import Testing
@testable import DiscordAgentBridge

// WO-1 (OK-2): message path isAdministrator must be computed, not fixed false. Covers
// GuildCreate population, live role-change propagation (Q1-b), and the actual admin/non-admin
// distinction the message path relies on. Each test uses a fresh instance (not .shared) so cases
// don't leak into each other, mirroring SessionRegistry's testability pattern.
@Suite("GuildAdminCache")
struct GuildAdminCacheTests {
    @Test func ownerIsAdministratorWithNoRoles() async {
        let cache = GuildAdminCache()
        await cache.setGuild(guildId: "g1", ownerId: "owner", adminRoleIds: [])
        #expect(await cache.isAdministrator(guildId: "g1", userId: "owner", roleIds: []) == true)
    }

    @Test func memberWithAdminRoleIsAdministrator() async {
        let cache = GuildAdminCache()
        await cache.setGuild(guildId: "g1", ownerId: "owner", adminRoleIds: ["role-admin"])
        #expect(await cache.isAdministrator(guildId: "g1", userId: "u1", roleIds: ["role-admin", "role-other"]) == true)
    }

    @Test func memberWithoutAdminRoleIsNotAdministrator() async {
        let cache = GuildAdminCache()
        await cache.setGuild(guildId: "g1", ownerId: "owner", adminRoleIds: ["role-admin"])
        #expect(await cache.isAdministrator(guildId: "g1", userId: "u1", roleIds: ["role-other"]) == false)
    }

    @Test func unknownGuildIsNotAdministrator() async {
        let cache = GuildAdminCache()
        #expect(await cache.isAdministrator(guildId: "unknown", userId: "owner", roleIds: []) == false)
    }

    @Test func roleGrantedAdminLiveUpdatesCache() async {
        let cache = GuildAdminCache()
        await cache.setGuild(guildId: "g1", ownerId: "owner", adminRoleIds: [])
        #expect(await cache.isAdministrator(guildId: "g1", userId: "u1", roleIds: ["role-mod"]) == false)

        // onGuildRoleUpdate: role-mod is edited to carry the Administrator bit.
        await cache.setRoleIsAdmin(guildId: "g1", roleId: "role-mod", isAdmin: true)
        #expect(await cache.isAdministrator(guildId: "g1", userId: "u1", roleIds: ["role-mod"]) == true)
    }

    @Test func roleRevokedAdminLiveUpdatesCache() async {
        let cache = GuildAdminCache()
        await cache.setGuild(guildId: "g1", ownerId: "owner", adminRoleIds: ["role-mod"])
        #expect(await cache.isAdministrator(guildId: "g1", userId: "u1", roleIds: ["role-mod"]) == true)

        // onGuildRoleUpdate: Administrator bit removed from role-mod.
        await cache.setRoleIsAdmin(guildId: "g1", roleId: "role-mod", isAdmin: false)
        #expect(await cache.isAdministrator(guildId: "g1", userId: "u1", roleIds: ["role-mod"]) == false)
    }

    @Test func roleDeletedIsDroppedFromAdminSet() async {
        let cache = GuildAdminCache()
        await cache.setGuild(guildId: "g1", ownerId: "owner", adminRoleIds: ["role-mod"])
        // onGuildRoleDelete: role-mod is deleted outright.
        await cache.removeRole(guildId: "g1", roleId: "role-mod")
        #expect(await cache.isAdministrator(guildId: "g1", userId: "u1", roleIds: ["role-mod"]) == false)
    }

    @Test func roleEventsBeforeGuildCreateAreNoOps() async {
        let cache = GuildAdminCache()
        // Guild never seen (no GuildCreate yet) — role events must not create phantom state.
        await cache.setRoleIsAdmin(guildId: "ghost", roleId: "role-x", isAdmin: true)
        #expect(await cache.isAdministrator(guildId: "ghost", userId: "u1", roleIds: ["role-x"]) == false)
    }
}
