import initialMessages from './initialMessages';

const FALLBACK_LOCALE = 'ru';

export const STARTUP_LOCALES = Object.freeze(Object.keys(initialMessages));

const localeLoaders = {
  ar: () => import('./locale/ar'),
  bg: () => import('./locale/bg'),
  ca: () => import('./locale/ca'),
  cs: () => import('./locale/cs'),
  da: () => import('./locale/da'),
  de: () => import('./locale/de'),
  el: () => import('./locale/el'),
  en: () => import('./locale/en'),
  es: () => import('./locale/es'),
  fa: () => import('./locale/fa'),
  fi: () => import('./locale/fi'),
  fr: () => import('./locale/fr'),
  he: () => import('./locale/he'),
  hi: () => import('./locale/hi'),
  hu: () => import('./locale/hu'),
  id: () => import('./locale/id'),
  is: () => import('./locale/is'),
  it: () => import('./locale/it'),
  ja: () => import('./locale/ja'),
  kk: () => import('./locale/kk'),
  ko: () => import('./locale/ko'),
  lt: () => import('./locale/lt'),
  lv: () => import('./locale/lv'),
  ml: () => import('./locale/ml'),
  nl: () => import('./locale/nl'),
  no: () => import('./locale/no'),
  pl: () => import('./locale/pl'),
  pt: () => import('./locale/pt'),
  pt_BR: () => import('./locale/pt_BR'),
  ro: () => import('./locale/ro'),
  ru: () => import('./locale/ru'),
  sk: () => import('./locale/sk'),
  sr: () => import('./locale/sr'),
  sv: () => import('./locale/sv'),
  ta: () => import('./locale/ta'),
  th: () => import('./locale/th'),
  tr: () => import('./locale/tr'),
  uk: () => import('./locale/uk'),
  vi: () => import('./locale/vi'),
  zh_CN: () => import('./locale/zh_CN'),
  zh_TW: () => import('./locale/zh_TW'),
};

export const SUPPORTED_LOCALES = Object.freeze(Object.keys(localeLoaders));

let dashboardI18n = null;

export const registerDashboardI18n = i18n => {
  dashboardI18n = i18n?.global || i18n || null;
};

const localeByLowercase = SUPPORTED_LOCALES.reduce((acc, locale) => {
  acc[locale.toLowerCase()] = locale;
  return acc;
}, {});

const normalizeLocaleCode = locale =>
  String(locale || '')
    .trim()
    .replace('-', '_');

export const resolveLocaleCode = locale => {
  const normalizedLocale = normalizeLocaleCode(locale);
  const exactLocale = localeByLowercase[normalizedLocale.toLowerCase()];
  if (exactLocale) return exactLocale;

  const languageCode = normalizedLocale.split('_')[0]?.toLowerCase();
  return localeByLowercase[languageCode] || FALLBACK_LOCALE;
};

export const loadLocaleMessages = async (i18n, locale) => {
  const resolvedLocale = resolveLocaleCode(locale);

  if (i18n.availableLocales?.includes(resolvedLocale)) {
    return resolvedLocale;
  }

  const localeModule = await localeLoaders[resolvedLocale]();
  i18n.setLocaleMessage(resolvedLocale, localeModule.default || localeModule);

  return resolvedLocale;
};

export const setI18nLocale = async (i18n, locale) => {
  const resolvedLocale = await loadLocaleMessages(i18n, locale);

  if (
    i18n.locale &&
    typeof i18n.locale === 'object' &&
    'value' in i18n.locale
  ) {
    i18n.locale.value = resolvedLocale;
  } else {
    i18n.locale = resolvedLocale;
  }

  return resolvedLocale;
};

export const setDashboardLocale = locale => {
  if (!dashboardI18n) {
    throw new Error('Dashboard i18n instance is not registered');
  }

  return setI18nLocale(dashboardI18n, locale);
};
