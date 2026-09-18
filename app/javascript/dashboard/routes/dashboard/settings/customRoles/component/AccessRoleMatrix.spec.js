import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import AccessRoleMatrix from './AccessRoleMatrix.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key =>
      key === 'CUSTOM_ROLE.ACCESS_MATRIX.SYSTEM_ROLES.EMPLOYEE'
        ? 'Localized employee'
        : key,
  }),
}));

const roles = [
  {
    id: 10,
    name: 'Employee',
    description: 'Default employee access',
    system_key: 'employee',
    role_kind: 'system',
    assigned_users_count: 2,
    grants: [
      {
        resource: 'contacts',
        capability: 'view',
        access_scope: 'own',
      },
    ],
  },
];

const resources = {
  contacts: ['view', 'create'],
};

const mountComponent = props =>
  mount(AccessRoleMatrix, {
    props,
    global: {
      mocks: {
        $t: (key, params) => (params ? `${key}:${params.n}` : key),
      },
      stubs: {
        Button: {
          props: ['label'],
          emits: ['click'],
          template:
            '<button type="button" @click="$emit(\'click\')">{{ label }}</button>',
        },
      },
    },
  });

describe('AccessRoleMatrix', () => {
  it('renders system role grants and fills absent grants with none', () => {
    const wrapper = mountComponent({ roles, resources });

    expect(wrapper.text()).toContain('Localized employee');
    expect(wrapper.text()).toContain(
      'CUSTOM_ROLE.ACCESS_MATRIX.ROLE_KIND.SYSTEM'
    );
    expect(wrapper.text()).toContain(
      'CUSTOM_ROLE.ACCESS_MATRIX.ASSIGNED_USERS:2'
    );
    expect(wrapper.find('[data-scope="own"]').exists()).toBe(true);
    expect(wrapper.find('[data-scope="none"]').exists()).toBe(true);
    expect(
      wrapper.findAll('[data-testid="access-role-resource-contacts"]')
    ).toHaveLength(1);
  });

  it('filters roles by the localized system role name', () => {
    const matchingWrapper = mountComponent({
      roles,
      resources,
      searchQuery: 'localized',
    });
    const missingWrapper = mountComponent({
      roles,
      resources,
      searchQuery: 'not present',
    });

    expect(
      matchingWrapper.findAll('[data-testid="access-role-card"]')
    ).toHaveLength(1);
    expect(
      missingWrapper.find('[data-testid="access-role-matrix-empty"]').exists()
    ).toBe(true);
  });

  it('renders the loading state', () => {
    const wrapper = mountComponent({ isLoading: true });

    expect(
      wrapper.find('[data-testid="access-role-matrix-loading"]').exists()
    ).toBe(true);
    expect(wrapper.findAll('[data-testid="access-role-card"]')).toHaveLength(0);
  });

  it('renders an error and emits retry', async () => {
    const wrapper = mountComponent({ hasError: true });

    await wrapper.get('button').trigger('click');

    expect(
      wrapper.find('[data-testid="access-role-matrix-error"]').exists()
    ).toBe(true);
    expect(wrapper.emitted('retry')).toHaveLength(1);
  });

  it('renders the empty state', () => {
    const wrapper = mountComponent({ roles: [], resources: {} });

    expect(
      wrapper.find('[data-testid="access-role-matrix-empty"]').exists()
    ).toBe(true);
  });
});
