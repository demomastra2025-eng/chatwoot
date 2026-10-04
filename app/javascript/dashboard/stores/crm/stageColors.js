const normalizeColor = color =>
  String(color || '')
    .trim()
    .toUpperCase();

const LEGACY_STAGE_COLOR_MAP = {
  '#E11D48': '#FF8F93',
  '#DC2626': '#FEC8C8',
  '#EA580C': '#FCCF58',
  '#F97316': '#FFDB80',
  '#D97706': '#FFEAB1',
  '#CA8A04': '#FFF000',
  '#84CC16': '#DFFF82',
  '#65A30D': '#EAFFB0',
  '#16A34A': '#87F1C0',
  '#059669': '#87F1C0',
  '#0D9488': '#87F1C0',
  '#0891B2': '#D5EAFF',
  '#0284C7': '#9BCAFF',
  '#2563EB': '#C1E0FD',
  '#4F46E5': '#CBC9F8',
  '#7C3AED': '#CBC9F8',
  '#9333EA': '#F1BFFE',
  '#C026D3': '#EB94FF',
  '#DB2777': '#F9DEFF',
  '#BE123C': '#FFDBDB',
};

export const STAGE_STANDARD_COLORS = [
  '#FFFEB3',
  '#FEFD7F',
  '#FFF000',
  '#FFEAB1',
  '#FFDB80',
  '#FCCF58',
  '#FFDBDB',
  '#FEC8C8',
  '#FF8F93',
  '#D5EAFF',
  '#C1E0FD',
  '#9BCAFF',
  '#EAFFB0',
  '#DFFF82',
  '#87F1C0',
  '#F9DEFF',
  '#F1BFFE',
  '#CBC9F8',
  '#EB94FF',
  '#F2F3F5',
  '#E7E8EA',
];

export const DEFAULT_STAGE_COLOR = STAGE_STANDARD_COLORS[0] || '';

export const resolveStageDisplayColor = color => {
  const normalizedColor = normalizeColor(color);
  return (
    LEGACY_STAGE_COLOR_MAP[normalizedColor] ||
    normalizedColor ||
    DEFAULT_STAGE_COLOR
  );
};

const getUsedStandardColors = (
  stages = [],
  palette = [],
  currentStageId = null
) => {
  const availableColors = palette.filter(Boolean);
  if (!availableColors.length) return [];

  const paletteColors = new Set(availableColors.map(normalizeColor));
  const usedColors = new Set();

  stages.forEach(stage => {
    if (currentStageId && Number(stage?.id) === Number(currentStageId)) {
      return;
    }

    const normalizedColor = normalizeColor(
      resolveStageDisplayColor(stage?.color || stage)
    );
    if (!paletteColors.has(normalizedColor)) {
      return;
    }

    usedColors.add(normalizedColor);
  });

  return [...usedColors];
};

export const getUnavailableStageColors = () => [];

export const pickStageColor = (
  stages = [],
  palette = STAGE_STANDARD_COLORS,
  currentStageId = null
) => {
  const availableColors = palette.filter(Boolean);
  if (!availableColors.length) return '';

  const usedColors = new Set(
    getUsedStandardColors(stages, palette, currentStageId)
  );

  return (
    availableColors.find(color => !usedColors.has(normalizeColor(color))) ||
    DEFAULT_STAGE_COLOR
  );
};
