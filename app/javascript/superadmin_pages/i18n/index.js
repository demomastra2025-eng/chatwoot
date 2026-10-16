import { createI18n } from 'vue-i18n';
import designSystem from 'dashboard/i18n/locale/ru/designSystem.json';
import ru from './ru.json';

// The super admin is Russian only (owner decision: ru-only freeze). The words of the design system
// components (status words, empty and error states, chart table) come from the operator app's own
// Russian file, so both apps say the same thing. en.json and kk.json are kept untouched and not loaded.
export const createSuperAdminI18n = () =>
  createI18n({
    legacy: false,
    locale: 'ru',
    fallbackLocale: 'ru',
    messages: { ru: { ...designSystem, ...ru } },
  });

export default { ru };
