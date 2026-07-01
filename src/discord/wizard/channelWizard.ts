// TODO(Phase 1): orchestrates one flow — folder browser (or favorite) → backend → model
// → permission mode/profile. Defaults pre-filled from resolved hierarchy (§4, §9 step 1).
export class ChannelWizard {
  run(_guildId: string, _channelId: string, _userId: string): Promise<void> {
    throw new Error('not implemented');
  }
}
