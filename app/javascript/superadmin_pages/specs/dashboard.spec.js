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
    clinic(2, 'Аккаунт «Сезим»', {
      status: 'suspended',
      whatsapp: { state: 'error', label: 'Требует авторизации' },
      failed_messages: 4,
      needs_attention: true,
    }),
    clinic(3, 'Медцентр «Достар»', {
      telephony: { state: 'healthy', label: '2 профиля OK' },
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

// The table is folded away until the title «Подробно по каналам» is pressed
const toggle = wrapper => wrapper.find('[data-testid="health-details-toggle"]');
const open = async (data = componentData) => {
  const wrapper = render(data);
  await toggle(wrapper).trigger('click');
  return wrapper;
};
const rows = wrapper => wrapper.findAll('tbody tr');

describe('the «Сводка» body: the table «Подробно по каналам»', () => {
  it('is folded away at first and says how many accounts are in it', () => {
    const wrapper = render();

    expect(wrapper.find('table').exists()).toBe(false);
    expect(toggle(wrapper).attributes('aria-expanded')).toBe('false');
    expect(toggle(wrapper).text()).toContain(ru.DASHBOARD.DETAILS.TITLE);
    expect(toggle(wrapper).text()).toContain('С проблемами в каналах: 1 из 3');
  });

  it('says only the number of accounts when none has a problem', () => {
    const wrapper = render({
      ...componentData,
      healthAccounts: [clinic(1, 'Acme Inc')],
    });

    expect(toggle(wrapper).text()).toContain('Аккаунтов: 1');
    expect(toggle(wrapper).text()).not.toContain('С проблемами');
  });

  it('opens on a press of its title and folds again on a second press', async () => {
    const wrapper = await open();

    expect(toggle(wrapper).attributes('aria-expanded')).toBe('true');
    expect(wrapper.find('table').exists()).toBe(true);

    await toggle(wrapper).trigger('click');
    expect(toggle(wrapper).attributes('aria-expanded')).toBe('false');
    expect(wrapper.find('table').exists()).toBe(false);
  });

  it('leaves the headline figures to the server: no tiles are drawn here', async () => {
    const wrapper = await open();

    expect(wrapper.find('[data-test-id="ds-stat"]').exists()).toBe(false);
    expect(wrapper.find('[data-testid="health-kpi"]').exists()).toBe(false);
  });

  it('lists a row per account with a link to its card', async () => {
    const wrapper = await open();

    expect(rows(wrapper)).toHaveLength(3);
    const links = wrapper.findAll('tbody a').map(a => a.attributes('href'));
    expect(links).toContain('/super_admin/accounts/2');
    expect(wrapper.text()).toContain(ru.DASHBOARD.TABLE.SUSPENDED);
    expect(wrapper.text()).toContain('Требует авторизации');
    expect(wrapper.text()).toContain('Не отправлено: 4');
  });

  it('names the columns in plain words', async () => {
    const wrapper = await open();
    const headers = wrapper.findAll('thead th').map(th => th.text());

    expect(headers).toEqual([
      'Аккаунт',
      'WhatsApp',
      'Телефония',
      'МедЭлемент',
      'Не отправлены за 3 дня',
      'Действия',
    ]);
    expect(wrapper.text()).not.toMatch(/Janus|МИС/);
  });

  it('draws every status as a dot with a word', async () => {
    const wrapper = await open();
    const states = wrapper
      .findAll('[data-status]')
      .map(dot => dot.attributes('data-status'));

    expect(states).toContain('bad');
    expect(states).toContain('good');
    expect(states).toContain('neutral');
  });

  it('keeps the wide table inside its own scrolling container', async () => {
    const wrapper = await open();
    const table = wrapper.find('table');

    expect(table.element.parentElement.classList).toContain('overflow-x-auto');
  });

  it('searches by name or number', async () => {
    const wrapper = await open();

    await wrapper.find('input[type="search"]').setValue('сезим');
    expect(rows(wrapper)).toHaveLength(1);
    expect(wrapper.text()).toContain('Показано 1 из 3');

    await wrapper.find('input[type="search"]').setValue('3');
    expect(rows(wrapper)[0].text()).toContain('Достар');
  });

  it('shows only the accounts with a problem in a channel', async () => {
    const wrapper = await open();
    const attention = wrapper
      .findAll('.segmented__item')
      .find(button => button.text() === ru.DASHBOARD.TOOLBAR.VIEW_ATTENTION);

    await attention.trigger('click');

    expect(rows(wrapper)).toHaveLength(1);
    expect(rows(wrapper)[0].text()).toContain('Сезим');
  });

  it('marks the chosen view and switches back to every account', async () => {
    const wrapper = await open();
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
    const wrapper = await open();

    await wrapper.find('input[type="search"]').setValue('нет такой');

    expect(wrapper.find('table').exists()).toBe(false);
    expect(wrapper.text()).toContain(ru.DASHBOARD.TABLE.EMPTY_TITLE);
    expect(wrapper.text()).toContain(ru.DASHBOARD.TABLE.EMPTY_HINT);
  });

  it('warns inside the table when a part of the data is missing', async () => {
    const data = {
      ...componentData,
      healthSummary: {
        ...componentData.healthSummary,
        incomplete_sources: ['сообщения', 'линии телефонии'],
      },
    };
    const wrapper = render(data);
    expect(
      wrapper.find('[data-testid="health-incomplete-sources"]').exists()
    ).toBe(false);

    await toggle(wrapper).trigger('click');
    const notice = wrapper.find('[data-testid="health-incomplete-sources"]');

    expect(notice.exists()).toBe(true);
    expect(notice.text()).toContain('сообщения, линии телефонии');
  });

  it('renders with no data at all', async () => {
    const wrapper = render({});
    expect(toggle(wrapper).text()).toContain('Аккаунтов: 0');

    await toggle(wrapper).trigger('click');
    expect(wrapper.text()).toContain(ru.DASHBOARD.TABLE.EMPTY_TITLE);
  });
});

describe('the «Сводка» body: the chart', () => {
  it('shows the chart only on demand, in the colours of the theme', async () => {
    const wrapper = render();
    const button = wrapper.find('[data-testid="health-chart-toggle"]');

    expect(wrapper.text()).not.toContain(ru.DASHBOARD.CHART.TITLE);
    expect(button.text()).toBe(ru.DASHBOARD.CHART.SHOW);

    await button.trigger('click');

    expect(wrapper.text()).toContain(ru.DASHBOARD.CHART.TITLE);
    expect(button.text()).toBe(ru.DASHBOARD.CHART.HIDE);
    expect(button.attributes('aria-expanded')).toBe('true');
    // the chart takes its colours from the theme tokens, never a fixed colour
    expect(wrapper.html()).toContain('stroke-n-brand');
    expect(wrapper.html()).not.toMatch(/rgb\(|#[0-9a-f]{6}/i);
  });
});

describe('the text of the «Сводка» body', () => {
  it('has no emoji and no English product names', async () => {
    const wrapper = await open();

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

  it('keeps no text the component does not ask for', () => {
    const asked = new Set(
      [...source.matchAll(/\bt\(\s*'([A-Z_.]+)'/g)].map(m => m[1])
    );
    const leaves = (node, path = []) =>
      typeof node === 'string'
        ? [path.join('.')]
        : Object.entries(node).flatMap(([key, value]) =>
            leaves(value, [...path, key])
          );

    leaves(ru).forEach(key => expect(asked.has(key), key).toBe(true));
  });

  it('has no emoji, no leftover English title and no empty text', () => {
    const texts = JSON.stringify(ru);

    expect(texts).not.toMatch(/\p{Extended_Pictographic}/u);
    expect(texts).not.toMatch(/Health Matrix/i);
    expect(texts).not.toContain('""');
  });
});
