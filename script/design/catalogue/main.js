/* eslint-disable @intlify/vue-i18n/no-missing-keys -- Standalone catalogue messages are loaded from its adjacent messages.js. */
import { createApp, h, ref, watch } from 'vue';
import { createI18n } from 'vue-i18n';
import { createStore } from 'vuex';
import FloatingVue from 'floating-vue';
import { directive as onClickaway } from 'vue3-click-away';
import Gallery from './Gallery.vue';
import galleryMessages from './messages';
import ruComponents from '../../../app/javascript/dashboard/i18n/locale/ru/components.json';
import kkComponents from '../../../app/javascript/dashboard/i18n/locale/kk/components.json';
import enComponents from '../../../app/javascript/dashboard/i18n/locale/en/components.json';
import ruDesign from '../../../app/javascript/dashboard/i18n/locale/ru/designSystem.json';
import kkDesign from '../../../app/javascript/dashboard/i18n/locale/kk/designSystem.json';
import enDesign from '../../../app/javascript/dashboard/i18n/locale/en/designSystem.json';
import 'floating-vue/dist/style.css';
import './catalogue.scss';

const i18n = createI18n({
  legacy: false,
  locale: 'ru',
  fallbackLocale: 'en',
  messages: {
    ru: { ...ruComponents, ...ruDesign, ...galleryMessages.ru },
    kk: { ...kkComponents, ...kkDesign, ...galleryMessages.kk },
    en: { ...enComponents, ...enDesign, ...galleryMessages.en },
  },
});
// Isolated UI host. It never imports the application store, router or API.
const store = createStore({ getters: { 'accounts/isRTL': () => false } });
const dark = ref(false);
const setTheme = value => {
  dark.value = value;
  document.documentElement.classList.toggle('dark', value);
  document.documentElement.style.colorScheme = value ? 'dark' : 'light';
};
watch(i18n.global.locale, value => {
  document.documentElement.lang = value;
  document.title = i18n.global.t('CATALOGUE.TITLE');
});

window.onelinkCatalogue = {
  source: '90530b5976aaa5e6b66a21a84c76d9dad462d7e3',
  errors: [],
};
const app = createApp({
  setup: () => () => h(Gallery, { dark: dark.value, onTheme: setTheme }),
});
app.config.errorHandler = error => {
  window.onelinkCatalogue.errors.push(String(error));
  // eslint-disable-next-line no-console -- Surface unexpected rendering failures in browser diagnostics.
  console.error(error);
};
app.use(i18n);
app.use(store);
app.use(FloatingVue, { instantMove: true, disposeTimeout: 1000 });
app.directive('on-clickaway', onClickaway);
app.mount('#app');
