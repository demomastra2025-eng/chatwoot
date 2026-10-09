import { ref } from 'vue';
import { describe, expect, it, vi } from 'vitest';
import {
  createAttachmentAvailability,
  isAttachmentConfirmedPurged,
} from '../useAttachmentAvailability';

const identity = () => ({
  accountId: '3',
  routeFullPath: '/app/accounts/3/conversations/7',
  selectedChatId: 7,
  selectedChatType: 'conversation',
  isCommunicationThread: false,
});

describe('useAttachmentAvailability', () => {
  it('uses explicit purged metadata and does not refetch it', async () => {
    const dispatch = vi.fn();
    const attachment = ref({ id: 81001, filePurged: true, dataUrl: '' });
    const status = createAttachmentAvailability({
      attachment,
      dispatch,
      getIdentity: identity,
    });

    expect(status.isPurged.value).toBe(true);
    await expect(status.refreshAfterMediaFailure()).resolves.toBe(true);
    expect(dispatch).not.toHaveBeenCalled();
  });

  it('keeps a missing or failed refresh as a media failure and checks only once', async () => {
    const dispatch = vi.fn().mockResolvedValue([]);
    const attachment = ref({
      id: 81002,
      filePurged: false,
      dataUrl: 'https://media.example.test/expired-url',
    });
    const status = createAttachmentAvailability({
      attachment,
      dispatch,
      getIdentity: identity,
    });

    await expect(status.refreshAfterMediaFailure()).resolves.toBe(false);
    await expect(status.refreshAfterMediaFailure()).resolves.toBe(false);

    expect(dispatch).toHaveBeenCalledTimes(1);
    expect(status.isPurged.value).toBe(false);
    expect(isAttachmentConfirmedPurged(81002, identity())).toBe(false);
  });

  it('keeps a failed permission-scoped request as a media failure', async () => {
    const dispatch = vi.fn().mockRejectedValue(new Error('network failure'));
    const attachment = ref({
      id: 81007,
      dataUrl: 'https://media.example.test/expired-url',
    });
    const status = createAttachmentAvailability({
      attachment,
      dispatch,
      getIdentity: identity,
    });

    await expect(status.refreshAfterMediaFailure()).resolves.toBe(false);
    expect(status.isPurged.value).toBe(false);
    expect(isAttachmentConfirmedPurged(81007, identity())).toBe(false);
  });

  it('suppresses a stale URL only when the authorized response confirms purge', async () => {
    const dispatch = vi.fn().mockResolvedValue([
      { id: 81003, file_purged: true, data_url: '', thumb_url: '' },
    ]);
    const attachment = ref({
      id: 81003,
      filePurged: false,
      dataUrl: 'https://media.example.test/stale-url',
    });
    const status = createAttachmentAvailability({
      attachment,
      dispatch,
      getIdentity: identity,
    });

    await expect(status.refreshAfterMediaFailure()).resolves.toBe(true);

    expect(dispatch).toHaveBeenCalledWith(
      'fetchAllAttachments',
      expect.objectContaining({
        conversationId: 7,
        expectedAccountId: '3',
        expectedRouteFullPath: '/app/accounts/3/conversations/7',
        expectedSelectedChatId: 7,
        expectedSelectedChatType: 'conversation',
      })
    );
    expect(status.isPurged.value).toBe(true);
    expect(isAttachmentConfirmedPurged(81003, identity())).toBe(true);
    expect(
      isAttachmentConfirmedPurged(81003, {
        ...identity(),
        accountId: '4',
      })
    ).toBe(false);
  });

  it('does not apply a purge result after the account or selected chat changes', async () => {
    let currentIdentity = identity();
    let resolveRefresh;
    const dispatch = vi.fn(
      () =>
        new Promise(resolve => {
          resolveRefresh = resolve;
        })
    );
    const attachment = ref({ id: 81004, dataUrl: 'https://media.test/stale' });
    const status = createAttachmentAvailability({
      attachment,
      dispatch,
      getIdentity: () => currentIdentity,
    });

    const refresh = status.refreshAfterMediaFailure();
    await Promise.resolve();
    currentIdentity = {
      ...currentIdentity,
      accountId: '4',
      routeFullPath: '/app/accounts/4/conversations/8',
      selectedChatId: 8,
    };
    resolveRefresh([{ id: 81004, file_purged: true, data_url: '' }]);

    await expect(refresh).resolves.toBe(false);
    expect(status.isPurged.value).toBe(false);
    expect(isAttachmentConfirmedPurged(81004, identity())).toBe(false);
  });

  it('deduplicates checks for the same attachment while a request is in flight', async () => {
    let resolveRefresh;
    const dispatch = vi.fn(
      () =>
        new Promise(resolve => {
          resolveRefresh = resolve;
        })
    );
    const attachment = ref({ id: 81005, dataUrl: 'https://media.test/stale' });
    const status = createAttachmentAvailability({
      attachment,
      dispatch,
      getIdentity: identity,
    });

    const firstRefresh = status.refreshAfterMediaFailure();
    const secondRefresh = status.refreshAfterMediaFailure();
    await Promise.resolve();
    resolveRefresh([{ id: 81005, file_purged: false, data_url: 'fresh' }]);

    await Promise.all([firstRefresh, secondRefresh]);
    expect(dispatch).toHaveBeenCalledTimes(1);
    expect(status.isPurged.value).toBe(false);
  });
});
