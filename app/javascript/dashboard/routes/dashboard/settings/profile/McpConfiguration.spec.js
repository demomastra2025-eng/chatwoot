import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { config, flushPromises, mount } from '@vue/test-utils';
import { ref } from 'vue';

import kk from 'dashboard/i18n/locale/kk';
import McpConfiguration from './McpConfiguration.vue';

const mocks = vi.hoisted(() => ({ get: vi.fn(), update: vi.fn() }));

vi.mock('dashboard/api/mcpSettings', () => ({
  default: { get: mocks.get, update: mocks.update },
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    accountId: ref(1),
    currentAccount: ref({ id: 1, name: 'Clinic' }),
  }),
}));

vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));

// The app-wide i18n instance installed by vitest.setup.js.
const i18n = config.global.plugins.find(plugin => plugin?.global?.locale);

const catalogPayload = () => ({
  permissions: { manage: true },
  groups: [
    { id: 'captain:Outbound', name: 'Outbound' },
    { id: 'openapi_read:Inboxes', name: 'Inboxes' },
  ],
  mcp_access: { enabled: true },
  tools: [
    {
      id: 'create_touch',
      name: 'create_touch',
      title: 'Create Touch',
      source: 'captain',
      group_name: 'Outbound',
      group_key: 'captain:Outbound',
    },
    {
      id: 'cancel_touches',
      name: 'cancel_touches',
      title: 'Cancel Touches',
      source: 'captain',
      group_name: 'Outbound',
      group_key: 'captain:Outbound',
    },
    {
      id: 'api__list_inboxes',
      operation_id: 'api__list_inboxes',
      title: 'List inboxes',
      source: 'openapi_read',
      group_name: 'Inboxes',
      group_key: 'openapi_read:Inboxes',
    },
  ],
});

const mountPage = async () => {
  mocks.get.mockResolvedValue({ data: catalogPayload() });
  const wrapper = mount(McpConfiguration, {
    props: { accessToken: '' },
    global: {
      stubs: {
        Button: { template: '<button type="button" />' },
        Switch: {
          props: ['modelValue', 'ariaLabel'],
          template: '<input type="checkbox" :aria-label="ariaLabel" />',
        },
      },
    },
  });
  await flushPromises();
  return wrapper;
};

describe('McpConfiguration AI tool catalog', () => {
  let previousLocale;
  let previousFallback;

  beforeEach(() => {
    // Only en and ru are loaded at startup; kk is loaded on demand.
    if (!i18n.global.availableLocales.includes('kk')) {
      i18n.global.setLocaleMessage('kk', kk);
    }
    previousLocale = i18n.global.locale.value;
    previousFallback = i18n.global.fallbackLocale.value;
    // As in the dashboard: missing keys fall back to English.
    i18n.global.fallbackLocale.value = 'en';
  });

  afterEach(() => {
    i18n.global.locale.value = previousLocale;
    i18n.global.fallbackLocale.value = previousFallback;
  });

  it.each(['en', 'ru', 'kk'])(
    'never shows the backend «touch» titles in %s',
    async locale => {
      i18n.global.locale.value = locale;
      const wrapper = await mountPage();
      const text = wrapper.text();

      expect(text).not.toMatch(/touch/i);
      expect(text).not.toMatch(/касани/i);
      expect(text).toContain(
        i18n.global.t(
          'CAPTAIN.ASSISTANTS.FORM.TOOL_ACCESS.TOOLS.create_touch.TITLE'
        )
      );
      // API tools keep their own titles and groups.
      expect(text).toContain('List inboxes');
      expect(text).toContain('Inboxes');
    }
  );

  it('shows the localized reminder wording in Russian', async () => {
    i18n.global.locale.value = 'ru';
    const wrapper = await mountPage();
    const text = wrapper.text();

    expect(text).toContain('Создать исходящее напоминание');
    expect(text).toContain('Отменить напоминания');
    expect(text).toContain('Исходящие');
    expect(
      wrapper.find('input[aria-label="Создать исходящее напоминание"]').exists()
    ).toBe(true);
  });
});
