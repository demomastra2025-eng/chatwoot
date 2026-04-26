import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const currentDir = dirname(fileURLToPath(import.meta.url));
const source = () => readFileSync(resolve(currentDir, '../index.js'), 'utf8');

describe('dashboard router startup dependencies', () => {
  it('does not eagerly load analytics helper before route tracking', () => {
    expect(source()).not.toMatch(
      /^import\s+AnalyticsHelper\s+from\s+['"].+AnalyticsHelper['"];?$/m
    );
  });
});
