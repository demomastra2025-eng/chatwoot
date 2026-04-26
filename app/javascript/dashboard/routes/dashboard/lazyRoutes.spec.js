import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const currentDir = dirname(fileURLToPath(import.meta.url));

const readRouteFile = relativePath => {
  return readFileSync(resolve(currentDir, relativePath), 'utf8');
};

const expectNoStaticVueImports = relativePath => {
  const source = readRouteFile(relativePath);
  const staticVueImports = source
    .split('\n')
    .filter(line => /^import\s+\w+\s+from\s+['"].+\.vue['"];?$/.test(line));

  expect(staticVueImports).toEqual([]);
};

describe('dashboard route code-splitting', () => {
  it('keeps heavy Captain route components lazy', () => {
    expectNoStaticVueImports('captain/captain.routes.js');
  });

  it('keeps heavy inbox setup route components lazy', () => {
    expectNoStaticVueImports('settings/inbox/inbox.routes.js');
  });

  it('keeps reports route components lazy', () => {
    expectNoStaticVueImports('settings/reports/reports.routes.js');
  });
});
