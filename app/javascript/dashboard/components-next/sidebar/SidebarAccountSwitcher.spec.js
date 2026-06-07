import { mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import SidebarAccountSwitcher from './SidebarAccountSwitcher.vue';

const {
  currentAccount,
  currentUser,
  globalConfig,
  userAccounts,
  accountScopedRoute,
} = vi.hoisted(() => ({
  currentAccount: {
    __v_isRef: true,
    value: {},
  },
  currentUser: { value: { accounts: [] } },
  globalConfig: { value: { createNewAccountFromDashboard: false } },
  userAccounts: { value: [] },
  accountScopedRoute: vi.fn(name => ({ name, params: { accountId: 1 } })),
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({ name: 'dashboard' }),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    accountId: {
      __v_isRef: true,
      get value() {
        return currentAccount.value.id;
      },
    },
    accountScopedRoute,
    currentAccount,
  }),
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: getter => {
    const getters = {
      getCurrentUser: currentUser,
      'globalConfig/get': globalConfig,
      getUserAccounts: userAccounts,
    };
    return getters[getter] || { value: null };
  },
}));

vi.mock('dashboard/components-next/avatar/Avatar.vue', () => ({
  default: {
    name: 'Avatar',
    props: ['src', 'name', 'size'],
    template:
      '<span data-test-id="workspace-avatar" :data-src="src" :data-name="name" :data-size="size" />',
  },
}));

vi.mock('next/icon/Logo.vue', () => ({
  default: {
    name: 'Logo',
    template: '<span data-test-id="default-workspace-logo" />',
  },
}));

vi.mock('next/icon/Icon.vue', () => ({
  default: {
    name: 'Icon',
    props: ['icon'],
    template: '<span data-test-id="icon" :data-icon="icon" />',
  },
}));

vi.mock('next/button/Button.vue', () => ({
  default: {
    name: 'ButtonNext',
    template: '<button><slot /></button>',
  },
}));

vi.mock('next/dropdown-menu/base', () => {
  const DropdownContainer = {
    name: 'DropdownContainer',
    props: ['menuClass'],
    methods: {
      toggle() {},
    },
    template:
      '<div class="dropdown-container" :data-menu-class="menuClass"><slot name="trigger" :toggle="toggle" :is-open="false" /><slot /></div>',
  };

  return {
    DropdownContainer,
    DropdownBody: {
      name: 'DropdownBody',
      template: '<div><slot /></div>',
    },
    DropdownSection: {
      name: 'DropdownSection',
      template: '<section><slot /></section>',
    },
    DropdownItem: {
      name: 'DropdownItem',
      props: ['label', 'icon', 'link'],
      template: '<div><slot name="label" />{{ label }}<slot /></div>',
    },
  };
});

const mountComponent = props =>
  mount(SidebarAccountSwitcher, {
    props,
    global: {
      stubs: {
        RouterLink: {
          name: 'RouterLink',
          props: ['to'],
          template: '<a data-test-id="workspace-settings-link"><slot /></a>',
        },
      },
    },
  });

describe('SidebarAccountSwitcher', () => {
  beforeEach(() => {
    currentAccount.value = {
      id: 1,
      name: 'OneLink Workspace',
      logo_url: '',
    };
    currentUser.value = {
      accounts: [{ id: 1, name: 'OneLink Workspace', role: 'administrator' }],
    };
    userAccounts.value = [{ id: 1, name: 'OneLink Workspace' }];
    globalConfig.value = { createNewAccountFromDashboard: false };
    accountScopedRoute.mockClear();
  });

  it('uses the default company logo as the workspace logo when no custom logo is set', () => {
    const wrapper = mountComponent({ isCollapsed: false });

    expect(
      wrapper.find('[data-test-id="default-workspace-logo"]').exists()
    ).toBe(true);
    expect(wrapper.find('[data-test-id="workspace-avatar"]').exists()).toBe(
      false
    );
  });

  it('uses the uploaded workspace logo when the account has a custom logo', () => {
    currentAccount.value = {
      ...currentAccount.value,
      logo_url: 'https://example.com/customer-logo.png',
    };

    const wrapper = mountComponent({ isCollapsed: false });
    const avatar = wrapper.find('[data-test-id="workspace-avatar"]');

    expect(avatar.exists()).toBe(true);
    expect(avatar.attributes('data-src')).toBe(
      'https://example.com/customer-logo.png'
    );
    expect(
      wrapper.find('[data-test-id="default-workspace-logo"]').exists()
    ).toBe(false);
  });

  it('uses the uploaded workspace logo in the collapsed sidebar trigger', () => {
    currentAccount.value = {
      ...currentAccount.value,
      logo_url: 'https://example.com/customer-logo.png',
    };
    currentUser.value = {
      accounts: [
        {
          id: 1,
          name: 'OneLink Workspace',
          role: 'administrator',
          logo_url: 'https://example.com/customer-logo.png',
        },
      ],
    };

    const wrapper = mountComponent({ isCollapsed: true });

    expect(wrapper.findAll('[data-test-id="workspace-avatar"]')).toHaveLength(
      2
    );
    expect(
      wrapper.find('[data-test-id="default-workspace-logo"]').exists()
    ).toBe(false);
  });

  it('positions the company menu to the right of the briefcase trigger', () => {
    const wrapper = mountComponent({
      isCollapsed: false,
      companyMenuItem: {
        name: 'my_company',
        label: 'Company',
        to: { name: 'settings_general' },
        children: [
          {
            name: 'employees',
            label: 'Employees',
            icon: 'i-lucide-users',
            to: { name: 'settings_agents' },
          },
        ],
      },
    });

    const containers = wrapper.findAll('.dropdown-container');

    expect(containers).toHaveLength(2);
    expect(containers[1].attributes('data-menu-class')).toBe(
      'ltr:left-full rtl:right-full top-0 ltr:ml-2 rtl:mr-2 !mt-0'
    );
    expect(wrapper.text()).toContain('Employees');
  });
});
