// Interactive first-run config (token, Client ID, defaults) via @inquirer/prompts
// (§4, §8). Writes config.json through ConfigStore (0600).
//
// Role tiers are NO LONGER set here: the terminal step needs only the secret (the
// bot token, which must be pasted in the terminal, never through Discord) plus the
// Client ID and the Message Content Intent confirmation. Role allowlists are left
// empty (deny-by-default) and the operator configures them AFTER inviting the bot,
// in Discord via the `/config` command (clicking role names — no IDs). See §7.1.
//
// Everything the wizard touches — the prompt functions, the browser opener, the
// output sink, the ConfigStore, and the logger — is injectable through `deps` so
// tests never block on real stdin or open a real browser (they feed scripted
// answers and assert against a temp-dir ConfigStore). The defaults below wire the
// real @inquirer/prompts + open + ConfigStore for the actual CLI path.
import { input, password, confirm } from '@inquirer/prompts';
import open from 'open';
import { PermissionFlagsBits } from 'discord.js';
import { ConfigStore } from '../core/config.js';
import { CONFIG_DEFAULTS, CONFIG_VERSION, type AppConfig } from '../core/configSchema.js';
import { createLogger } from '../core/logger.js';
import type { Logger } from '../core/contracts.js';
import { setLocale, t, type Locale } from '../discord/i18n.js';

// The bot's required permission bitfield, computed from the exact permission set
// documented in README ("초대 링크 만들기" → Bot Permissions). Kept as the discord.js
// PermissionFlagsBits so the bits stay authoritative if Discord renumbers them.
const INVITE_PERMISSION_BITS: bigint =
  PermissionFlagsBits.ManageChannels |
  PermissionFlagsBits.SendMessages |
  PermissionFlagsBits.EmbedLinks |
  PermissionFlagsBits.AttachFiles |
  PermissionFlagsBits.ReadMessageHistory |
  PermissionFlagsBits.CreatePublicThreads |
  PermissionFlagsBits.SendMessagesInThreads |
  PermissionFlagsBits.ManageThreads |
  PermissionFlagsBits.AddReactions;

const DEVELOPER_PORTAL_URL = 'https://discord.com/developers/applications';

// The prompt surface the wizard needs. Matches the @inquirer/prompts signatures we
// use, narrowed to what the wizard calls so a test double is trivial to write.
export interface SetupPrompts {
  input(config: { message: string; default?: string; validate?: (v: string) => boolean | string }): Promise<string>;
  password(config: { message: string; mask?: boolean | string; validate?: (v: string) => boolean | string }): Promise<string>;
  confirm(config: { message: string; default?: boolean }): Promise<boolean>;
}

// Injectable dependencies. All optional; each defaults to the real implementation so
// `runSetup()` with no args is the production path and `runSetup({...})` is the test
// path. `log` is the plain user-facing output channel (console.log by default) —
// deliberately separate from `logger` (the redacting operational logger), because
// the token must never reach either in plaintext.
export interface SetupDeps {
  prompts?: SetupPrompts;
  open?: (target: string) => Promise<unknown>;
  store?: ConfigStore;
  logger?: Logger;
  log?: (message: string) => void;
}

// Build the OAuth2 bot-invite URL for the given client id with the bot +
// applications.commands scopes and the required permission bitfield (§ README).
export function buildInviteUrl(clientId: string): string {
  const permissions = INVITE_PERMISSION_BITS.toString();
  return (
    'https://discord.com/api/oauth2/authorize' +
    `?client_id=${encodeURIComponent(clientId)}` +
    '&scope=bot%20applications.commands' +
    `&permissions=${permissions}`
  );
}

const defaultPrompts: SetupPrompts = { input, password, confirm };

