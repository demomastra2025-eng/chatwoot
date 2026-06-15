export const labelDisplayTitle = label => {
  if (typeof label === 'string') return label;
  return label?.display_title || label?.title || '';
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
