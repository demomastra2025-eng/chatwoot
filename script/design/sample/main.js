import { createApp, nextTick } from 'vue';
import { createI18n } from 'vue-i18n';
import en from 'dashboard/i18n/locale/en/designSystem.json';
import ru from 'dashboard/i18n/locale/ru/designSystem.json';
import kk from 'dashboard/i18n/locale/kk/designSystem.json';
import Showcase from './Showcase.vue';
import './sample.scss';

// ?theme=dark switches the theme the same way the app does (body.dark);
// ?locale=en|ru|kk picks the component language; ?tooltip=1 opens the chart
// tooltip through the keyboard path so a static screenshot shows it;
// ?table=1 switches the charts to their table view.
const params = new URLSearchParams(window.location.search);
const dark = params.get('theme') === 'dark';
document.body.classList.toggle('dark', dark);
document.documentElement.style.setProperty(
  'color-scheme',
  dark ? 'dark' : 'light'
);

const i18n = createI18n({
  legacy: false,
  locale: params.get('locale') || 'ru',
  fallbackLocale: 'en',
  messages: { en, ru, kk },
});

createApp(Showcase).use(i18n).mount('#app');

if (params.get('table')) {
  document
    .querySelectorAll('[data-test-id="ds-chart-table-toggle"]')
    .forEach(button => button.click());
}

if (params.get('tooltip')) {
  nextTick(() => {
    const plot = document.querySelector('[role="group"]');
    plot?.focus();
    ['ArrowLeft', 'ArrowLeft', 'ArrowLeft', 'ArrowLeft'].forEach(key =>
      plot?.dispatchEvent(new KeyboardEvent('keydown', { key }))
    );
  });
}
