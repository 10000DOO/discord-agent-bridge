// Pure semver helpers for the auto-updater (§7). No dependency on the `semver` package
// (the project ships none — see package.json). Only the subset we need: parse an
// 'x.y.z[-pre][+build]' string, compare two versions, and decide whether a candidate is
// a STABLE release strictly newer than the current one. No side effects; fully unit-tested.

export interface SemVer {
  major: number;
  minor: number;
  patch: number;
  // Dot-separated prerelease identifiers ([] for a stable release, e.g. ['beta','1']).
  prerelease: string[];
}

// Parse a semver string. Returns null for anything not matching 'MAJOR.MINOR.PATCH'
// with an optional '-prerelease' and/or '+build' (build metadata is parsed but ignored,
// per semver: it does not affect precedence).
export function parseVersion(v: string): SemVer | null {
  const match = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/.exec(v.trim());
  if (!match) return null;
  const [, major, minor, patch, pre] = match;
  return {
    major: Number(major),
    minor: Number(minor),
    patch: Number(patch),
    prerelease: pre ? pre.split('.') : [],
  };
}

// Compare two prerelease identifier lists per semver §11: a version WITHOUT prerelease
// outranks one WITH; numeric identifiers compare numerically and rank below non-numeric;
// otherwise compare lexically; a longer set outranks a shorter set when all prior
// identifiers are equal. Returns -1/0/1.
function comparePrerelease(a: string[], b: string[]): number {
  if (a.length === 0 && b.length === 0) return 0;
  if (a.length === 0) return 1; // a is a stable release → higher precedence
  if (b.length === 0) return -1;
  const len = Math.min(a.length, b.length);
  for (let i = 0; i < len; i++) {
    const ai = a[i] as string;
    const bi = b[i] as string;
    const an = /^\d+$/.test(ai);
    const bn = /^\d+$/.test(bi);
    if (an && bn) {
      const diff = Number(ai) - Number(bi);
      if (diff !== 0) return diff < 0 ? -1 : 1;
    } else if (an !== bn) {
      return an ? -1 : 1; // numeric identifiers rank below non-numeric
    } else if (ai !== bi) {
      return ai < bi ? -1 : 1;
    }
  }
  if (a.length === b.length) return 0;
  return a.length < b.length ? -1 : 1;
}

// Total ordering over versions: compare core (major.minor.patch), then prerelease.
// Returns -1 when a < b, 0 when equal, 1 when a > b (build metadata ignored).
export function compareVersions(a: SemVer, b: SemVer): number {
  if (a.major !== b.major) return a.major < b.major ? -1 : 1;
  if (a.minor !== b.minor) return a.minor < b.minor ? -1 : 1;
  if (a.patch !== b.patch) return a.patch < b.patch ? -1 : 1;
  return comparePrerelease(a.prerelease, b.prerelease);
}

// True ONLY when `latest` is a STABLE release (no prerelease) strictly greater than
// `current`. Equal versions, downgrades, a prerelease `latest`, or an unparseable
// input all yield false — so the updater proposes a stable upgrade and nothing else.
export function isNewerStable(current: string, latest: string): boolean {
  const c = parseVersion(current);
  const l = parseVersion(latest);
  if (!c || !l) return false;
  if (l.prerelease.length > 0) return false; // only propose stable releases
  return compareVersions(l, c) > 0;
}
