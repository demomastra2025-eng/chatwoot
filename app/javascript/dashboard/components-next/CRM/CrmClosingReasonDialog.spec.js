import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

import CrmClosingReasonDialog from './CrmClosingReasonDialog.vue';

const DialogStub = {
  props: ['disableConfirmButton'],
  methods: {
    close() {},
    open() {},
  },
  template:
    '<div :data-confirm-disabled="String(disableConfirmButton)"><slot /></div>',
};

const ComboBoxStub = {
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

  it('requires a configured transition reason for the target open stage', async () => {
    const wrapper = mountDialog();

    wrapper.vm.open({
      kind: 'transition',
      targetStage: {
        transitionReasonOptions: ['Needs documents'],
        transitionReasonRequired: true,
        name: 'Proposal',
      },
    });
    await wrapper.vm.$nextTick();

    expect(wrapper.find('[data-test="reason-options"]').text()).toContain(
      'Needs documents'
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

  it('keeps the explicit no-reason option when the Lost toggle is disabled', async () => {
    const wrapper = mountDialog();

    wrapper.vm.open({
      kind: 'closing',
      targetStage: {
        closingReasonOptions: ['Too expensive'],
        closingReasonRequired: false,
        name: 'Lost',
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
});
