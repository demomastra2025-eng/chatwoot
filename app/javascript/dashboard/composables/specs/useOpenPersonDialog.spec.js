import { beforeEach, describe, expect, it, vi } from 'vitest';

import { useOpenPersonDialog } from '../useOpenPersonDialog';

const push = vi.hoisted(() => vi.fn());
const injected = vi.hoisted(() => ({ opener: null }));

vi.mock('vue-router', () => ({
  useRouter: () => ({ push }),
  useRoute: () => ({ params: { accountId: 3 } }),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ getters: { getCurrentAccountId: 3 } }),
}));

vi.mock('vue', async importOriginal => ({
  ...(await importOriginal()),
  inject: vi.fn(() => injected.opener),
}));

describe('useOpenPersonDialog', () => {
  beforeEach(() => {
    push.mockReset();
    injected.opener = null;
  });

  it('opens the dialog of the person on its own screen', () => {
    useOpenPersonDialog().openPersonDialog(5);

    expect(push).toHaveBeenCalledWith({
      name: 'communication_thread_contact',
      params: { accountId: 3, contact_id: 5 },
      query: {},
    });
  });

  it('names the patient and the channel the dialog is opened from', () => {
    useOpenPersonDialog().openPersonDialog(9, {
      patientContactId: 5,
      replyInboxId: 12,
    });

    expect(push.mock.calls[0][0].query).toEqual({
      patientContactId: '5',
      patientChatContactId: '9',
      replyInbox: '12',
    });
  });

  it('leaves the page to the panel that shows the dialog beside it', () => {
    injected.opener = vi.fn();

    useOpenPersonDialog().openPersonDialog(5, { replyInboxId: 12 });

    expect(injected.opener).toHaveBeenCalledWith(5, {
      patientContactId: null,
      replyInboxId: 12,
    });
    expect(push).not.toHaveBeenCalled();
  });
});
