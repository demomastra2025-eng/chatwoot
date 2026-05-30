import { getSidebarChildDisplayLabel } from './sidebarDisplayLabels';

describe('sidebarDisplayLabels', () => {
  it('keeps the normal label while the parent section is expanded', () => {
    expect(
      getSidebarChildDisplayLabel(
        { label: 'All', collapsedLabel: 'All channels' },
        true
      )
    ).toBe('All');
  });

  it('uses the contextual label while the parent section is collapsed', () => {
    expect(
      getSidebarChildDisplayLabel(
        { label: 'All', collapsedLabel: 'All tags' },
        false
      )
    ).toBe('All tags');
  });

  it('falls back to the normal label when no contextual label exists', () => {
    expect(getSidebarChildDisplayLabel({ label: 'Open' }, false)).toBe('Open');
  });
});
