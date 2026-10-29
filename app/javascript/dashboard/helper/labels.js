export const SYSTEM_META_ADS_LABEL_NAMES = new Set(['meta_ads', 'meta ads']);

export const labelDisplayTitle = label => {
  if (typeof label === 'string') return label;
  return label?.display_title || label?.title || '';
};

export const isSystemMetaAdsLabel = label => {
  if (!label) return false;
  if (typeof label === 'string') {
    return SYSTEM_META_ADS_LABEL_NAMES.has(label.trim().toLowerCase());
  }
  const title = String(label?.title || '')
    .trim()
    .toLowerCase();
  const display = String(label?.display_title || label?.displayTitle || '')
    .trim()
    .toLowerCase();
  return (
    SYSTEM_META_ADS_LABEL_NAMES.has(title) ||
    SYSTEM_META_ADS_LABEL_NAMES.has(display)
  );
};

export const labelMarkerType = label => {
  if (label?.marker_type === 'emoji' && label?.emoji) {
    return 'emoji';
  }
  return 'color';
};

export const labelMarkerEmoji = label =>
  labelMarkerType(label) === 'emoji' ? label.emoji : '';

export const labelDisplayTitleWithoutMarker = label => {
  const title = labelDisplayTitle(label).trim();
  const emoji = labelMarkerEmoji(label);
  if (!emoji || !title.startsWith(emoji)) return title;

  return title.slice(emoji.length).trimStart();
};

export const labelMarkerColor = label => label?.color || '#1f93ff';

export const sortLabelsByDisplayTitle = labels =>
  [...(labels || [])].sort((a, b) =>
    labelDisplayTitle(a).localeCompare(labelDisplayTitle(b))
  );
