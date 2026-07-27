import Foundation

/// 게이트웨이 메시지 경로 isAdministrator 계산용 캐시(OK-2). 인터랙션 payload는 계산된
/// member.permissions를 실어주지만 메시지 payload는 안 실어주므로, GuildCreate + 역할
/// 변경 이벤트로부터 같은 답을 재현한다. 역할 변경 시 재부팅 없이 즉시 갱신됨(Q1-b).
public actor GuildAdminCache {
    public static let shared = GuildAdminCache()

    private struct GuildInfo {
        var ownerId: String
        var adminRoleIds: Set<String>
    }

    private var guilds: [String: GuildInfo] = [:]

    public init() {}

    /// GuildCreate(부팅/조인)에서 전체 교체: owner id + Administrator 비트를 가진 role id 집합.
    public func setGuild(guildId: String, ownerId: String, adminRoleIds: Set<String>) {
        guilds[guildId] = GuildInfo(ownerId: ownerId, adminRoleIds: adminRoleIds)
    }

    /// 역할 생성/수정: 현재 비트에 따라 admin 집합에 추가/제거. 아직 못 본 길드면 no-op
    /// (봇이 속한 길드는 GuildCreate가 역할 이벤트보다 항상 먼저 옴).
    public func setRoleIsAdmin(guildId: String, roleId: String, isAdmin: Bool) {
        guard var info = guilds[guildId] else { return }
        if isAdmin { info.adminRoleIds.insert(roleId) } else { info.adminRoleIds.remove(roleId) }
        guilds[guildId] = info
    }

    /// 역할 삭제: 무조건 admin 집합에서 제거.
    public func removeRole(guildId: String, roleId: String) {
        guard var info = guilds[guildId] else { return }
        info.adminRoleIds.remove(roleId)
        guilds[guildId] = info
    }

    /// userId가 길드 owner이거나 admin-flagged role을 하나라도 갖고 있으면 true. Administrator
    /// 비트는 디스코드 권한 모델상 채널 오버라이트를 무시하므로 role id OR만으로 충분.
    public func isAdministrator(guildId: String, userId: String, roleIds: [String]) -> Bool {
        guard let info = guilds[guildId] else { return false }
        return info.ownerId == userId || !Set(roleIds).isDisjoint(with: info.adminRoleIds)
    }
}
