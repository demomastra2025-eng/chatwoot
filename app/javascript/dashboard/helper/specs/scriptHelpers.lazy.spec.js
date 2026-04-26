import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const currentDir = dirname(fileURLToPath(import.meta.url));
const source = () =>
  readFileSync(resolve(currentDir, '../scriptHelpers.js'), 'utf8');

describe('script helper startup dependencies', () => {
  it('does not eagerly load analytics or audio helpers at app startup', () => {
    expect(source()).not.toMatch(
      /^import\s+AnalyticsHelper\s+from\s+['"].+AnalyticsHelper['"];?$/m
    );
    expect(source()).not.toMatch(
      /^import\s+DashboardAudioNotificationHelper\s+from\s+['"].+DashboardAudioNotificationHelper['"];?$/m
    );
  });
});
