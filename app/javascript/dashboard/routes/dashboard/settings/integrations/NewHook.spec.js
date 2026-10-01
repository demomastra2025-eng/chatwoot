import { flushPromises, mount } from '@vue/test-utils';
import { defaultConfig, plugin as formKitPlugin } from '@formkit/vue';
import { computed } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import enIntegrationApps from 'dashboard/i18n/locale/en/integrationApps.json';
import kkIntegrationApps from 'dashboard/i18n/locale/kk/integrationApps.json';
import ruIntegrationApps from 'dashboard/i18n/locale/ru/integrationApps.json';

const testState = vi.hoisted(() => ({
  integration: null,
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('dashboard/composables/useIntegrationHook', () => ({
  useIntegrationHook: () => ({
    integration: computed(() => testState.integration),
    isHookTypeInbox: computed(() => false),
  }),
}));

vi.mock('shared/composables/useBranding', () => ({
  useBranding: () => ({ replaceInstallationName: value => value }),
}));

import NewHook from './NewHook.vue';

const hook = {
  id: 45,
  status: true,
  settings: {
    sync_interval_hours: 12,
    write_enabled: false,
  },
};

const mountComponent = () =>
  mount(NewHook, {
    props: { integrationId: 'medelement', hook },
    global: {
      plugins: [[formKitPlugin, defaultConfig()]],
      mocks: {
        $store: {
          getters: {
            'integrations/getUIFlags': {},
            'inboxes/dialogFlowEnabledInboxes': [],
          },
          dispatch: vi.fn(),
        },
        $t: key => key,
      },
      stubs: {
        NextButton: true,
        WootModalHeader: true,
      },
    },
  });

describe('NewHook edit form', () => {
  beforeEach(() => {
    testState.integration = {
      id: 'medelement',
      name: 'MedElement',
      short_description: 'MedElement settings',
      settings_form_schema: [
        {
          label: 'Company Login',
          type: 'text',
          name: 'company_login',
          validation: 'required',
          store: 'secret_settings',
        },
        {
          label: 'Password',
          type: 'password',
          name: 'password',
          validation: 'required',
          store: 'secret_settings',
        },
        {
          label: 'Integration enabled',
          type: 'checkbox',
          name: 'enabled',
          value: true,
          store: 'status',
        },
        {
          label: 'Enable write operations',
          type: 'checkbox',
          name: 'write_enabled',
          value: true,
        },
        {
          label: 'Sync frequency',
          type: 'select',
          name: 'sync_interval_hours',
          value: 0.25,
          value_type: 'number',
          validation: 'required',
          options: [
            { label: 'Every 15 minutes', value: 0.25 },
            { label: 'Every 12 hours', value: 12 },
          ],
        },
      ],
    };
  });

  it('keeps persisted settings and explains that blank secrets remain unchanged', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.vm.values).toEqual({
      company_login: '',
      password: '',
      enabled: true,
      write_enabled: false,
      sync_interval_hours: 12,
    });
    expect(wrapper.get('input[name="write_enabled"]').element.checked).toBe(
      false
    );
    expect(
      wrapper.get('select[name="sync_interval_hours"] option:checked').text()
    ).toBe('Every 12 hours');
    expect(
      wrapper.get('input[name="company_login"]').attributes('placeholder')
    ).toBe('INTEGRATION_APPS.ADD.FORM.SECRET_KEEP_PLACEHOLDER');
    expect(wrapper.text()).toContain(
      'INTEGRATION_APPS.ADD.FORM.SECRET_KEEP_HELP'
    );
    expect(
      wrapper.get('next-button-stub[type="submit"]').attributes('label')
    ).toBe('INTEGRATION_APPS.ADD.FORM.SAVE');

    expect(wrapper.vm.buildHookPayload()).toEqual({
      app_id: 'medelement',
      status: 'enabled',
      settings: {
        write_enabled: false,
        sync_interval_hours: 12,
      },
    });
  });

  it('shows the MedElement removal toggle localized and off for a hook saved before it existed', async () => {
    const messages = ruIntegrationApps.INTEGRATION_APPS.MEDELEMENT.SETTINGS;
    const translations = {
      'INTEGRATION_APPS.MEDELEMENT.SETTINGS.REMOVE_RECEPTION_ON_CANCEL.LABEL':
        messages.REMOVE_RECEPTION_ON_CANCEL.LABEL,
      'INTEGRATION_APPS.MEDELEMENT.SETTINGS.REMOVE_RECEPTION_ON_CANCEL.HINT':
        messages.REMOVE_RECEPTION_ON_CANCEL.HINT,
    };
    testState.integration.settings_form_schema.push({
      label: 'Remove the MedElement reception',
      label_i18n:
        'INTEGRATION_APPS.MEDELEMENT.SETTINGS.REMOVE_RECEPTION_ON_CANCEL.LABEL',
      help_i18n:
        'INTEGRATION_APPS.MEDELEMENT.SETTINGS.REMOVE_RECEPTION_ON_CANCEL.HINT',
      type: 'switch',
      name: 'remove_reception_on_cancel',
      value: false,
    });
    const wrapper = mount(NewHook, {
      props: { integrationId: 'medelement', hook },
      global: {
        plugins: [[formKitPlugin, defaultConfig()]],
        mocks: {
          $store: {
            getters: {
              'integrations/getUIFlags': {},
              'inboxes/dialogFlowEnabledInboxes': [],
            },
            dispatch: vi.fn(),
          },
          $t: key => translations[key] || key,
        },
        stubs: { NextButton: true, WootModalHeader: true },
      },
    });
    await flushPromises();

    const input = wrapper.get('[role="switch"]');
    expect(input.attributes('aria-checked')).toBe('false');
    expect(input.attributes('aria-labelledby')).toBe(
      'integration-setting-label-remove_reception_on_cancel'
    );
    expect(wrapper.text()).toContain(
      'Удалять приём в МедЭлементе при отмене в OneLink'
    );
    expect(wrapper.text()).toContain(
      'Если выключено, отмена меняет статус только в OneLink.'
    );
    expect(input.attributes('label_i18n')).toBeUndefined();

    await input.trigger('click');
    await flushPromises();
    expect(wrapper.vm.buildHookPayload().settings).toMatchObject({
      remove_reception_on_cancel: true,
    });
  });

  it.each([
    ['en', enIntegrationApps],
    ['ru', ruIntegrationApps],
    ['kk', kkIntegrationApps],
  ])(
    'provides real %s copy for the MedElement removal toggle',
    (_locale, m) => {
      const copy =
        m.INTEGRATION_APPS.MEDELEMENT.SETTINGS.REMOVE_RECEPTION_ON_CANCEL;

      expect(copy.LABEL).toEqual(expect.any(String));
      expect(copy.HINT).toEqual(expect.any(String));
      expect(copy.LABEL).not.toContain('REMOVE_RECEPTION');
    }
  );

  it.each([
    ['en', enIntegrationApps],
    ['ru', ruIntegrationApps],
    ['kk', kkIntegrationApps],
  ])(
    'provides real %s copy for preserved secret fields',
    (_locale, messages) => {
      const formMessages = messages.INTEGRATION_APPS.ADD.FORM;

      expect(formMessages.SECRET_KEEP_PLACEHOLDER).toEqual(expect.any(String));
      expect(formMessages.SECRET_KEEP_HELP).toEqual(expect.any(String));
      expect(formMessages.SAVE).toEqual(expect.any(String));
      expect(formMessages.SECRET_KEEP_PLACEHOLDER).not.toContain('SECRET_KEEP');
      expect(formMessages.SECRET_KEEP_HELP).not.toContain('SECRET_KEEP');
    }
  );
});
