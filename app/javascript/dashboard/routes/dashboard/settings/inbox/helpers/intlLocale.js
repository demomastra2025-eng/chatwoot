const isSupportedLocale = tag => {
  try {
    return Intl.DateTimeFormat.supportedLocalesOf([tag]).length > 0;
  } catch {
    return false;
  }
};

// Turns the interface language code («ru», «pt_BR») into a locale that Intl
// understands. Dates and language names follow the interface language, never
// the language of the browser.
export const getIntlLocale = rawLocale => {
  const normalizedLocale = String(rawLocale || 'en').replace(/_/g, '-');

  if (isSupportedLocale(normalizedLocale)) {
    return normalizedLocale;
  }

  const baseLocale = normalizedLocale.split('-')[0];
  return isSupportedLocale(baseLocale) ? baseLocale : 'en';
};

const capitalize = text => text.charAt(0).toLocaleUpperCase() + text.slice(1);

// «ru» -> «Русский», «en_US» -> «Американский английский». The code itself
// is the fallback for anything Intl does not know.
export const getLanguageName = (code, rawLocale) => {
  const value = String(code || '').trim();
  if (!value) {
    return '';
  }

  try {
    const names = new Intl.DisplayNames([getIntlLocale(rawLocale)], {
      type: 'language',
      fallback: 'none',
    });
    const name = names.of(value.replace(/_/g, '-'));
    return name ? capitalize(name) : value;
  } catch {
    return value;
  }
};
