// TODO(Phase 1): project favorites/bookmarks (saved cwd paths) (§4, §8).
export class Favorites {
  list(_guildId: string): string[] {
    throw new Error('not implemented');
  }

  add(_guildId: string, _path: string): void {
    throw new Error('not implemented');
  }
}
