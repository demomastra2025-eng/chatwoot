import { beforeEach, describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import { ref } from 'vue';

import PersonDialogActions from './PersonDialogActions.vue';

const openPersonDialog = vi.hoisted(() => vi.fn());
const inboxes = vi.hoisted(() => ({ value: [] }));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables/useOpenPersonDialog', () => ({
  useOpenPersonDialog: () => ({ openPersonDialog }),
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => ref(inboxes.value),
  useStore: () => ({}),
}));

const VoiceCallButtonStub = {
  name: 'VoiceCallButton',
  props: ['phone', 'contactId', 'label'],
  emits: ['callInitiated'],
  template: '<button data-test="voice-call" />',
};
const ButtonStub = {
  props: ['label', 'disabled', 'icon'],
  emits: ['click'],
  template:
    '<button :disabled="disabled" :data-label="label" @click="$emit(\'click\')" />',
};

const mountActions = (props = {}) =>
  mount(PersonDialogActions, {
    props: { contactId: 5, phone: '+77011234567', ...props },
    global: {
      stubs: { VoiceCallButton: VoiceCallButtonStub, Button: ButtonStub },
      directives: { tooltip: {} },
    },
  });

describe('PersonDialogActions', () => {
  beforeEach(() => {
    openPersonDialog.mockReset();
    inboxes.value = [{ id: 1, channel_type: 'Channel::Voice' }];
  });

  it('writes by opening the dialog of the person, whatever they have already', async () => {
    const wrapper = mountActions();

    await wrapper.find('[data-test-id="person-dialog-write"]').trigger('click');

    expect(openPersonDialog).toHaveBeenCalledWith(5, {
      patientContactId: null,
    });
    expect(wrapper.emitted('write')).toEqual([[5]]);
  });

  it('keeps the patient the dialog is about when it is held with someone else', async () => {
    const wrapper = mountActions({ contactId: 9, patientContactId: 5 });

    await wrapper.find('[data-test-id="person-dialog-write"]').trigger('click');

    expect(openPersonDialog).toHaveBeenCalledWith(9, { patientContactId: 5 });
  });

  it('calls through the voice button and reports the started call', async () => {
    const wrapper = mountActions();

    wrapper
      .findComponent(VoiceCallButtonStub)
      .vm.$emit('callInitiated', { communication_thread_id: 77 });

    expect(wrapper.emitted('callInitiated')).toEqual([
      [{ communication_thread_id: 77 }],
    ]);
  });

  it('hides the call when the user has no voice inbox', () => {
    inboxes.value = [{ id: 2, channel_type: 'Channel::Whatsapp' }];
    const wrapper = mountActions();

    expect(wrapper.findComponent(VoiceCallButtonStub).exists()).toBe(false);
    expect(
      wrapper.find('[data-test-id="person-dialog-call-disabled"]').exists()
    ).toBe(false);
    expect(wrapper.find('[data-test-id="person-dialog-write"]').exists()).toBe(
      true
    );
  });

  it('shows a disabled call with a reason when the person has no phone', () => {
    const wrapper = mountActions({ phone: '' });

    expect(wrapper.findComponent(VoiceCallButtonStub).exists()).toBe(false);
    expect(
      wrapper
        .find('[data-test-id="person-dialog-call-disabled"]')
        .attributes('disabled')
    ).toBeDefined();
  });

  it('can show only the call or only the write button', () => {
    const onlyCall = mountActions({ showWrite: false });
    const onlyWrite = mountActions({ showCall: false });

    expect(onlyCall.find('[data-test-id="person-dialog-write"]').exists()).toBe(
      false
    );
    expect(onlyCall.findComponent(VoiceCallButtonStub).exists()).toBe(true);
    expect(onlyWrite.findComponent(VoiceCallButtonStub).exists()).toBe(false);
    expect(
      onlyWrite.find('[data-test-id="person-dialog-write"]').exists()
    ).toBe(true);
  });
});
