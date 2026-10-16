import { readFileSync } from 'node:fs';
import { resolve as resolvePath } from 'node:path';
import { config, mount } from '@vue/test-utils';
import Index from '../views/dashboard/Index.vue';
import ru from '../i18n/ru.json';
import { createSuperAdminI18n } from '../i18n';

// The page installs its own Russian i18n; the plugin of the global test setup (the operator app) must not be
// installed next to it.
config.global.plugins = [];

const clinic = (id, name, extra = {}) => ({
  id,
  name,
  status: 'active',
  whatsapp: { state: 'none', label: 'Не подключен' },
  telephony: { state: 'none', label: 'Нет линий' },
  medelement: { state: 'none', label: 'Не настроен' },
  failed_messages: 0,
  needs_attention: false,
  ...extra,
});

const componentData = {
  healthAccounts: [
    clinic(1, 'Acme Inc'),
    clinic(2, 'Клиника «Сезим»', {
      status: 'suspended',
      whatsapp: { state: 'error', label: 'Требует авторизации' },
      failed_messages: 4,
      needs_attention: true,
    }),
    clinic(3, 'Медцентр «Достар»', {
      telephony: { state: 'healthy', label: '2 профилей OK' },
    }),
  ],
  healthSummary: {
    total_accounts: 3,
    needs_attention: 1,
    whatsapp_healthy: 0,
    telephony_healthy: 1,
    incomplete_sources: [],
    updated_at: '06:37:00',
  },
  chartData: [
    ['2026-09-16', 3],
    ['2026-09-17', 5],
  ],
};

const render = (data = componentData) =>
  mount(Index, {
    props: { componentData: data },
    global: { plugins: [createSuperAdminI18n()] },
  });

const rows = wrapper => wrapper.findAll('tbody tr');

