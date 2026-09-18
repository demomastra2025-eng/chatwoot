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
          props: ['label', 'disabled'],
          emits: ['click'],
          template:
            '<button type="button" :disabled="disabled" @click="$emit(\'click\', $event)">{{ label }}</button>',
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

  it('exposes edit and delete only for custom roles when mutations are enabled', async () => {
    const customRole = {
      ...roles[0],
      id: 11,
      name: 'Support',
      system_key: null,
      role_kind: 'custom',
      assigned_users_count: 0,
    };
    const readOnlyWrapper = mountComponent({
      roles: [customRole],
      resources,
    });
    const editableWrapper = mountComponent({
      roles: [customRole],
      resources,
      mutationsEnabled: true,
    });

    expect(readOnlyWrapper.findAll('button')).toHaveLength(0);
    const [editButton, deleteButton] = editableWrapper.findAll('button');
    await editButton.trigger('click');
    await deleteButton.trigger('click');

    expect(editableWrapper.emitted('edit')[0]).toEqual([customRole]);
    expect(editableWrapper.emitted('delete')[0]).toEqual([customRole]);
  });

  it('disables deletion for an assigned custom role', () => {
    const wrapper = mountComponent({
      roles: [
        {
          ...roles[0],
          id: 12,
          system_key: null,
          role_kind: 'custom',
          assigned_users_count: 1,
        },
      ],
      resources,
      mutationsEnabled: true,
    });

    expect(wrapper.findAll('button')[1].attributes('disabled')).toBeDefined();
  });
});
