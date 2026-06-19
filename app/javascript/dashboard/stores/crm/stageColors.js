const normalizeColor = color =>
  String(color || '')
    .trim()
    .toUpperCase();

export const STAGE_STANDARD_COLORS = [
  '#F0F0F3',
  '#E8E8EC',
  '#0EA5E9',
  '#3B82F6',
  '#6366F1',
  '#8B5CF6',
  '#A855F7',
  '#EC4899',
  '#F97316',
  '#EAB308',
  '#22C55E',
  '#14B8A6',
];

export const DEFAULT_STAGE_COLOR =
  STAGE_STANDARD_COLORS.find(color => color === '#F0F0F3') ||
  STAGE_STANDARD_COLORS.find(color => color === '#E8E8EC') ||
  STAGE_STANDARD_COLORS[0] ||
  '';

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
