// The app Tailwind config plus the sample page sources.
const base = require('../../../tailwind.config.js');

module.exports = {
  ...base,
  content: [...base.content, './script/design/sample/**/*.vue'],
};
