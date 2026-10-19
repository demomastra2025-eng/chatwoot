import { shallowMount } from '@vue/test-utils';
import { createStore } from 'vuex';
import { nextTick } from 'vue';
import AccountSettings from './Index.vue';
import { useAlert } from 'dashboard/composables';

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: { locale: 'en' },
  }),
}));

vi.mock('dashboard/composables/useConfig', () => ({
  useConfig: () => ({
    enabledLanguages: [
      { iso_639_1_code: 'en', name: 'English' },
      { iso_639_1_code: 'ru', name: 'Русский' },
    ],
  }),
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    accountId: 530,
  }),
}));

let canManageWorkspace = true;

vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({
    checkPermissions: vi.fn(() => canManageWorkspace),
  }),
}));

vi.mock('dashboard/i18n', () => ({
  setDashboardLocale: vi.fn(locale => Promise.resolve(locale || 'en')),
}));

const account = {
  id: 530,
  name: 'Acme Inc',
  locale: 'en',
  features: {},
  logo_url: '',
};

const buildWrapper = ({
  updateAction = vi.fn(() => Promise.resolve()),
  isOnChatwootCloud = false,
  accountRecord = account,
} = {}) => {
  const store = createStore({
    modules: {
      accounts: {
        namespaced: true,
        getters: {
          getAccount: () => () => accountRecord,
          getUIFlags: () => ({ isFetchingItem: false, isUpdating: false }),
        },
        actions: {
          update: updateAction,
        },
      },
      globalConfig: {
        namespaced: true,
        getters: {
          isOnChatwootCloud: () => isOnChatwootCloud,
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
          props: ['title'],
          template:
            '<section :data-title="title"><slot /><slot name="headerActions" /></section>',
        },
        WorkspaceLogo: true,
        AccountId: { template: '<div data-test="account-id" />' },
        AccountDelete: { template: '<div data-test="account-delete" />' },
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
    canManageWorkspace = true;
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

  it('shows a field-specific validation error instead of a generic form error', async () => {
    const { wrapper, updateAction } = buildWrapper();
    await wrapper.vm.hydrateAccountForm();
    await wrapper.setData({ name: '   ', locale: 'ru' });

    await wrapper.vm.updateAccount();

    expect(updateAction).not.toHaveBeenCalled();
    expect(useAlert).toHaveBeenCalledWith('GENERAL_SETTINGS.FORM.NAME.ERROR');
    expect(useAlert).not.toHaveBeenCalledWith('GENERAL_SETTINGS.FORM.ERROR');
  });

  it('shows the general form and account ID directly without collapsible details or build info', async () => {
    const { wrapper } = buildWrapper({ isOnChatwootCloud: true });
    await wrapper.vm.hydrateAccountForm();

    expect(wrapper.find('nav').exists()).toBe(false);
    expect(wrapper.find('form').exists()).toBe(true);
    expect(wrapper.find('[data-test="account-id"]').exists()).toBe(true);
    expect(wrapper.find('details').exists()).toBe(false);
    expect(wrapper.find('[data-test="account-delete"]').exists()).toBe(true);
  });

  it('hides the danger zone outside cloud or for a read-only workspace', () => {
    const { wrapper: nonCloudWrapper } = buildWrapper();
    expect(nonCloudWrapper.find('[data-test="account-delete"]').exists()).toBe(
      false
    );

    canManageWorkspace = false;
    const { wrapper } = buildWrapper({ isOnChatwootCloud: true });
    expect(wrapper.find('[data-test="account-delete"]').exists()).toBe(false);
    expect(wrapper.text()).toContain('GENERAL_SETTINGS.READ_ONLY');
  });

  it('waits for account data before mounting dependent sections', () => {
    const { wrapper } = buildWrapper({
      accountRecord: null,
      isOnChatwootCloud: true,
    });

    expect(wrapper.find('[data-test="account-id"]').exists()).toBe(false);
    expect(wrapper.find('[data-test="account-delete"]').exists()).toBe(false);
  });

  it('detects normalized workspace changes and restores persisted values', async () => {
    const { wrapper } = buildWrapper();
    await wrapper.vm.hydrateAccountForm();

    expect(wrapper.vm.hasWorkspaceChanges).toBe(false);
    await wrapper.setData({ name: 'Renamed workspace' });
    expect(wrapper.vm.hasWorkspaceChanges).toBe(true);

    await wrapper.vm.discardWorkspaceChanges();

    expect(wrapper.vm.name).toBe(account.name);
    expect(wrapper.vm.hasWorkspaceChanges).toBe(false);
  });

  it('protects browser navigation while changes are unsaved', async () => {
    const { wrapper } = buildWrapper();
    await wrapper.vm.hydrateAccountForm();
    await wrapper.setData({ name: 'Renamed workspace' });
    const event = { preventDefault: vi.fn(), returnValue: undefined };

    wrapper.vm.handleBeforeUnload(event);

    expect(event.preventDefault).toHaveBeenCalled();
    expect(event.returnValue).toBe('');
  });

  it('does not overwrite a draft when the same account refreshes', async () => {
    const { wrapper } = buildWrapper();
    await wrapper.vm.hydrateAccountForm();
    await wrapper.setData({ name: 'Unsaved workspace name' });

    await wrapper.vm.hydrateAccountForm();

    expect(wrapper.vm.name).toBe('Unsaved workspace name');
  });

  it('protects workspace changes when the route account changes', () => {
    const next = vi.fn();
    const context = {
      confirmWorkspaceNavigation: vi.fn(() => false),
    };

    AccountSettings.beforeRouteUpdate.call(
      context,
      { params: { accountId: '531' } },
      { params: { accountId: '530' } },
      next
    );

    expect(context.confirmWorkspaceNavigation).toHaveBeenCalled();
    expect(next).toHaveBeenCalledWith(false);
  });
});
