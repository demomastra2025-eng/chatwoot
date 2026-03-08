const languages = [
  {
    name: 'English',
    id: 'en',
  },
  {
    name: 'Russian',
    id: 'ru',
  },
  {
    name: 'Kazakh',
    id: 'kk',
  },
];

export const getLanguageName = (languageCode = '') => {
  const languageObj =
    languages.find(language => language.id === languageCode) || {};
  return languageObj.name || '';
};

export const getLanguageDirection = (languageCode = '') => {
  const rtlLanguageIds = ['ar', 'as', 'fa', 'he', 'ku', 'ur'];
  return rtlLanguageIds.includes(languageCode);
};

export default languages;
