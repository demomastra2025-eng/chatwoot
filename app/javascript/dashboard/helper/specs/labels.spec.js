import {
  labelDisplayTitle,
  labelDisplayTitleWithoutMarker,
  labelMarkerColor,
  labelMarkerEmoji,
  labelMarkerType,
} from '../labels';

describe('labels helper', () => {
  describe('labelDisplayTitleWithoutMarker', () => {
    it('removes the leading marker emoji from the display title', () => {
      const label = {
        display_title: '🔥 Горячие',
        title: 'label_fire',
        marker_type: 'emoji',
        emoji: '🔥',
      };

      expect(labelDisplayTitleWithoutMarker(label)).toBe('Горячие');
    });

    it('keeps titles that do not start with the marker emoji', () => {
      const label = {
        display_title: 'VIP 🔥',
        title: 'vip',
        marker_type: 'emoji',
        emoji: '🔥',
      };

      expect(labelDisplayTitleWithoutMarker(label)).toBe('VIP 🔥');
    });
  });

  it('returns marker metadata with safe fallbacks', () => {
    const colorLabel = { color: '#ffcc00' };

    expect(labelDisplayTitle({ display_title: 'VIP', title: 'vip' })).toBe(
      'VIP'
    );
    expect(labelMarkerType({ marker_type: 'emoji', emoji: '⭐' })).toBe(
      'emoji'
    );
    expect(labelMarkerEmoji({ marker_type: 'emoji', emoji: '⭐' })).toBe('⭐');
    expect(labelMarkerType(colorLabel)).toBe('color');
    expect(labelMarkerColor(colorLabel)).toBe('#ffcc00');
    expect(labelMarkerColor({})).toBe('#1f93ff');
  });
});
