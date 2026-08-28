import { describe, expect, it } from 'vitest';
import { resolveBulkSelectionPayload } from '../bulkSelection';

describe('resolveBulkSelectionPayload', () => {
  it('uses applied filters before a saved folder query', () => {
    const appliedFilterPayload = [{ attribute_key: 'status' }];

    expect(
      resolveBulkSelectionPayload({
        appliedFilterPayload,
        activeFolderQuery: { payload: [{ attribute_key: 'team_id' }] },
      })
    ).toEqual(appliedFilterPayload);
  });

  it('uses the active saved-folder payload without applied filters', () => {
    const folderPayload = [{ attribute_key: 'team_id' }];

    expect(
      resolveBulkSelectionPayload({
        activeFolderQuery: { payload: folderPayload },
      })
    ).toEqual(folderPayload);
  });

  it('returns an empty payload when neither filter source is active', () => {
    expect(resolveBulkSelectionPayload({})).toEqual([]);
  });
});
