import { SERVICE_NAME, type ResolvedServiceDeps, type ServiceInstaller } from './types.js';

// Windows auto-start via the Task Scheduler (schtasks) with an onlogon trigger. This
// needs NO admin rights, which is the trade-off: onlogon runs the bot when the user
// logs in but does NOT auto-restart it if it crashes (unlike launchd KeepAlive /
// systemd Restart=always). That limitation is surfaced in the install output.

// The command the scheduled task runs: the absolute node binary + this package's CLI
// entry, each quoted so paths with spaces survive. Passed to schtasks as one /tr arg.
function taskCommand(d: ResolvedServiceDeps): string {
  return `"${d.nodePath}" "${d.cliEntry}"`;
}

export function createSchtasksInstaller(d: ResolvedServiceDeps): ServiceInstaller {
  return {
    async install() {
      const res = await d.run('schtasks', [
        '/create',
        '/tn',
        SERVICE_NAME,
        '/sc',
        'onlogon',
        '/tr',
        taskCommand(d),
        '/f',
      ]);
      if (res.code !== 0) {
        d.log('서비스 등록에 실패했습니다 (schtasks /create).');
        if (res.stderr.trim()) d.log(`  ${res.stderr.trim()}`);
        d.log('수동 방법은 README 를 참고하세요.');
        return false;
      }
      d.log('로그인 시 자동 실행되도록 작업 스케줄러에 등록했습니다.');
      d.log(`  작업 이름: ${SERVICE_NAME}`);
      d.log(`  실행: ${taskCommand(d)}`);
      d.log('  참고: onlogon 작업은 크래시 시 자동 재시작을 보장하지 않습니다.');
      return true;
    },

    async uninstall() {
      const res = await d.run('schtasks', ['/delete', '/tn', SERVICE_NAME, '/f']);
      if (res.code !== 0) {
        d.log('자동 실행 등록 해제에 실패했습니다 (schtasks /delete).');
        if (res.stderr.trim()) d.log(`  ${res.stderr.trim()}`);
        d.log('수동 방법은 README 를 참고하세요.');
        return false;
      }
      d.log('자동 실행 등록을 해제했습니다.');
      return true;
    },

    async status() {
      const res = await d.run('schtasks', ['/query', '/tn', SERVICE_NAME]);
      if (res.code === 0) {
        d.log(`자동 실행 등록: 있음 (작업 ${SERVICE_NAME})`);
        if (res.stdout.trim()) d.log(res.stdout.trim());
      } else {
        d.log(`자동 실행 등록: 없음 (작업 ${SERVICE_NAME})`);
      }
      return true;
    },

    async restart() {
      // onlogon tasks have no "restart"; end the running instance (best-effort) then
      // run it again.
      await d.run('schtasks', ['/end', '/tn', SERVICE_NAME]).catch(() => undefined);
      const res = await d.run('schtasks', ['/run', '/tn', SERVICE_NAME]);
      if (res.code !== 0) {
        d.log('서비스 재시작에 실패했습니다 (schtasks /run).');
        if (res.stderr.trim()) d.log(`  ${res.stderr.trim()}`);
        d.log('수동 방법은 README 를 참고하세요.');
        return false;
      }
      d.log('서비스를 재시작했습니다.');
      return true;
    },
  };
}
