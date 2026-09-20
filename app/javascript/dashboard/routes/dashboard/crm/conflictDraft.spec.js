import { describe, expect, it } from 'vitest';

import {
  assertCrmEditCurrent,
  changedDraftPayload,
  changedObjectKeys,
  isStaleCrmError,
  rebaseSnapshotLockVersion,
} from './conflictDraft';

describe('CRM conflict draft helpers', () => {
  it('retries only fields changed by the local draft', () => {
    expect(
      changedDraftPayload(
        {
          description: 'Server baseline',
          lock_version: 1,
          owner_id: 4,
          title: 'Original',
        },
        {
          description: 'Server baseline',
          lock_version: 3,
          owner_id: 4,
          title: 'Local draft',
        },
        ['lock_version']
      )
    ).toEqual({ title: 'Local draft' });
  });

  it('sends only changed custom-field keys and nulls for local clears', () => {
    expect(
      changedObjectKeys(
        { cleared: 'remove me', local: 1, remote: 1 },
        { local: 2, remote: 1 }
      )
    ).toEqual({ cleared: null, local: 2 });

    expect(
      changedDraftPayload(
        { custom_attributes: { local: 1, remote: 1 } },
        { custom_attributes: { local: 2, remote: 1 } }
      )
    ).toEqual({ custom_attributes: { local: 2 } });
  });

  it('rejects a local save when realtime advanced the record version', () => {
    expect(() =>
      assertCrmEditCurrent({ id: 7, lockVersion: 1 }, { id: 7, lockVersion: 2 })
    ).toThrow('STALE_RECORD');
  });

  it('rebases only the lock version and preserves the original baseline', () => {
    const snapshot = {
      deal: { id: 7, lockVersion: 1, ownerId: 4, title: 'Original' },
      payload: { owner_id: 4, title: 'Original' },
    };

    expect(
      rebaseSnapshotLockVersion(snapshot, 'deal', {
        id: 7,
        lockVersion: 3,
        ownerId: 9,
        title: 'Changed elsewhere',
      })
    ).toEqual({
      deal: { id: 7, lockVersion: 3, ownerId: 4, title: 'Original' },
      payload: { owner_id: 4, title: 'Original' },
    });
  });

  it('recognizes an Axios stale response instead of the transport code', () => {
    expect(
      isStaleCrmError({
        code: 'ERR_BAD_REQUEST',
        message: 'Request failed with status code 409',
        response: {
          status: 409,
          data: { code: 'STALE_RECORD', error: 'Stale object' },
        },
      })
    ).toBe(true);
  });
});
