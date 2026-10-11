import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

import CrmClosingReasonDialog from './CrmClosingReasonDialog.vue';

const DialogStub = {
  name: 'Dialog',
  props: ['disableConfirmButton'],
  methods: {
    close() {},
    open() {},
  },
  template:
    '<div :data-confirm-disabled="String(disableConfirmButton)"><slot /></div>',
};

const ComboBoxStub = {
  name: 'ComboBox',
  props: ['modelValue', 'options'],
  template:
    '<div data-test="reason-options">{{ JSON.stringify(options) }}</div>',
};

const mountDialog = () =>
  mount(CrmClosingReasonDialog, {
    global: {
      stubs: { ComboBox: ComboBoxStub, Dialog: DialogStub },
    },
  });

describe('CrmClosingReasonDialog', () => {
  it('does not offer an empty reason when the Lost stage requires a reason', async () => {
    const wrapper = mountDialog();

    wrapper.vm.open({
      kind: 'closing',
      targetStage: {
        closingReasonOptions: ['Too expensive'],
        closingReasonRequired: true,
        name: 'Lost',
        outcome: 'lost',
      },
    });
    await wrapper.vm.$nextTick();

    expect(wrapper.find('[data-test="reason-options"]').text()).toContain(
      'Too expensive'
    );
    expect(wrapper.find('[data-test="reason-options"]').text()).not.toContain(
      '__crm_no_reason__'
    );
    expect(
      wrapper
        .find('[data-confirm-disabled]')
        .attributes('data-confirm-disabled')
    ).toBe('true');
  });

  it('does not open a reason dialog for an ordinary stage with legacy transition options', async () => {
    const wrapper = mountDialog();
    const dialog = wrapper.findComponent({ name: 'Dialog' });
    const open = vi.spyOn(dialog.vm, 'open');
    const result = wrapper.vm.open({
      kind: 'transition',
      targetStage: {
        transitionReasonOptions: ['Needs documents'],
        transitionReasonRequired: true,
        name: 'Proposal',
        outcome: 'open',
      },
    });
    await wrapper.vm.$nextTick();

    await expect(result).resolves.toEqual([]);
    expect(open).not.toHaveBeenCalled();
    expect(wrapper.find('[data-test="reason-options"]').text()).not.toContain(
      'Needs documents'
    );
  });

  it('keeps the explicit no-reason option when the Lost toggle is disabled', async () => {
    const wrapper = mountDialog();

    wrapper.vm.open({
      kind: 'closing',
      targetStage: {
        closingReasonOptions: ['Too expensive'],
        closingReasonRequired: false,
        name: 'Lost',
        outcome: 'lost',
      },
    });
    await wrapper.vm.$nextTick();

    expect(wrapper.find('[data-test="reason-options"]').text()).toContain(
      '__crm_no_reason__'
    );
    expect(
      wrapper
        .find('[data-confirm-disabled]')
        .attributes('data-confirm-disabled')
    ).toBe('false');
  });

  it('returns the selected Lost reason and keeps cancellation distinct from no reason', async () => {
    const wrapper = mountDialog();
    const targetStage = {
      outcome: 'lost',
      name: 'Lost',
      closingReasonOptions: ['Too expensive'],
      closingReasonRequired: true,
    };
    const selected = wrapper.vm.open({ targetStage });
    await wrapper.vm.$nextTick();
    wrapper
      .findComponent({ name: 'ComboBox' })
      .vm.$emit('update:modelValue', 'Too expensive');
    await wrapper.vm.$nextTick();
    wrapper.findComponent({ name: 'Dialog' }).vm.$emit('confirm');
    await expect(selected).resolves.toEqual(['Too expensive']);
    const cancelled = wrapper.vm.open({ targetStage });
    wrapper.findComponent({ name: 'Dialog' }).vm.$emit('close');
    await expect(cancelled).resolves.toBe(wrapper.vm.CANCELLED);
  });
});
