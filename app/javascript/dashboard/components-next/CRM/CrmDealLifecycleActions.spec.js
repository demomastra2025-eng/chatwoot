import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

import CrmDealLifecycleActions from './CrmDealLifecycleActions.vue';

const ButtonStub = {
  props: ['disabled', 'label'],
  emits: ['click'],
  template:
    '<button :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
};

const DialogStub = {
  props: ['confirmButtonLabel'],
  emits: ['close', 'confirm'],
  methods: {
    close() {},
    open() {},
  },
  template:
    '<div><button data-test="dialog-confirm" @click="$emit(\'confirm\')">{{ confirmButtonLabel }}</button></div>',
};

const mountActions = props =>
  mount(CrmDealLifecycleActions, {
    props,
    global: {
      mocks: { $t: key => key },
      stubs: { Button: ButtonStub, Dialog: DialogStub },
    },
  });

describe('CrmDealLifecycleActions', () => {
  it('shows explicit Won and Lost actions for an open deal', () => {
    const wrapper = mountActions({ outcome: 'open' });

    expect(wrapper.find('[data-test="close-won"]').exists()).toBe(true);
    expect(wrapper.find('[data-test="close-lost"]').exists()).toBe(true);
    expect(wrapper.find('[data-test="reopen"]').exists()).toBe(false);
  });

  it('shows Reopen for a terminal deal and Undo only while it is available', () => {
    const wrapper = mountActions({ canUndo: true, outcome: 'lost' });

    expect(wrapper.find('[data-test="reopen"]').exists()).toBe(true);
    expect(wrapper.find('[data-test="undo"]').exists()).toBe(true);
    expect(wrapper.find('[data-test="close-lost"]').exists()).toBe(false);
  });

  it.each([
    ['close-won', 'closeWon', 'open'],
    ['close-lost', 'closeLost', 'open'],
    ['reopen', 'reopen', 'lost'],
    ['undo', 'undo', 'lost'],
  ])('confirms %s before emitting %s', async (button, event, outcome) => {
    const wrapper = mountActions({ canUndo: true, outcome });

    await wrapper.find(`[data-test="${button}"]`).trigger('click');
    await wrapper.find('[data-test="dialog-confirm"]').trigger('click');

    expect(wrapper.emitted(event)).toHaveLength(1);
  });

  it('disables commands while the deal form contains unsaved changes', () => {
    const wrapper = mountActions({
      disabled: true,
      disabledReason: 'Save changes first',
      outcome: 'open',
    });

    expect(
      wrapper.find('[data-test="close-won"]').attributes('disabled')
    ).toBeDefined();
    expect(wrapper.find('[data-test="disabled-reason"]').text()).toBe(
      'Save changes first'
    );
  });
});
