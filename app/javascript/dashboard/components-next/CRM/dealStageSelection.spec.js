import {
  defaultStageForNewDeal,
  dealStageDisplayName,
} from './dealStageSelection';

describe('CRM deal stage selection', () => {
  it('uses the active Unsorted stage record and keeps its actual database id', () => {
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

    expect(defaultStageForNewDeal({ stages: [assigned, unsorted] })).toBe(
      unsorted
    );
    expect(defaultStageForNewDeal({ stages: [assigned, unsorted] }).id).toBe(
      104
    );
    expect(dealStageDisplayName(unsorted, key => key)).toBe(
      'CRM.SETTINGS.STAGES.SYSTEM.UNSORTED'
    );
  });

  it('falls back to an active default when Unsorted is inactive or absent', () => {
    const assigned = {
      id: 205,
      code: 'qualify',
      active: true,
      default: true,
      outcome: 'open',
    };

    expect(
      defaultStageForNewDeal({
        stages: [
          { id: 104, code: 'new', active: false },
          assigned,
        ],
      })
    ).toBe(assigned);
  });
});
