import { flushPromises, shallowMount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';

import Index from './Index.vue';

const { dispatch } = vi.hoisted(() => ({
  dispatch: vi.fn(),
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
  useAlert: vi.fn(),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch }),
  useMapGetter: key => {
    if (key === 'customRole/getCustomRoles') return ref(roles);
    if (key === 'customRole/getAccessRoleCatalog') {
      return ref({
        records: [{ id: 1, name: 'Employee', grants: [] }],
        resources: {},
        accessScopes: [],
        error: false,
      });
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
        AccessRoleMatrix: true,
        BaseSettingsHeader: {
          template: '<header><slot name="actions" /></header>',
        },
        BaseTable: {
          props: ['items'],
          template: '<div><slot name="row" :items="items" /></div>',
        },
        Button: true,
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
        WootModal: true,
      },
    },
  });

describe('Custom roles settings index', () => {
  beforeEach(() => {
    dispatch.mockReset();
    dispatch.mockResolvedValue();
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
});
