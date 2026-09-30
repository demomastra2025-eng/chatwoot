import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import { createStore } from 'vuex';

import enCampaign from 'dashboard/i18n/locale/en/campaign.json';
import TouchEditorDrawer from './TouchEditorDrawer.vue';

const mocks = vi.hoisted(() => ({
  create: vi.fn(),
  update: vi.fn(),
  useAlert: vi.fn(),
}));

vi.mock('dashboard/api/touches', () => ({
  default: { create: mocks.create, update: mocks.update },
}));

vi.mock('dashboard/composables', () => ({ useAlert: mocks.useAlert }));

const ERRORS = enCampaign.OUTBOUND_WORKSPACE.TOUCHES.ERRORS;

const buildStore = () =>
  createStore({
    getters: {
      getCurrentAccountId: () => 1,
      getCannedResponses: () => [],
      'inboxes/getAllInboxes': () => [],
      'inboxes/getFilteredWhatsAppTemplates': () => () => [],
    },
    actions: { getCannedResponse: () => {} },
  });

const existingReminder = {
  id: 3,
  action_type: 'send_message',
  body: 'See you tomorrow at 10:00',
  content_kind: 'free_text',
  timing_mode: 'absolute',
  scheduled_at: '2030-01-01T10:00:00Z',
  remindable: { id: 5, type: 'Conversation' },
  conversation_id: 5,
  attachments: [],
};

const mountDrawer = () =>
  mount(TouchEditorDrawer, {
    props: {
      modelValue: true,
      conversationId: 5,
      remindableId: 5,
      remindableType: 'Conversation',
      touch: existingReminder,
    },
    global: {
      plugins: [buildStore()],
      stubs: {
        TouchEditorShell: {
          name: 'TouchEditorShell',
          emits: ['confirm'],
          template:
            '<div><slot /><button data-test="save" @click="$emit(\'confirm\')" /></div>',
        },
        TouchMessageComposer: true,
        TagMultiSelectComboBox: true,
        SchedulingDateTimeField: true,
        SchedulingFormFieldGroup: true,
        SchedulingRelativeOffsetInput: true,
        SchedulingSelectField: true,
        TabBar: true,
        Checkbox: true,
        Input: true,
        Button: true,
      },
    },
  });

const saveWithError = async error => {
  mocks.update.mockRejectedValueOnce(error);
  const wrapper = mountDrawer();
  await flushPromises();
  await wrapper.find('[data-test="save"]').trigger('click');
  await flushPromises();
  return mocks.useAlert.mock.calls.map(([message]) => message);
};

describe('TouchEditorDrawer error toasts (reminders)', () => {
  beforeEach(() => {
    mocks.useAlert.mockReset();
    mocks.update.mockReset();
  });

  it('shows the localized text for a duplicate reminder instead of the backend «touch» text', async () => {
    const alerts = await saveWithError({
      response: {
        status: 422,
        data: { error: 'An open touch with the same content already exists' },
      },
    });

    expect(mocks.update).toHaveBeenCalledWith(3, expect.any(Object));
    expect(alerts).toEqual([ERRORS.DUPLICATE]);
  });

  it('shows the localized text when a sent reminder can no longer be changed', async () => {
    const alerts = await saveWithError({
      response: {
        status: 422,
        data: { error: 'Only unsent open touches can be updated.' },
      },
    });

    expect(alerts).toEqual([ERRORS.NOT_EDITABLE]);
  });

  it('never shows the word «touch» for other validation errors', async () => {
    const alerts = await saveWithError({
      response: {
        status: 422,
        data: { error: 'Body must be present for message touches' },
      },
    });

    expect(alerts).toEqual(['Body must be present for message reminders']);
    alerts.forEach(message => expect(message).not.toMatch(/touch/i));
  });

  it('falls back to the localized save error without a backend text', async () => {
    const alerts = await saveWithError({
      message: 'Request failed with status code 500',
      response: { status: 500, data: {} },
    });

    expect(alerts).toEqual([
      enCampaign.OUTBOUND_WORKSPACE.TOUCH_EDITOR.ERRORS.SAVE,
    ]);
  });
});
