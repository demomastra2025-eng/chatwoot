import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const currentDir = dirname(fileURLToPath(import.meta.url));
const source = () =>
  readFileSync(resolve(currentDir, '../actionCable.js'), 'utf8');

describe('action cable startup dependencies', () => {
  it('does not eagerly load dashboard audio notification helper', () => {
    expect(source()).not.toMatch(
      /^import\s+DashboardAudioNotificationHelper\s+from\s+['"].+DashboardAudioNotificationHelper['"];?$/m
    );
  });
});
