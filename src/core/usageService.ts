// TODO(Phase 1): Claude OAuth usage endpoint + ctx-usage cache/backoff (§7.4). Codex: n/a.
export interface UsageSnapshot {
  fiveHour?: { utilization: number; resetsAt?: string };
  sevenDay?: { utilization: number; resetsAt?: string };
  sevenDayOpus?: { utilization: number; resetsAt?: string };
  sevenDaySonnet?: { utilization: number; resetsAt?: string };
}

// Requires OAuth subscription login (~/.claude/.credentials.json), not an API key.
// If only an API key is present, degrade gracefully and hide the panel.
export class UsageService {
  getUsage(): Promise<UsageSnapshot | null> {
    throw new Error('not implemented');
  }
}
