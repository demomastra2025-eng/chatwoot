import { flushPromises, shallowMount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';

import Index from './Index.vue';

const { catalog, dispatch, useAlert } = vi.hoisted(() => ({
  catalog: {
    records: [{ id: 1, name: 'Employee', grants: [] }],
    resources: {},
    accessScopes: [],
    mutationsEnabled: false,
    legacyMutationsEnabled: true,
    loaded: true,
    error: false,
  },
  dispatch: vi.fn(),
  useAlert: vi.fn(),
}));

const roles = [
  {
    id: 7,
    name: 'Operator',
    description: 'Handles conversations',
    permissions: ['conversation_manage'],
  },
  {
    id: 8,
    name: 'Supervisor',
    description: 'Supervises conversations',
    permissions: ['conversation_manage'],
  },
];

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('@scmmishra/pico-search', () => ({
  picoSearch: items => items,
}));

vi.mock('dashboard/composables', () => ({
  useAlert,
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch }),
  useMapGetter: key => {
    if (key === 'customRole/getCustomRoles') return ref(roles);
    if (key === 'customRole/getAccessRoleCatalog') {
      return ref(catalog);
    }
    if (key === 'customRole/getUIFlags') {
      return ref({
        fetchingList: false,
        fetchingAccessRoleCatalog: false,
      });
    }
    if (key === 'accounts/isFeatureEnabledonAccount') {
      return ref(() => true);
    }
    if (key === 'getCurrentAccountId') return ref(1);
    return ref(null);
  },
}));

const mountComponent = () =>
  shallowMount(Index, {
    global: {
      mocks: {
        $t: key => key,
      },
      stubs: {
        AccessRoleMatrix: {
          name: 'AccessRoleMatrix',
          props: ['mutationsEnabled'],
          emits: ['clone', 'edit', 'delete', 'retry'],
          template: '<div data-testid="access-role-matrix" />',
        },
        BaseSettingsHeader: {
          template: '<header><slot name="actions" /></header>',
        },
        BaseTable: {
          name: 'BaseTable',
          props: ['items'],
          template: '<div><slot name="row" :items="items" /></div>',
        },
        Button: {
          name: 'Button',
          props: ['disabled'],
          template: '<button :disabled="disabled" />',
        },
        AccessRoleModal: {
          name: 'AccessRoleModal',
          props: ['mode', 'selectedRole'],
          emits: ['close', 'stale'],
          template: '<div />',
        },
        CustomRoleModal: true,
        CustomRolePaywall: true,
        CustomRoleTableBody: {
          name: 'CustomRoleTableBody',
          props: ['roles', 'loading'],
          emits: ['edit', 'delete'],
          template: `
            <button
              v-for="role in roles"
              :key="role.id"
              :data-testid="\`delete-role-\${role.id}\`"
              :data-loading="String(Boolean(loading[role.id]))"
              :disabled="loading[role.id]"
              @click="$emit('delete', role)"
            >
              Delete
            </button>
          `,
        },
        SettingsLayout: {
          template:
            '<main><slot name="header" /><slot name="body" /><slot /></main>',
        },
        WootDeleteModal: {
          props: ['onConfirm'],
          template:
            '<button data-testid="confirm-delete" @click="onConfirm">Confirm</button>',
        },
        WootModal: {
          name: 'WootModal',
          props: ['show'],
          emits: ['update:show'],
          template: '<div><slot /></div>',
        },
      },
    },
  });

