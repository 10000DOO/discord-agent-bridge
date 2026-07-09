// Do NOT download Chromium on `npm install` (design §6.1). The image renderer reuses a
// system-installed Chrome (see src/discord/render/chrome.ts); when none is present the
// render branch stays off and answers fall back to raw text. Keeps install lightweight.
module.exports = { skipDownload: true };
