import { createI18n } from 'vue-i18n';
import ru from './ru.json';
import en from './en.json';
import kk from './kk.json';

const DEFAULT_LOCALE = 'ru';
const messages = { ru, en, kk };

// Unsupported locales fall back to English instead of showing raw message keys.
export const createSuperAdminI18n = locale =>
  createI18n({
    legacy: false,
    locale: messages[locale] ? locale : DEFAULT_LOCALE,
    fallbackLocale: 'en',
    messages,
  });

export default messages;
