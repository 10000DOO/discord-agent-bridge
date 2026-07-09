import { describe, it, expect } from 'vitest';
import { parseVersion, compareVersions, isNewerStable } from './version.js';

describe('parseVersion', () => {
  it('parses a plain release', () => {
    expect(parseVersion('1.2.3')).toEqual({ major: 1, minor: 2, patch: 3, prerelease: [] });
  });

  it('parses a prerelease into dot-separated identifiers', () => {
    expect(parseVersion('1.2.3-beta.1')).toEqual({ major: 1, minor: 2, patch: 3, prerelease: ['beta', '1'] });
  });

  it('parses and ignores build metadata (no precedence effect)', () => {
    expect(parseVersion('1.2.3+build.7')).toEqual({ major: 1, minor: 2, patch: 3, prerelease: [] });
    expect(parseVersion('1.2.3-rc.1+build.7')).toEqual({ major: 1, minor: 2, patch: 3, prerelease: ['rc', '1'] });
  });

  it('trims surrounding whitespace', () => {
    expect(parseVersion('  0.12.0 ')).toEqual({ major: 0, minor: 12, patch: 0, prerelease: [] });
  });

  it('returns null for malformed input', () => {
    for (const bad of ['', 'v1.2.3', '1.2', '1.2.3.4', 'latest', '1.x.0', 'abc']) {
      expect(parseVersion(bad)).toBeNull();
    }
  });
});

describe('compareVersions', () => {
  const v = (s: string) => parseVersion(s)!;

  it('orders by major, then minor, then patch', () => {
    expect(compareVersions(v('1.0.0'), v('2.0.0'))).toBe(-1);
    expect(compareVersions(v('1.2.0'), v('1.1.0'))).toBe(1);
    expect(compareVersions(v('1.1.1'), v('1.1.2'))).toBe(-1);
    expect(compareVersions(v('1.1.1'), v('1.1.1'))).toBe(0);
  });

  it('ranks a prerelease below the matching release', () => {
    expect(compareVersions(v('1.2.3-beta.1'), v('1.2.3'))).toBe(-1);
    expect(compareVersions(v('1.2.3'), v('1.2.3-beta.1'))).toBe(1);
  });

  it('orders prerelease identifiers per semver (numeric < alphanumeric, then length)', () => {
    expect(compareVersions(v('1.0.0-alpha.1'), v('1.0.0-alpha.2'))).toBe(-1);
    expect(compareVersions(v('1.0.0-alpha'), v('1.0.0-beta'))).toBe(-1);
    // numeric identifiers rank below non-numeric
    expect(compareVersions(v('1.0.0-1'), v('1.0.0-alpha'))).toBe(-1);
    // a larger set of identifiers outranks its prefix
    expect(compareVersions(v('1.0.0-alpha'), v('1.0.0-alpha.1'))).toBe(-1);
  });
});

describe('isNewerStable', () => {
  it('is true only for a strictly newer STABLE latest', () => {
    expect(isNewerStable('0.12.0', '0.12.1')).toBe(true);
    expect(isNewerStable('0.12.0', '0.13.0')).toBe(true);
    expect(isNewerStable('0.12.0', '1.0.0')).toBe(true);
  });

  it('is false for equal or older latest (no downgrade)', () => {
    expect(isNewerStable('0.12.0', '0.12.0')).toBe(false);
    expect(isNewerStable('0.12.0', '0.11.9')).toBe(false);
    expect(isNewerStable('1.0.0', '0.99.99')).toBe(false);
  });

  it('is false when latest is a prerelease (only stable is proposed)', () => {
    expect(isNewerStable('0.12.0', '0.13.0-beta.1')).toBe(false);
    expect(isNewerStable('0.12.0', '1.0.0-rc.1')).toBe(false);
  });

  it('is false when either version is unparseable', () => {
    expect(isNewerStable('not-a-version', '0.13.0')).toBe(false);
    expect(isNewerStable('0.12.0', 'latest')).toBe(false);
  });
});
