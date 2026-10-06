#!/usr/bin/env node
/* eslint-disable no-console */
// The fixture records every declaration in the production theme at 07e22bbfd.
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '../..');
const fixture = require('./prod-next-colors.json');
const source = fs.readFileSync(
  path.join(root, 'app/javascript/dashboard/assets/scss/_next-colors.scss'),
  'utf8'
);
const blocks = [
  ...source.matchAll(/^ {2}(:root|\.dark) \{\n([\s\S]*?)^ {2}\}/gm),
];
const errors = [];

Object.keys(fixture).forEach(selector => {
  if (blocks.filter(match => match[1] === selector).length !== 1) {
    errors.push(`Expected one theme block: ${selector}`);
  }
});

Object.entries(fixture).forEach(([selector, expected]) => {
  const block = blocks.find(match => match[1] === selector);
  if (!block) {
    errors.push(`Missing theme block: ${selector}`);
    return;
  }

  const declarations = new Map();
  [...block[2].matchAll(/^ {4}(--[\w-]+): ([^;]+);$/gm)].forEach(match => {
    if (declarations.has(match[1])) {
      errors.push(`Duplicate ${selector} ${match[1]}`);
    }
    declarations.set(match[1], match[2]);
  });
  Object.entries(expected).forEach(([name, value]) => {
    if (declarations.get(name) !== value) {
      errors.push(
        `${selector} ${name}: expected ${value}, got ${declarations.get(name)}`
      );
    }
  });
});

const scan = directory => {
  if (!fs.existsSync(directory)) return;
  fs.readdirSync(directory, { withFileTypes: true }).forEach(entry => {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      scan(file);
    } else if (/\.(vue|erb|haml|slim|html)$/.test(entry.name)) {
      if (fs.readFileSync(file, 'utf8').includes('theme-graphite')) {
        errors.push(`Graphite class in ${path.relative(root, file)}`);
      }
    }
  });
};
scan(path.join(root, 'app/views'));
scan(path.join(root, 'enterprise/app/views'));
scan(path.join(root, 'app/javascript'));
scan(path.join(root, 'enterprise/app/javascript'));

if (errors.length) {
  console.error(errors.join('\n'));
  process.exit(1);
}
console.log('Production theme values and template class guard passed.');
