import * as fs from 'node:fs';

// Chrome/Chromium detection, kept SEPARATE from browserRenderer so callers (wiring's
// session-start branch) can check availability WITHOUT importing puppeteer. We reuse an
// already-installed system browser rather than downloading one (see .puppeteerrc.cjs).

const CHROME_CANDIDATES = [
  process.env.PUPPETEER_EXECUTABLE_PATH,
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
  '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
  '/usr/bin/google-chrome',
  '/usr/bin/chromium',
  '/usr/bin/chromium-browser',
];

export function findChrome(): string | undefined {
  for (const c of CHROME_CANDIDATES) {
    if (c && fs.existsSync(c)) return c;
  }
  return undefined;
}

// The session-start branch gate (design §7): a renderer is injected only when this is
// true; otherwise the answer stays raw text.
export function chromeAvailable(): boolean {
  return findChrome() !== undefined;
}
