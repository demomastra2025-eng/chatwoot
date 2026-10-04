#!/usr/bin/env node
/* eslint-disable no-console */
/**
 * Finds colour utility classes that are used in the sources but have no rule
 * in the built CSS (for example `bg-amber-50` when the Tailwind theme has no
 * `amber`). Such classes silently render nothing.
 *
 * Usage (after `bin/vite build`, which writes public/vite/assets/*.css):
 *   node script/design/check-unresolved-classes.js
 *     [--css <file-or-dir> ...]   built CSS to read (default: public/vite)
 *     [--root <dir>]              repository root to scan (default: cwd)
 *     [--baseline <file>]         default: script/design/unresolved-classes.baseline.json
 *     [--update-baseline]         rewrite the baseline with the current counts
 *     [--list]                    print every unresolved class per file
 *     [--top <n>]                 files shown in the summary (default 20)
 *
 * The baseline stores, per file, how many distinct unresolved classes it may
 * still contain. The check fails when a file goes above its allowance (or a
 * new file appears), so the number can only go down. When a screen is fixed,
 * run with --update-baseline and commit the smaller baseline.
 */
const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const option = name => {
  const index = args.indexOf(name);
  return index === -1 ? null : args[index + 1];
};
const optionList = name =>
  args.reduce((list, arg, index) => {
    if (arg === name && args[index + 1]) list.push(args[index + 1]);
    return list;
  }, []);

const root = path.resolve(option('--root') || process.cwd());
const cssInputs = optionList('--css');
const baselinePath = path.resolve(
  option('--baseline') ||
    path.join(__dirname, 'unresolved-classes.baseline.json')
);
const topCount = Number(option('--top') || 20);

const SOURCE_DIRS = [
  { dir: 'app/javascript', extensions: ['.vue', '.js', '.ts'] },
  { dir: 'app/views', extensions: ['.erb'] },
];
const IGNORED_FILE = /(\.spec|\.test)\.[jt]s$|\/specs?\/|\/__tests__\//;

const UTILITIES =
  'bg|text|border(?:-[xytrbse])?|ring(?:-offset)?|outline|divide|from|via|to|fill|stroke|placeholder|accent|caret|decoration|shadow';
const PALETTE =
  'slate|gray|zinc|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose|woot|black';
const COLOUR_UTILITY = new RegExp(
  `^!?-?(?:${UTILITIES})-(?:n-[a-z0-9-]+|(?:${PALETTE})-\\d{2,3}|white|black|transparent|current|inherit)(?:/(?:\\d{1,3}|\\[[^\\]]+\\]))?$`
);
const VARIANT =
  /^(?:[a-z0-9@-]+(?:\/[\w-]+)?|[a-z0-9@-]*\[[^\]]+\](?:\/[\w-]+)?)$/;

const walk = (dir, extensions, files = []) => {
  if (!fs.existsSync(dir)) return files;
  fs.readdirSync(dir, { withFileTypes: true }).forEach(entry => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name !== 'node_modules') walk(full, extensions, files);
    } else if (extensions.some(ext => entry.name.endsWith(ext))) {
      files.push(full);
    }
  });
  return files;
};

const unescapeCss = value =>
  value
    .replace(/\\([0-9a-fA-F]{1,6})\s?/g, (_, hex) =>
      String.fromCodePoint(parseInt(hex, 16))
    )
    .replace(/\\(.)/g, '$1');

const readCssClasses = () => {
  const inputs = cssInputs.length
    ? cssInputs
    : [path.join(root, 'public/vite')];
  const files = inputs.flatMap(input => {
    const full = path.resolve(input);
    if (!fs.existsSync(full)) return [];
    return fs.statSync(full).isDirectory() ? walk(full, ['.css']) : [full];
  });
  const classes = new Set();
  files.forEach(file => {
    const css = fs.readFileSync(file, 'utf8');
    const selector = /\.((?:\\[0-9a-fA-F]{1,6}\s?|\\.|[\w-])+)/g;
    let match = selector.exec(css);
    while (match) {
      classes.add(unescapeCss(match[1]));
      match = selector.exec(css);
    }
  });
  return { files, classes };
};