describe('the «Сводка» body', () => {
  it('shows the four key figures of the summary', () => {
    const wrapper = render();
    const figures = wrapper.findAll('[data-test-id="ds-stat"]');

    expect(figures.map(figure => figure.find('dt').text())).toEqual([
      ru.DASHBOARD.KPI.CLINICS,
      ru.DASHBOARD.KPI.ATTENTION,
      ru.DASHBOARD.KPI.WHATSAPP,
      ru.DASHBOARD.KPI.TELEPHONY,
    ]);
    expect(figures.map(figure => figure.findAll('dd')[0].text())).toEqual([
      '3',
      '1',
      '0',
      '1',
    ]);
  });

  it('lists a row per clinic with a link to its card', () => {
    const wrapper = render();

    expect(rows(wrapper)).toHaveLength(3);
    const links = wrapper.findAll('tbody a').map(a => a.attributes('href'));
    expect(links).toContain('/super_admin/accounts/2');
    expect(wrapper.text()).toContain(ru.DASHBOARD.TABLE.SUSPENDED);
    expect(wrapper.text()).toContain('Требует авторизации');
    expect(wrapper.text()).toContain('Зависших: 4');
  });

  it('draws every status as a dot with a word', () => {
    const wrapper = render();
    const states = wrapper
      .findAll('[data-status]')
      .map(dot => dot.attributes('data-status'));

    expect(states).toContain('bad');
    expect(states).toContain('good');
    expect(states).toContain('neutral');
  });

  it('keeps the wide table inside its own scrolling container', () => {
    const wrapper = render();
    const table = wrapper.find('table');

    expect(table.element.parentElement.classList).toContain('overflow-x-auto');
  });

  it('searches by name or number', async () => {
    const wrapper = render();

    await wrapper.find('input[type="search"]').setValue('сезим');
    expect(rows(wrapper)).toHaveLength(1);
    expect(wrapper.text()).toContain('Показано 1 из 3');

    await wrapper.find('input[type="search"]').setValue('3');
    expect(rows(wrapper)[0].text()).toContain('Достар');
  });

  it('shows only the clinics that need attention', async () => {
    const wrapper = render();
    const attention = wrapper
      .findAll('.segmented__item')
      .find(button => button.text() === ru.DASHBOARD.TOOLBAR.VIEW_ATTENTION);

    await attention.trigger('click');

    expect(rows(wrapper)).toHaveLength(1);
    expect(rows(wrapper)[0].text()).toContain('Сезим');
  });

  it('marks the chosen view and switches back to every clinic', async () => {
    const wrapper = render();
    const [all, attention] = wrapper.findAll('.segmented__item');

    expect(all.attributes('aria-current')).toBe('true');
    expect(attention.attributes('aria-current')).toBeUndefined();

    await attention.trigger('click');
    expect(attention.attributes('aria-current')).toBe('true');
    expect(all.attributes('aria-current')).toBeUndefined();

    await all.trigger('click');
    expect(rows(wrapper)).toHaveLength(3);
  });

  it('says so when nothing matches', async () => {
    const wrapper = render();

    await wrapper.find('input[type="search"]').setValue('нет такой');

    expect(wrapper.find('table').exists()).toBe(false);
    expect(wrapper.text()).toContain(ru.DASHBOARD.TABLE.EMPTY_TITLE);
    expect(wrapper.text()).toContain(ru.DASHBOARD.TABLE.EMPTY_HINT);
  });

  it('warns when a part of the data is missing', () => {
    const wrapper = render({
      ...componentData,
      healthSummary: {
        ...componentData.healthSummary,
        incomplete_sources: ['Message', 'Telephony::SipProfile'],
      },
    });
    const notice = wrapper.find('[data-testid="health-incomplete-sources"]');

    expect(notice.exists()).toBe(true);
    expect(notice.text()).toContain('Message, Telephony::SipProfile');
  });

  it('shows the chart only on demand, in the colours of the theme', async () => {
    const wrapper = render();
    const toggle = wrapper.find('[data-testid="health-chart-toggle"]');

    expect(wrapper.text()).not.toContain(ru.DASHBOARD.CHART.TITLE);
    expect(toggle.text()).toBe(ru.DASHBOARD.CHART.SHOW);

    await toggle.trigger('click');

    expect(wrapper.text()).toContain(ru.DASHBOARD.CHART.TITLE);
    expect(toggle.text()).toBe(ru.DASHBOARD.CHART.HIDE);
    expect(toggle.attributes('aria-expanded')).toBe('true');
    // the chart takes its colours from the theme tokens, never a fixed colour
    expect(wrapper.html()).toContain('stroke-n-brand');
    expect(wrapper.html()).not.toMatch(/rgb\(|#[0-9a-f]{6}/i);
  });

  it('renders with no data at all', () => {
    const wrapper = render({});

    expect(wrapper.text()).toContain(ru.DASHBOARD.TABLE.EMPTY_TITLE);
    expect(wrapper.findAll('[data-test-id="ds-stat"] dd')[0].text()).toBe('0');
  });

  it('has no emoji and no English product names in the text', () => {
    const wrapper = render();

    expect(wrapper.text()).not.toMatch(/\p{Extended_Pictographic}/u);
    expect(wrapper.text()).not.toMatch(/Health Matrix/i);
  });
});

describe('the Russian texts of the dashboard', () => {
  const source = readFileSync(
    resolvePath(
      process.cwd(),
      'app/javascript/superadmin_pages/views/dashboard/Index.vue'
    ),
    'utf8'
  );

  const lookup = key => key.split('.').reduce((node, part) => node?.[part], ru);

  it('has every key the component asks for', () => {
    const keys = [...source.matchAll(/\bt\(\s*'([A-Z_.]+)'/g)].map(m => m[1]);

    expect(keys.length).toBeGreaterThan(15);
    keys.forEach(key => expect(lookup(key), key).toBeTypeOf('string'));
  });

  it('has no emoji, no leftover English title and no empty text', () => {
    const texts = JSON.stringify(ru);

    expect(texts).not.toMatch(/\p{Extended_Pictographic}/u);
    expect(texts).not.toMatch(/Health Matrix/i);
    expect(texts).not.toContain('""');
  });
});
