// TODO(Phase 1): Korean-default localizable bot messages (message catalog) (§4, §11 item 14).
export type Locale = 'ko' | 'en';

export function t(_key: string, _locale: Locale = 'ko', _params?: Record<string, string>): string {
  throw new Error('not implemented');
}