// Split `md:hover:[&>svg]:text-n-slate-11` on colons outside brackets.
const splitVariants = token => {
  const parts = [];
  let depth = 0;
  let current = '';
  [...token].forEach(char => {
    if (char === '[') depth += 1;
    if (char === ']') depth -= 1;
    if (char === ':' && depth === 0) {
      parts.push(current);
      current = '';
    } else {
      current += char;
    }
  });
  parts.push(current);
  return parts;
};

const isColourUtility = token => {
  if (/[${}#<>?]/.test(token.replace(/\[[^\]]*\]/g, ''))) return false;
  const parts = splitVariants(token);
  const base = parts.pop();
  return COLOUR_UTILITY.test(base) && parts.every(part => VARIANT.test(part));
};

const candidateTokens = source =>
  source
    .replace(/<style[\s\S]*?<\/style>/g, '')
    .split('\n')
    .filter(line => !line.includes('@apply'))
    .join('\n')
    .split(/[\s"'`,{}()]+/)
    .map(token => token.replace(/^[<>=.:]+/, '').replace(/[;:.>]+$/, ''))
    .filter(token => token && isColourUtility(token));

const scanSources = classes => {
  const unresolved = {};
  SOURCE_DIRS.forEach(({ dir, extensions }) => {
    walk(path.join(root, dir), extensions).forEach(file => {
      const relative = path.relative(root, file).split(path.sep).join('/');
      if (IGNORED_FILE.test(`/${relative}`)) return;
      const missing = new Set(
        candidateTokens(fs.readFileSync(file, 'utf8')).filter(
          token => !classes.has(token)
        )
      );
      if (missing.size) unresolved[relative] = [...missing].sort();
    });
  });
  return unresolved;
};

const { files: cssFiles, classes } = readCssClasses();
if (!cssFiles.length || classes.size < 500) {
  console.error(
    `No built CSS found (${cssFiles.length} files, ${classes.size} classes). Run a vite build first or pass --css.`
  );
  process.exit(2);
}

const unresolved = scanSources(classes);
const counts = Object.fromEntries(
  Object.entries(unresolved)
    .map(([file, tokens]) => [file, tokens.length])
    .sort(([a], [b]) => a.localeCompare(b))
);
const total = Object.values(counts).reduce((sum, count) => sum + count, 0);

console.log(
  `Read ${classes.size} classes from ${cssFiles.length} CSS files; ${total} unresolved colour classes in ${Object.keys(counts).length} files.`
);
Object.entries(counts)
  .sort(([, a], [, b]) => b - a)
  .slice(0, topCount)
  .forEach(([file, count]) =>
    console.log(`  ${String(count).padStart(4)}  ${file}`)
  );

if (args.includes('--list')) {
  Object.entries(unresolved).forEach(([file, tokens]) => {
    console.log(`\n${file}\n  ${tokens.join('\n  ')}`);
  });
}

if (args.includes('--update-baseline')) {
  fs.writeFileSync(baselinePath, `${JSON.stringify(counts, null, 2)}\n`);
  console.log(`Baseline written to ${path.relative(root, baselinePath)}.`);
  process.exit(0);
}

const baseline = fs.existsSync(baselinePath)
  ? JSON.parse(fs.readFileSync(baselinePath, 'utf8'))
  : {};
const regressions = Object.entries(unresolved).filter(
  ([file, tokens]) => tokens.length > (baseline[file] || 0)
);
const improved = Object.keys(baseline).filter(
  file => (counts[file] || 0) < baseline[file]
);

if (improved.length) {
  console.log(
    `\n${improved.length} files are below their baseline; run with --update-baseline to lock that in.`
  );
}
if (regressions.length) {
  console.error('\nUnresolved colour classes above the baseline:');
  regressions.forEach(([file, tokens]) => {
    console.error(
      `  ${file} (${tokens.length}, baseline ${baseline[file] || 0}): ${tokens.join(' ')}`
    );
  });
  console.error(
    '\nUse n-* design tokens (see app/javascript/dashboard/components-next/ds/README.md).'
  );
  process.exit(1);
}
console.log('No new unresolved colour classes.');
