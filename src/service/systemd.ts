import * as path from 'node:path';
import { SERVICE_NAME, type ResolvedServiceDeps, type ServiceInstaller } from './types.js';
import { ensureRunScript } from './runScript.js';

// Linux auto-start via a systemd --user unit. Restart=always keeps it alive; a
// best-effort `loginctl enable-linger` lets it run without an active login session
// (so it survives reboot before the user logs in). ExecStart runs the shared run.sh
// wrapper for node-version independence.

// The unit path, derived from just the home dir. Exported so the update layer's
// restart-strategy detection can check for a systemd install WITHOUT duplicating the
// path convention (update/environment.ts old-install fallback, §3.2).
export function systemdUnitPath(home: string): string {
  return path.join(home, '.config', 'systemd', 'user', `${SERVICE_NAME}.service`);
}

function unitPath(d: ResolvedServiceDeps): string {
  return systemdUnitPath(d.home);
}

function buildUnit(scriptPath: string): string {
  return (
    [
      '[Unit]',
      'Description=discord-agent-bridge (Discord <-> agent bridge)',
      'After=network-online.target',
      'Wants=network-online.target',
      '',
      '[Service]',
      'Type=simple',
      `ExecStart=/bin/bash ${scriptPath}`,
      'Restart=always',
      'RestartSec=5',
      '',
      '[Install]',
      'WantedBy=default.target',
      '',
    ].join('\n')
  );
}

export function createSystemdInstaller(d: ResolvedServiceDeps): ServiceInstaller {
  const unit = unitPath(d);

  return {
    async install() {
      const scriptPath = ensureRunScript(d);
      d.fs.mkdirp(path.dirname(unit));
      d.fs.writeFile(unit, buildUnit(scriptPath), 0o644);

      await d.run('systemctl', ['--user', 'daemon-reload']);
      const enabled = await d.run('systemctl', ['--user', 'enable', '--now', SERVICE_NAME]);
      if (enabled.code !== 0) {
        d.log('서비스 등록에 실패했습니다 (systemctl enable --now).');
        if (enabled.stderr.trim()) d.log(`  ${enabled.stderr.trim()}`);
        d.log('수동 방법은 README 를 참고하세요.');
        return false;
      }

      d.log('서비스를 등록하고 시작했습니다.');
      d.log(`  unit: ${unit}`);
      // Linger lets the service start at boot before the user logs in. Non-fatal: on
      // failure the service still runs while the user is logged in.
      const linger = await d.run('loginctl', ['enable-linger', d.username]).catch(() => null);
      if (!linger || linger.code !== 0) {
        d.log('  참고: loginctl enable-linger 실패 — 로그인 전 자동 시작이 안 될 수 있습니다.');
        d.log('        필요하면 `sudo loginctl enable-linger <사용자>` 를 직접 실행하세요.');
      }
      return true;
    },

    async uninstall() {
      await d.run('systemctl', ['--user', 'disable', '--now', SERVICE_NAME]).catch(() => undefined);
      if (d.fs.exists(unit)) d.fs.remove(unit);
      await d.run('systemctl', ['--user', 'daemon-reload']).catch(() => undefined);
      d.log('서비스를 중지하고 자동 실행 등록을 해제했습니다.');
      return true;
    },

    async status() {
      const res = await d.run('systemctl', ['--user', 'status', SERVICE_NAME]);
      d.log(`자동 실행 등록: ${d.fs.exists(unit) ? '있음' : '없음'} (${unit})`);
      if (res.stdout.trim()) d.log(res.stdout.trim());
      // `systemctl status` exits non-zero for inactive/failed/missing units — that is
      // informational here, not a command failure, so status still counts as success.
      return true;
    },

    async restart() {
      const res = await d.run('systemctl', ['--user', 'restart', SERVICE_NAME]);
      if (res.code !== 0) {
        d.log('서비스 재시작에 실패했습니다 (systemctl restart).');
        if (res.stderr.trim()) d.log(`  ${res.stderr.trim()}`);
        d.log('수동 방법은 README 를 참고하세요.');
        return false;
      }
      d.log('서비스를 재시작했습니다.');
      return true;
    },
  };
}
