import {
  defaultStageForManualDeal,
  dealStageDisplayName,
} from './dealStageSelection';

describe('CRM deal stage selection', () => {
  it('keeps the configured default ahead of Unsorted for manual deal creation', () => {
    const unsorted = {
      id: 104,
      code: 'new',
      name: 'New',
      active: true,
    };
    const assigned = {
      id: 205,
      code: 'qualify',
      name: 'Qualified',
      active: true,
      default: true,
      outcome: 'open',
    };

    expect(defaultStageForManualDeal({ stages: [unsorted, assigned] })).toBe(
      assigned
    );
    expect(dealStageDisplayName(unsorted, key => key)).toBe(
      'CRM.SETTINGS.STAGES.SYSTEM.UNSORTED'
    );
  });

  it('falls back to the first active open stage when no default is configured', () => {
    const qualified = {
      id: 205,
      code: 'qualify',
      active: true,
      outcome: 'open',
    };

    expect(
      defaultStageForManualDeal({
        stages: [
          { id: 104, code: 'new', active: false }, qualified,
        ],
      })
    ).toBe(qualified);
  });
});
