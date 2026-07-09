import * as path from 'node:path';
import { SERVICE_LABEL, type ResolvedServiceDeps, type ServiceInstaller } from './types.js';
import { ensureRunScript } from './runScript.js';

// macOS auto-start via a per-user LaunchAgent (launchd). RunAtLoad + KeepAlive means
// it starts on login and is relaunched if it exits — the closest launchd equivalent
// of "start at boot and keep alive".

// The plist path, derived from just the home dir. Exported so the update layer's
// restart-strategy detection can check for a launchd install WITHOUT duplicating the
// path convention (update/environment.ts old-install fallback, §3.2).
export function launchdPlistPath(home: string): string {
  return path.join(home, 'Library', 'LaunchAgents', `${SERVICE_LABEL}.plist`);
}

function plistPath(d: ResolvedServiceDeps): string {
  return launchdPlistPath(d.home);
}
function outLogPath(d: ResolvedServiceDeps): string {
  return path.join(d.baseDir, 'agent.out.log');
}
function errLogPath(d: ResolvedServiceDeps): string {
  return path.join(d.baseDir, 'agent.err.log');
}

// Escape the five XML predefined entities for text placed inside <string> nodes.
function xml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

function buildPlist(d: ResolvedServiceDeps, scriptPath: string): string {
  return (
    [
      '<?xml version="1.0" encoding="UTF-8"?>',
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
      '<plist version="1.0">',
      '<dict>',
      '  <key>Label</key>',
      `  <string>${SERVICE_LABEL}</string>`,
      '  <key>ProgramArguments</key>',
      '  <array>',
      '    <string>/bin/bash</string>',
      `    <string>${xml(scriptPath)}</string>`,
      '  </array>',
      '  <key>EnvironmentVariables</key>',
      '  <dict>',
      '    <key>HOME</key>',
      `    <string>${xml(d.home)}</string>`,
      '  </dict>',
      '  <key>RunAtLoad</key>',
      '  <true/>',
      '  <key>KeepAlive</key>',
      '  <true/>',
      '  <key>StandardOutPath</key>',
      `  <string>${xml(outLogPath(d))}</string>`,
      '  <key>StandardErrorPath</key>',
      `  <string>${xml(errLogPath(d))}</string>`,
      '</dict>',
      '</plist>',
      '',
    ].join('\n')
  );
}

export function createLaunchdInstaller(d: ResolvedServiceDeps): ServiceInstaller {
  const plist = plistPath(d);

  async function load(): Promise<boolean> {
    // Unload first (ignore the outcome — it fails harmlessly when not yet loaded),
    // then load with -w so it survives reboots.
    await d.run('launchctl', ['unload', plist]).catch(() => undefined);
    const res = await d.run('launchctl', ['load', '-w', plist]);
    return res.code === 0;
  }

  return {
    async install() {
      const scriptPath = ensureRunScript(d);
      d.fs.mkdirp(path.dirname(plist));
      d.fs.writeFile(plist, buildPlist(d, scriptPath), 0o644);
      if (!(await load())) {
        d.log('서비스 등록에 실패했습니다 (launchctl load).');
        d.log('수동 방법은 README 를 참고하세요.');
        return false;
      }
      d.log('서비스를 등록하고 시작했습니다. 재부팅/로그인 시 자동 실행됩니다.');
      d.log(`  plist: ${plist}`);
      d.log(`  로그: ${outLogPath(d)}`);
      d.log(`        ${errLogPath(d)}`);
      return true;
    },

    async uninstall() {
      await d.run('launchctl', ['unload', '-w', plist]).catch(() => undefined);
      if (d.fs.exists(plist)) d.fs.remove(plist);
      d.log('서비스를 중지하고 자동 실행 등록을 해제했습니다.');
      return true;
    },

    async status() {
      const res = await d.run('launchctl', ['list']);
      const running = res.stdout.split('\n').some((line) => line.includes(SERVICE_LABEL));
      d.log(`자동 실행 등록: ${d.fs.exists(plist) ? '있음' : '없음'} (${plist})`);
      d.log(`실행 중: ${running ? '예' : '아니오'}`);
      return true;
    },

    async restart() {
      if (!(await load())) {
        d.log('서비스 재시작에 실패했습니다 (launchctl load).');
        d.log('수동 방법은 README 를 참고하세요.');
        return false;
      }
      d.log('서비스를 재시작했습니다.');
      return true;
    },
  };
}
