import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const currentDir = dirname(fileURLToPath(import.meta.url));
const source = () => readFileSync(resolve(currentDir, '../routes.js'), 'utf8');

describe('v3 public auth route code-splitting', () => {
  it('keeps non-login auth pages lazy so login does not load every auth screen', () => {
    const staticVueImports = source()
      .split('\n')
      .filter(line => /^import\s+\w+\s+from\s+['"].+\.vue['"];?$/.test(line));

    expect(staticVueImports).toEqual([
      "import Login from './login/Index.vue';",
    ]);
  });
});
