import * as path from 'node:path';
import type { AuthAction } from '../../core/auth.js';
import { t } from '../i18n.js';

// The tier each command requires (§7.1): stop-all is admin; the rest are execute.
export const ACTION_TIER: Record<string, AuthAction> = {
  'agent.start': 'drive',
  'agent.resume': 'drive',
  'agent.close': 'drive',
  'agent.stats': 'drive',
  'mode.backend': 'drive',
  'mode.perm': 'drive',
  model: 'drive',
  effort: 'drive',
  stop: 'drive',
  clear: 'drive',
  doc: 'drive',
  'stop-all': 'admin',
};

export function channelKey(guildId: string, channelId: string): string {
  return `${guildId}:${channelId}`;
}

export async function safe(p: Promise<unknown>): Promise<void> {
  try {
    await p;
  } catch {
    // best-effort
  }
}

// True when `name` is a safe SINGLE folder segment for the 📁 Create flow: non-empty,
// no path separators ('/' or '\\'), not '.'/'..' traversal, and not absolute. This
// guarantees the created folder is a DIRECT child of the current browsed directory and
// can never escape it (the router additionally verifies dirname(target) === parent).
export function isSafeFolderName(name: string): boolean {
  if (name.length === 0) return false;
  if (name === '.' || name === '..') return false;
  if (name.includes('/') || name.includes('\\')) return false;
  if (path.isAbsolute(name)) return false;
  // A segment that path treats as anything other than itself (e.g. contains a NUL) is
  // rejected; path.basename normalizes trailing separators, so require an exact match.
  if (path.basename(name) !== name) return false;
  return true;
}

// Render an updatedAt ISO string as a short relative time for the resume picker
// (A4D-style "3분 전"). Absent/unparseable → empty (the option just shows its label).
export function relativeTime(updatedAt: string | undefined): string {
  if (!updatedAt) return '';
  const then = Date.parse(updatedAt);
  if (Number.isNaN(then)) return '';
  const seconds = Math.max(0, Math.floor((Date.now() - then) / 1000));
  if (seconds < 60) return t('resume.time.now');
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return t('resume.time.min', { n: minutes });
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return t('resume.time.hour', { n: hours });
  return t('resume.time.day', { n: Math.floor(hours / 24) });
}
