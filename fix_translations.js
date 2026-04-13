const fs = require('fs');
const path = require('path');

const localesDir = path.join(__dirname, 'app/javascript/dashboard/i18n/locale');
let changedFiles = 0;

if (fs.existsSync(localesDir)) {
  const locales = fs.readdirSync(localesDir);
  locales.forEach(locale => {
    const file = path.join(localesDir, locale, 'integrations.json');
    if (fs.existsSync(file)) {
      let content = fs.readFileSync(file, 'utf8');
      
      // Look for the exact matching placeholder and replace the curly braces with vue-i18n escape syntax
      const search = /"PLACEHOLDER": "\{\\n  \\"url\\": \\"https:\/\/example.com\/mcp\\"\\n\}"/g;
      const replace = '"PLACEHOLDER": "{ \'{\' }\\n  \\"url\\": \\"https://example.com/mcp\\"\\n{ \'}\' }"';
      
      if (search.test(content)) {
        content = content.replace(search, replace);
        fs.writeFileSync(file, content);
        changedFiles++;
      }
    }
  });
}
console.log(`Updated ${changedFiles} translation files.`);
