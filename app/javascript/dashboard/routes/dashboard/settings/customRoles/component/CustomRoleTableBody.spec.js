import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import CustomRoleTableBody from './CustomRoleTableBody.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

const role = {
  id: 7,
  name: 'Operator',
  description: 'Handles conversations',
  permissions: ['conversation_manage'],
};

const mountComponent = loading =>
  mount(CustomRoleTableBody, {
    props: {
      roles: [role],
      loading,
    },
    global: {
      mocks: {
        $t: key => key,
      },
      stubs: {
        BaseTableRow: {
          template: '<div><slot /></div>',
        },
        BaseTableCell: {
          template: '<div><slot /></div>',
        },
        Button: {
          props: ['icon', 'isLoading', 'disabled'],
          emits: ['click'],
          template: `
            <button
              :data-icon="icon"
              :data-loading="String(Boolean(isLoading))"
              :disabled="disabled"
              @click="$emit('click')"
            />
          `,
        },
      },
    },
  });

describe('CustomRoleTableBody', () => {
  it('disables the delete action while that role is loading', async () => {
    const wrapper = mountComponent({ [role.id]: true });
    const deleteButton = wrapper.get('[data-icon="i-woot-bin"]');

    expect(deleteButton.attributes()).toMatchObject({
      'data-loading': 'true',
      disabled: '',
    });
    await deleteButton.trigger('click');
    expect(wrapper.emitted('delete')).toBeUndefined();
  });

  it('keeps another role-independent delete action enabled', () => {
    const wrapper = mountComponent({ 8: true });
    const deleteButton = wrapper.get('[data-icon="i-woot-bin"]');

    expect(deleteButton.attributes('data-loading')).toBe('false');
    expect(deleteButton.attributes('disabled')).toBeUndefined();
  });
});
