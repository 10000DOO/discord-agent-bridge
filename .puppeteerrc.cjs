// Do NOT download Chromium on `npm install` (design §6.1). Chromium is provisioned ON
// DEMAND instead: the image renderer reuses a system-installed Chrome when present (see
// src/discord/render/chrome.ts), or the operator opts into a background download via the
// /setup and /config install prompts (src/discord/render/chromiumProvisioner.ts). Until a
// browser is available the render branch stays off and answers fall back to raw text.
// Keeps `npm install` lightweight — no ~300MB download at install time.
module.exports = { skipDownload: true };
