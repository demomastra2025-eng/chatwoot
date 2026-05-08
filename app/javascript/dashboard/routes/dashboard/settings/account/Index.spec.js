import { beforeEach, describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';
import { createStore } from 'vuex';
import { nextTick } from 'vue';

import { useVuelidate } from '@vuelidate/core';
import { required } from '@vuelidate/validators';

import AccountSettings from './Index.vue';
import { useAlert } from 'dashboard/composables';

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({ uiSettings: { locale: 'ru' } }),
}));

vi.mock('dashboard/composables/useConfig', () => ({
  useConfig: () => ({
    enabledLanguages: [
      { name: 'English (en)', iso_639_1_code: 'en' },
      { name: 'русский (ru)', iso_639_1_code: 'ru' },
      { name: 'қазақ тілі (kk)', iso_639_1_code: 'kk' },
    ],
  }),
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({ accountId: 530 }),
}));

let shouldShowSamlFeature = false;

vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({
    shouldShow: vi.fn(() => shouldShowSamlFeature),
    shouldShowPaywall: vi.fn(() => false),
    checkPermissions: vi.fn(() => true),
  }),
}));

vi.mock('dashboard/i18n', () => ({
  setDashboardLocale: vi.fn(locale => Promise.resolve(locale || 'en')),
}));

const account = {
  id: 530,
  name: 'Acme Inc',
  locale: 'en',
  domain: '',
  support_email: 'dev@example.com',
  features: {},
  logo_url: '',
};

const InvalidNestedSettings = {
  setup() {
    return { v$: useVuelidate() };
  },
  data() {
    return { samlUrl: '' };
  },
  validations: {
    samlUrl: { required },
  },
  template: '<div />',
};

const buildWrapper = ({
  updateAction = vi.fn(() => Promise.resolve()),
} = {}) => {
  const store = createStore({
    modules: {
      accounts: {
        namespaced: true,
        getters: {
          getAccount: () => () => account,
          getUIFlags: () => ({ isFetchingItem: false, isUpdating: false }),
        },
        actions: {
          update: updateAction,
        },
      },
      globalConfig: {
        namespaced: true,
        getters: {
          isOnChatwootCloud: () => false,
        },
      },
    },
  });

  const wrapper = shallowMount(AccountSettings, {
    global: {
      plugins: [store],
      mocks: {
        $t: key => key,
      },
      stubs: {
        BaseSettingsHeader: true,
        SectionLayout: {
          template: '<section><slot /><slot name="headerActions" /></section>',
        },
        WorkspaceLogo: true,
        AccountId: true,
        BuildInfo: true,
        AccountDelete: true,
        SamlSettings: InvalidNestedSettings,
        SamlPaywall: true,
        NextInput: true,
        NextSelect: true,
        NextButton: true,
        WithLabel: { template: '<label><slot /><slot name="help" /></label>' },
        'woot-loading-state': true,
      },
    },
  });

  return { wrapper, updateAction };
};

describe('Account settings', () => {
  beforeEach(() => {
    shouldShowSamlFeature = false;
    vi.clearAllMocks();
  });

  it('submits valid general settings to backend instead of failing local validation', async () => {
    const { wrapper, updateAction } = buildWrapper();
    await wrapper.vm.hydrateAccountForm();
    await wrapper.setData({ name: 'Renamed workspace', locale: 'ru' });
    await nextTick();

    await wrapper.vm.updateAccount();

    expect(updateAction).toHaveBeenCalledWith(
      expect.any(Object),
      expect.objectContaining({
        id: 530,
        name: 'Renamed workspace',
        locale: 'ru',
      })
    );
    expect(useAlert).not.toHaveBeenCalledWith('GENERAL_SETTINGS.FORM.ERROR');
  });

  it('submits logo-only updates when the workspace name and locale are valid', async () => {
    const { wrapper, updateAction } = buildWrapper();
    const logo = new File(['logo'], 'logo.png', { type: 'image/png' });
    await wrapper.vm.hydrateAccountForm();

    wrapper.vm.updateWorkspaceLogo({ file: logo, url: 'blob:logo' });
    await wrapper.vm.updateAccount();

    expect(updateAction).toHaveBeenCalledWith(
      expect.any(Object),
      expect.objectContaining({
        id: 530,
        name: 'Acme Inc',
        locale: 'en',
        logo,
      })
    );
    expect(useAlert).not.toHaveBeenCalledWith('GENERAL_SETTINGS.FORM.ERROR');
  });

  it('does not let nested settings validations block workspace general settings save', async () => {
    shouldShowSamlFeature = true;
    const { wrapper, updateAction } = buildWrapper();
    await wrapper.vm.hydrateAccountForm();
    await wrapper.setData({ name: 'Renamed workspace', locale: 'ru' });
    await nextTick();

    await wrapper.vm.updateAccount();

    expect(updateAction).toHaveBeenCalledWith(
      expect.any(Object),
      expect.objectContaining({
        id: 530,
        name: 'Renamed workspace',
        locale: 'ru',
      })
    );
    expect(useAlert).not.toHaveBeenCalledWith('GENERAL_SETTINGS.FORM.ERROR');
  });

  it('shows a field-specific validation error instead of a generic form error', async () => {
    const { wrapper, updateAction } = buildWrapper();
    await wrapper.vm.hydrateAccountForm();
    await wrapper.setData({ name: '   ', locale: 'ru' });

    await wrapper.vm.updateAccount();

    expect(updateAction).not.toHaveBeenCalled();
    expect(useAlert).toHaveBeenCalledWith('GENERAL_SETTINGS.FORM.NAME.ERROR');
    expect(useAlert).not.toHaveBeenCalledWith('GENERAL_SETTINGS.FORM.ERROR');
  });
});
