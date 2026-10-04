// Pure geometry helpers for DsChartFrame (kept separate so they are testable).

export const CHART_WIDTH = 720;
export const PAD_LEFT = 40;
export const PAD_RIGHT = 12;
export const PAD_TOP = 8;
export const AXIS_BAND = 22;
export const MAX_BAR_WIDTH = 14;
export const RAMP_STEPS = 5;

// Round an axis maximum up to a clean number whose half is clean too (the
// grid is drawn at 0, half and max), keeping the headroom small.
export const niceMax = value => {
  if (!value || value <= 0) return 1;
  const power = 10 ** Math.floor(Math.log10(value));
  const scaled = value / power;
  const step = [1, 1.5, 2, 3, 4, 5, 6, 8, 10].find(
    candidate => scaled <= candidate
  );
  return step * power;
};

export const xPosition = (index, count) => {
  const inner = CHART_WIDTH - PAD_LEFT - PAD_RIGHT;
  if (count <= 1) return PAD_LEFT + inner / 2;
  return PAD_LEFT + (inner * index) / (count - 1);
};

export const nearestIndex = (x, count) => {
  if (count <= 1) return 0;
  const inner = CHART_WIDTH - PAD_LEFT - PAD_RIGHT;
  const index = Math.round(((x - PAD_LEFT) / inner) * (count - 1));
  return Math.min(count - 1, Math.max(0, index));
};

// A line path that breaks at missing (null / undefined) values.
export const linePath = (values, toX, toY) => {
  let pen = 'M';
  return values
    .map((value, index) => {
      if (value === null || value === undefined) {
        pen = 'M';
        return '';
      }
      const segment = `${pen}${toX(index).toFixed(1)} ${toY(value).toFixed(1)}`;
      pen = 'L';
      return segment;
    })
    .filter(Boolean)
    .join(' ');
};

// Column with a rounded data end (top) and a square baseline.
export const columnPath = (x, y, width, height) => {
  if (height <= 0) return '';
  const radius = Math.min(4, width / 2, height);
  const right = x + width;
  const bottom = y + height;
  return [
    `M${x} ${bottom}`,
    `V${y + radius}`,
    `Q${x} ${y} ${x + radius} ${y}`,
    `H${right - radius}`,
    `Q${right} ${y} ${right} ${y + radius}`,
    `V${bottom}`,
    'Z',
  ].join(' ');
};

// Which x labels to print so they never collide: about six, always the last.
export const visibleTickIndexes = (count, maxTicks = 6) => {
  if (!count) return [];
  const step = Math.max(1, Math.ceil(count / maxTicks));
  const indexes = [];
  for (let index = 0; index < count; index += step) {
    if (count - 1 - index >= step / 2 || index === count - 1) {
      indexes.push(index);
    }
  }
  if (indexes[indexes.length - 1] !== count - 1) indexes.push(count - 1);
  return indexes;
};

// Ordinal ramp step (1 = strongest) for stage `index` of `count`: earlier
// stages get stronger steps, spread over the whole ramp. Past five stages
// neighbours may share a step; the labels and values still tell them apart.
export const rampStep = (index, count) => {
  if (count <= 1) return 1;
  return 1 + Math.round((index * (RAMP_STEPS - 1)) / (count - 1));
};
