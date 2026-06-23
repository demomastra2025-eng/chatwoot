const normalizeColor = color =>
  String(color || '')
    .trim()
    .toUpperCase();

export const STAGE_STANDARD_COLORS = [
  '#E11D48',
  '#DC2626',
  '#EA580C',
  '#F97316',
  '#D97706',
  '#CA8A04',
  '#84CC16',
  '#65A30D',
  '#16A34A',
  '#059669',
  '#0D9488',
  '#0891B2',
  '#0284C7',
  '#2563EB',
  '#4F46E5',
  '#7C3AED',
  '#9333EA',
  '#C026D3',
  '#DB2777',
  '#BE123C',
];

export const DEFAULT_STAGE_COLOR = STAGE_STANDARD_COLORS[0] || '';

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

    const normalizedColor = normalizeColor(stage?.color || stage);
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