export async function runSetup(deps: SetupDeps = {}): Promise<void> {
  const prompts = deps.prompts ?? defaultPrompts;
  const openUrl = deps.open ?? open;
  const store = deps.store ?? new ConfigStore();
  const logger = deps.logger ?? createLogger('setup');
  const log = deps.log ?? ((m: string) => console.log(m));

  log('=== discord-agent-bridge 셋업 ===\n');

  // Step 1 — bot token (masked; never echoed back in plaintext).
  log('1단계 — Discord 봇 토큰');
  log(`  ${DEVELOPER_PORTAL_URL} 의 애플리케이션 → Bot 탭에서 토큰을 복사하세요.`);
  log('  ⚠️ 토큰은 비밀번호입니다. 노출되면 즉시 Reset Token 으로 재발급하세요.');
  const token = await prompts.password({
    message: '봇 토큰을 입력하세요:',
    mask: '*',
    validate: (v) => (v.trim().length > 0 ? true : '토큰은 필수입니다.'),
  });

  // Step 2 — Client ID (Application ID).
  log('\n2단계 — Client ID (Application ID)');
  log('  OAuth2 탭(또는 General Information)에서 Client ID 를 복사하세요.');
  const clientId = await prompts.input({
    message: 'Client ID 를 입력하세요:',
    validate: (v) => (v.trim().length > 0 ? true : 'Client ID 는 필수입니다.'),
  });

  // Step 3 — Message Content Intent reminder.
  log('\n3단계 — Message Content Intent');
  log('  Bot 탭 → Privileged Gateway Intents 에서 MESSAGE CONTENT INTENT 를 켜고 저장하세요.');
  log('  (켜져 있지 않으면 봇이 메시지 내용을 읽지 못합니다.)');
  await prompts.confirm({
    message: 'Message Content Intent 를 켰나요?',
    default: true,
  });

  // Role tiers are NOT prompted here anymore. They are left empty (deny-by-default)
  // and configured in Discord via `/config` after the bot is invited (§7.1). The
  // guidance is printed near the invite step below, once the bot can be added.

  // Step 4 — defaults (Claude model, codexHome, locale).
  log('\n4단계 — 기본값');
  const claudeModel = await prompts.input({
    message: '기본 Claude 모델:',
    default: CONFIG_DEFAULTS.defaults.claudeModel,
  });
  const codexHome = await prompts.input({
    message: 'Codex 홈 경로:',
    default: CONFIG_DEFAULTS.defaults.codexHome,
  });
  const locale = await prompts.input({
    message: '언어(locale):',
    default: CONFIG_DEFAULTS.locale,
  });

  // Step 5 — invite URL: print, then open in the browser (skipped/mocked in tests).
  const inviteUrl = buildInviteUrl(clientId.trim());
  log('\n5단계 — 봇 초대 링크');
  log(`  ${inviteUrl}`);
  log('  브라우저에서 이 링크를 열어 내 서버에 봇을 초대하세요.');
  try {
    await openUrl(inviteUrl);
  } catch {
    log('  브라우저를 열지 못했습니다. 위 링크를 직접 방문하세요.');
  }

  // Step 6 — write config.json (0600), merging entered values over CONFIG_DEFAULTS.
  // Role allowlists are left EMPTY (from CONFIG_DEFAULTS.auth): deny-by-default until
  // an admin sets them in Discord via `/config` (roles are per-server, §7.1).
  const chosenLocale = locale.trim() || CONFIG_DEFAULTS.locale;
  const config: AppConfig = {
    ...CONFIG_DEFAULTS,
    version: CONFIG_VERSION,
    discord: { token: token.trim(), clientId: clientId.trim() },
    defaults: {
      ...CONFIG_DEFAULTS.defaults,
      mode: 'claude',
      claudeModel: claudeModel.trim() || CONFIG_DEFAULTS.defaults.claudeModel,
      codexHome: codexHome.trim() || CONFIG_DEFAULTS.defaults.codexHome,
    },
    locale: chosenLocale,
  };

  store.save(config);
  logger.info('setup wrote config', { path: store.configPath, clientId: config.discord.clientId });
  log(`\n설정을 저장했어요: ${store.configPath} (권한 600)`);
  // Guidance: roles move from the terminal to Discord's `/config` (§7.1). Render it
  // in the config's locale so the message matches the operator's chosen language.
  setLocale(chosenLocale as Locale);
  log(`\n${t('setup.rolesInDiscord')}`);
  log('이제 `node dist/cli.js` 로 봇을 실행하세요.');
}
