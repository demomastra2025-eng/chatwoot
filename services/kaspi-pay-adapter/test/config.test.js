import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import test from 'node:test';

const readAppConfig = env => {
  const script = "import('./src/config.js').then(({ APP }) => process.stdout.write(JSON.stringify(APP)))";
  const output = execFileSync(process.execPath, ['--input-type=module', '--eval', script], {
    cwd: new URL('..', import.meta.url),
    env: {
      ...process.env,
      TOKEN_SECRET_KEY: process.env.TOKEN_SECRET_KEY || '00'.repeat(32),
      ...env,
    },
    encoding: 'utf8',
  });

  return JSON.parse(output.trim().split('\n').at(-1));
};

test('Kaspi mobile fingerprint uses current verified defaults', () => {
  const app = readAppConfig({
    APP_VERSION: '',
    APP_BUILD: '',
  });

  assert.equal(app.version, '4.112.1');
  assert.equal(app.build, '1107');
});

test('Kaspi mobile fingerprint can be updated from environment without rebuilding', () => {
  const app = readAppConfig({
    APP_VERSION: '4.999.0',
    APP_BUILD: '1999',
    APP_PLATFORM_VER: '19.0',
    APP_MODEL: 'iPhone99,1',
  });

  assert.equal(app.version, '4.999.0');
  assert.equal(app.build, '1999');
  assert.equal(app.platformVer, '19.0');
  assert.equal(app.model, 'iPhone99,1');
});
