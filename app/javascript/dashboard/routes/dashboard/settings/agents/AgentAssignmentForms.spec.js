import { flushPromises, shallowMount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';

import AddAgent from './AddAgent.vue';
import EditAgent from './EditAgent.vue';

const { catalog, customRoles, dispatch, useAlert } = vi.hoisted(() => ({
  catalog: {
    records: [
      { id: 10, name: 'Employee', system_key: 'employee' },
      { id: 11, name: 'Observer', system_key: 'observer' },
    ],
    assignmentsEnabled: true,
    legacyAssignmentsEnabled: false,
    loaded: true,
    error: false,
  },
  customRoles: [{ id: 7, name: 'Legacy support' }],
  dispatch: vi.fn(),
  useAlert: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables', () => ({ useAlert }));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch }),
  useMapGetter: key => {
    if (key === 'agents/getUIFlags') {
      return ref({ isCreating: false, isUpdating: false });
    }
    if (key === 'agents/getAgentById') {
      return ref(() => ({ access_role_id: 12 }));
    }
    if (key === 'customRole/getCustomRoles') return ref(customRoles);
    if (key === 'customRole/getAccessRoleCatalog') return ref(catalog);
    return ref(null);
  },
}));

vi.mock('../../../../api/auth', () => ({
  default: { resetPassword: vi.fn() },
}));

const global = {
  mocks: { $t: key => key },
  stubs: {
    WootModalHeader: true,
    Button: {
      props: ['type', 'disabled'],
      template: '<button :type="type" :disabled="disabled"><slot /></button>',
    },
    Select: {
      props: ['modelValue'],
      emits: ['update:modelValue', 'change'],
      template: `
        <select
          :value="modelValue"
          @change="$emit('update:modelValue', $event.target.value); $emit('change')"
        >
          <slot />
        </select>
      `,
    },
  },
};

describe('agent assignment forms', () => {
  beforeEach(() => {
    dispatch.mockReset();
    dispatch.mockResolvedValue();
    useAlert.mockReset();
    catalog.assignmentsEnabled = true;
  });

  it('creates an agent with only the canonical access role field', async () => {
    const wrapper = shallowMount(AddAgent, { global });
    const inputs = wrapper.findAll('input');
    await inputs[0].setValue('New observer');
    await inputs[1].setValue('observer@example.com');
    await wrapper.get('select').setValue('access:11');
    await wrapper.get('form').trigger('submit');
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('agents/create', {
      name: 'New observer',
      email: 'observer@example.com',
      access_role_id: 11,
    });
  });

  it('updates an agent with canonical stale-assignment protection', async () => {
    const wrapper = shallowMount(EditAgent, {
      props: {
        id: 42,
        name: 'Existing agent',
        email: 'agent@example.com',
        type: 'agent',
        availability: 'online',
        accessRoleId: 10,
      },
      global,
    });
    await wrapper.get('select').setValue('access:11');
    await wrapper.get('form').trigger('submit');
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('agents/update', {
      id: 42,
      name: 'Existing agent',
      availability: 'online',
      access_role_id: 11,
      previous_access_role_id: 10,
    });
  });

  it('keeps the legacy payload contract when assignment capability is absent', async () => {
    catalog.assignmentsEnabled = false;
    const wrapper = shallowMount(EditAgent, {
      props: {
        id: 42,
        name: 'Legacy agent',
        email: 'legacy@example.com',
        type: 'agent',
        availability: 'online',
        customRoleId: 7,
        accessRoleId: 10,
      },
      global,
    });
    await wrapper.get('form').trigger('submit');
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('agents/update', {
      id: 42,
      name: 'Legacy agent',
      availability: 'online',
      custom_role_id: 7,
    });
  });

  it('rebases only the stale baseline and preserves the selected draft role', async () => {
    const staleError = {
      response: { data: { code: 'STALE_ACCESS_ROLE_ASSIGNMENT' } },
    };
    let updateAttempts = 0;
    dispatch.mockImplementation(action => {
      if (action === 'agents/update' && updateAttempts === 0) {
        updateAttempts += 1;
        return Promise.reject(staleError);
      }
      if (action === 'agents/get') {
        return Promise.resolve([{ id: 42, access_role_id: 12 }]);
      }
      return Promise.resolve();
    });
    const wrapper = shallowMount(EditAgent, {
      props: {
        id: 42,
        name: 'Existing agent',
        email: 'agent@example.com',
        type: 'agent',
        availability: 'online',
        accessRoleId: 10,
      },
      global,
    });
    await wrapper.get('select').setValue('access:11');
    await wrapper.get('form').trigger('submit');
    await flushPromises();
    await wrapper.get('form').trigger('submit');
    await flushPromises();

    const updateCalls = dispatch.mock.calls.filter(
      ([action]) => action === 'agents/update'
    );
    expect(updateCalls).toEqual([
      [
        'agents/update',
        expect.objectContaining({
          access_role_id: 11,
          previous_access_role_id: 10,
        }),
      ],
      [
        'agents/update',
        expect.objectContaining({
          access_role_id: 11,
          previous_access_role_id: 12,
        }),
      ],
    ]);
    expect(dispatch).toHaveBeenCalledWith('agents/get', {
      throwOnError: true,
    });
    expect(dispatch).toHaveBeenCalledWith('customRole/fetchAccessRoleCatalog', {
      throwOnError: true,
    });
  });

  it('keeps the stale baseline when the authoritative refresh fails', async () => {
    const staleError = {
      response: { data: { code: 'STALE_ACCESS_ROLE_ASSIGNMENT' } },
    };
    let updateAttempts = 0;
    dispatch.mockImplementation(action => {
      if (action === 'agents/update') {
        updateAttempts += 1;
        return updateAttempts === 1
          ? Promise.reject(staleError)
          : Promise.resolve();
      }
      if (action === 'agents/get') {
        return Promise.reject(new Error('refresh failed'));
      }
      return Promise.resolve();
    });
    const wrapper = shallowMount(EditAgent, {
      props: {
        id: 42,
        name: 'Existing agent',
        email: 'agent@example.com',
        type: 'agent',
        availability: 'online',
        accessRoleId: 10,
      },
      global,
    });
    await wrapper.get('select').setValue('access:11');
    await wrapper.get('form').trigger('submit');
    await flushPromises();
    await wrapper.get('form').trigger('submit');
    await flushPromises();

    const updateCalls = dispatch.mock.calls.filter(
      ([action]) => action === 'agents/update'
    );
    expect(updateCalls[1][1]).toEqual(
      expect.objectContaining({ previous_access_role_id: 10 })
    );
  });
});
