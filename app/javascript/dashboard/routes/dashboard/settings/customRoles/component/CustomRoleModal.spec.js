import { flushPromises, mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import CustomRoleModal from './CustomRoleModal.vue';

const { dispatch, useAlert } = vi.hoisted(() => ({
  dispatch: vi.fn().mockResolvedValue(),
  useAlert: vi.fn(),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch }),
}));

vi.mock('dashboard/composables', () => ({ useAlert }));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

const mountComponent = () =>
  mount(CustomRoleModal, {
    props: {
      mode: 'edit',
      selectedRole: {
        id: 42,
        name: 'Automation manager',
        description: 'Manages automation rules',
        permissions: ['automation_manage'],
      },
    },
    global: {
      mocks: { $t: key => key },
      stubs: {
        WootModalHeader: true,
        Button: {
          props: ['type', 'label', 'disabled'],
          template:
            '<button :type="type" :disabled="disabled">{{ label }}</button>',
        },
        Checkbox: {
          props: ['modelValue', 'value', 'id'],
          emits: ['update:modelValue'],
          template:
            '<input :id="id" type="checkbox" :checked="modelValue.includes(value)" />',
        },
      },
    },
  });

describe('CustomRoleModal', () => {
  it('renders and submits the Automation management permission', async () => {
    dispatch.mockClear();
    const wrapper = mountComponent();

    expect(wrapper.get('#automation_manage').exists()).toBe(true);

    await wrapper.get('form').trigger('submit');
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('customRole/updateCustomRole', {
      id: 42,
      name: 'Automation manager',
      description: 'Manages automation rules',
      permissions: ['automation_manage'],
    });
  });
});
