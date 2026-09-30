import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';

import enCampaign from 'dashboard/i18n/locale/en/campaign.json';
import {
  reminderErrorMessage,
  reminderLastError,
  withReminderWording,
} from './reminderErrors';
import ConfirmDeleteTouchDialog from './ConfirmDeleteTouchDialog.vue';
import TouchAnalyticsDialog from './TouchAnalyticsDialog.vue';

const mocks = vi.hoisted(() => ({ delete: vi.fn(), useAlert: vi.fn() }));

vi.mock('dashboard/api/touches', () => ({
  default: { delete: mocks.delete },
}));

vi.mock('dashboard/composables', () => ({ useAlert: mocks.useAlert }));

const ERRORS = enCampaign.OUTBOUND_WORKSPACE.TOUCHES.ERRORS;
const t = key => `t:${key}`;
const httpError = data => ({
  message: 'Request failed with status code 422',
  response: { status: 422, data },
});

const DialogStub = {
  name: 'Dialog',
  emits: ['confirm'],
  template:
    '<div><slot /><button data-test="confirm" @click="$emit(\'confirm\')" /></div>',
};

describe('reminderErrors', () => {
  it('rewords «touch» in backend texts as «reminder»', () => {
    expect(
      withReminderWording('Body must be present for message touches')
    ).toBe('Body must be present for message reminders');
    expect(withReminderWording('Touch plan does not support this entity')).toBe(
      'Reminder plan does not support this entity'
    );
    expect(
      withReminderWording('apply_touch_plan requires a valid touch plan')
    ).toBe('apply_reminder_plan requires a valid reminder plan');
    expect(withReminderWording('Provider delivery failed')).toBe(
      'Provider delivery failed'
    );
  });

  it('maps known backend messages to localized texts', () => {
    expect(
      reminderErrorMessage(
        httpError({
          error: 'An open touch with the same content already exists',
        }),
        'fallback',
        t
      )
    ).toBe('t:OUTBOUND_WORKSPACE.TOUCHES.ERRORS.DUPLICATE');
    expect(
      reminderErrorMessage(
        httpError({ error: 'Only unsent delayed messages can be deleted.' }),
        'fallback',
        t
      )
    ).toBe('t:OUTBOUND_WORKSPACE.TOUCHES.ERRORS.NOT_DELETABLE');
  });

  it('uses the localized fallback when the backend sends no text', () => {
    expect(reminderErrorMessage(httpError({}), 'fallback', t)).toBe('fallback');
    expect(reminderErrorMessage(null, 'fallback', t)).toBe('fallback');
  });

  it('keeps messages thrown by the page itself', () => {
    expect(reminderErrorMessage(new Error('File is too big'), 'x', t)).toBe(
      'File is too big'
    );
  });

  it('localizes or rewords a stored delivery error', () => {
    expect(
      reminderLastError(
        'Touch target is not deliverable for the selected inbox',
        t
      )
    ).toBe('t:OUTBOUND_WORKSPACE.TOUCHES.ERRORS.TARGET_NOT_DELIVERABLE');
    expect(reminderLastError('live touch plan was deleted', t)).toBe(
      'live reminder plan was deleted'
    );
    expect(reminderLastError('', t)).toBe('');
  });
});

describe('reminder dialogs', () => {
  beforeEach(() => {
    mocks.delete.mockReset();
    mocks.useAlert.mockReset();
  });

  it('delete dialog shows a localized toast instead of the backend text', async () => {
    mocks.delete.mockRejectedValueOnce(
      httpError({ error: 'Only unsent delayed messages can be deleted.' })
    );
    const wrapper = mount(ConfirmDeleteTouchDialog, {
      props: { selectedTouch: { id: 8 } },
      global: { stubs: { Dialog: DialogStub } },
    });

    await wrapper.find('[data-test="confirm"]').trigger('click');
    await flushPromises();

    expect(mocks.delete).toHaveBeenCalledWith(8);
    expect(mocks.useAlert).toHaveBeenCalledWith(ERRORS.NOT_DELETABLE);
  });

  it('analytics dialog never prints «touch» from the stored error', () => {
    const wrapper = mount(TouchAnalyticsDialog, {
      props: {
        selectedTouch: {
          id: 8,
          status: 'failed',
          last_error: 'Touch target is not deliverable for the selected inbox',
        },
      },
      global: { stubs: { Dialog: DialogStub, Button: true, Icon: true } },
    });

    const error = wrapper.find('[data-test="reminder-last-error"]');
    expect(error.text()).toBe(ERRORS.TARGET_NOT_DELIVERABLE);
    expect(wrapper.text()).not.toMatch(/touch/i);
  });
});
