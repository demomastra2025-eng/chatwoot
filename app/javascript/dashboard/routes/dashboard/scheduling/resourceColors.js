const normalizeColor = color =>
  String(color || '')
    .trim()
    .toUpperCase();

export const getUnavailableResourceColors = (
  resources = [],
  palette = [],
  currentResourceId = null
) => {
  const availableColors = palette.filter(Boolean);
  if (!availableColors.length) return [];

  const paletteColors = new Set(availableColors.map(normalizeColor));
  const unavailableColors = new Set();

  resources.forEach(resource => {
    if (
      currentResourceId &&
      Number(resource?.id) === Number(currentResourceId)
    ) {
      return;
    }

    const normalizedColor = normalizeColor(resource?.color || resource);
    if (!paletteColors.has(normalizedColor)) {
      return;
    }

    unavailableColors.add(normalizedColor);
  });

  return [...unavailableColors];
};

export const pickResourceColor = (
  resources = [],
  palette = [],
  currentResourceId = null
) => {
  const availableColors = palette.filter(Boolean);
  if (!availableColors.length) return '';

  const unavailableColors = new Set(
    getUnavailableResourceColors(resources, palette, currentResourceId)
  );

  return (
    availableColors.find(
      color => !unavailableColors.has(normalizeColor(color))
    ) || availableColors[0]
  );
};