describe('Custom roles settings index', () => {
  beforeEach(() => {
    dispatch.mockReset();
    dispatch.mockResolvedValue();
    useAlert.mockReset();
    catalog.records = [{ id: 1, name: 'Employee', grants: [] }];
    catalog.mutationsEnabled = false;
    catalog.legacyMutationsEnabled = true;
    catalog.loaded = true;
  });

  it('owns loading per role and rejects duplicate deletion while pending', async () => {
    const resolveDeletion = new Map();
    dispatch.mockImplementation((action, id) => {
      if (action === 'customRole/deleteCustomRole') {
        return new Promise(resolve => {
          resolveDeletion.set(id, resolve);
        });
      }
      return Promise.resolve();
    });
    const wrapper = mountComponent();

    await wrapper.get('[data-testid="delete-role-7"]').trigger('click');
    await wrapper.get('[data-testid="confirm-delete"]').trigger('click');

    expect(
      wrapper.get('[data-testid="delete-role-7"]').attributes()
    ).toMatchObject({ 'data-loading': 'true', disabled: '' });
    expect(dispatch).toHaveBeenCalledWith(
      'customRole/deleteCustomRole',
      roles[0].id
    );

    wrapper
      .findComponent({ name: 'CustomRoleTableBody' })
      .vm.$emit('delete', roles[0]);
    await wrapper.get('[data-testid="confirm-delete"]').trigger('click');
    expect(
      dispatch.mock.calls.filter(
        ([action]) => action === 'customRole/deleteCustomRole'
      )
    ).toHaveLength(1);

    await wrapper.get('[data-testid="delete-role-8"]').trigger('click');
    await wrapper.get('[data-testid="confirm-delete"]').trigger('click');
    expect(
      wrapper.get('[data-testid="delete-role-8"]').attributes()
    ).toMatchObject({ 'data-loading': 'true', disabled: '' });

    resolveDeletion.get(roles[1].id)();
    await flushPromises();

    expect(
      wrapper.get('[data-testid="delete-role-8"]').attributes('data-loading')
    ).toBe('false');
    expect(
      wrapper.get('[data-testid="delete-role-8"]').attributes('disabled')
    ).toBeUndefined();
    expect(
      wrapper.get('[data-testid="delete-role-7"]').attributes('data-loading')
    ).toBe('true');

    resolveDeletion.get(roles[0].id)();
    await flushPromises();

    expect(
      wrapper.get('[data-testid="delete-role-7"]').attributes('data-loading')
    ).toBe('false');
  });

  it('uses the normalized delete command and hides the legacy table when enabled', async () => {
    const accessRole = {
      id: 12,
      name: 'Support',
      role_kind: 'custom',
      lock_version: 5,
      assigned_users_count: 0,
      grants: [],
    };
    catalog.records = [accessRole];
    catalog.mutationsEnabled = true;
    catalog.legacyMutationsEnabled = false;
    const wrapper = mountComponent();

    expect(wrapper.findComponent({ name: 'BaseTable' }).exists()).toBe(false);
    wrapper
      .findComponent({ name: 'AccessRoleMatrix' })
      .vm.$emit('delete', accessRole);
    catalog.records = [{ ...accessRole, lock_version: 6 }];
    await wrapper.get('[data-testid="confirm-delete"]').trigger('click');
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('customRole/deleteAccessRole', {
      id: accessRole.id,
      lockVersion: accessRole.lock_version,
    });
  });

  it('closes a stale editor when the refreshed role no longer exists', async () => {
    const accessRole = {
      id: 12,
      name: 'Support',
      role_kind: 'custom',
      lock_version: 5,
      assigned_users_count: 0,
      grants: [],
    };
    catalog.records = [accessRole];
    catalog.mutationsEnabled = true;
    catalog.legacyMutationsEnabled = false;
    const wrapper = mountComponent();
    wrapper
      .findComponent({ name: 'AccessRoleMatrix' })
      .vm.$emit('edit', accessRole);
    await wrapper.vm.$nextTick();
    expect(wrapper.findComponent({ name: 'WootModal' }).props('show')).toBe(
      true
    );
    catalog.records = [];

    wrapper.findComponent({ name: 'AccessRoleModal' }).vm.$emit('stale', 12);
    await wrapper.vm.$nextTick();

    expect(useAlert).toHaveBeenCalledWith(
      'CUSTOM_ROLE.ACCESS_EDITOR.NOT_FOUND_ERROR'
    );
    expect(wrapper.findComponent({ name: 'WootModal' }).props('show')).toBe(
      false
    );
  });

  it('opens a normalized clone draft for system roles', async () => {
    const systemRole = {
      id: 1,
      name: 'Сотрудник',
      role_kind: 'system',
      system_key: 'employee',
      assigned_users_count: 3,
      grants: [
        {
          resource: 'contacts',
          capability: 'view',
          access_scope: 'own',
        },
      ],
    };
    catalog.records = [systemRole];
    catalog.mutationsEnabled = true;
    catalog.legacyMutationsEnabled = false;
    const wrapper = mountComponent();

    wrapper
      .findComponent({ name: 'AccessRoleMatrix' })
      .vm.$emit('clone', systemRole);
    await wrapper.vm.$nextTick();

    expect(
      wrapper.findComponent({ name: 'AccessRoleModal' }).props()
    ).toMatchObject({
      mode: 'clone',
      selectedRole: systemRole,
    });
    expect(wrapper.findComponent({ name: 'WootModal' }).props('show')).toBe(
      true
    );
  });

  it('keeps role management read-only when neither writer is enabled', () => {
    catalog.mutationsEnabled = false;
    catalog.legacyMutationsEnabled = false;
    const wrapper = mountComponent();

    expect(wrapper.findComponent({ name: 'BaseTable' }).exists()).toBe(false);
    expect(wrapper.findComponent({ name: 'Button' }).props('disabled')).toBe(
      true
    );
    expect(
      wrapper
        .findComponent({ name: 'AccessRoleMatrix' })
        .props('mutationsEnabled')
    ).toBe(false);
  });
});
