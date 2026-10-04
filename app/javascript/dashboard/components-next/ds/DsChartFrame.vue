<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import DsCard from './DsCard.vue';
import DsState from './DsState.vue';
import DsTable from './DsTable.vue';
import {
  AXIS_BAND,
  CHART_WIDTH,
  MAX_BAR_WIDTH,
  PAD_LEFT,
  PAD_RIGHT,
  PAD_TOP,
  columnPath,
  linePath,
  nearestIndex,
  niceMax,
  rampStep,
  visibleTickIndexes,
  xPosition,
} from './chartGeometry';

// Chart card following the dataviz rules of design variant A:
// - kind "line": up to two series on ONE axis (accent line 2px, comparison
//   series in muted ink), three hairline grid levels, crosshair tooltip.
//   A metric on a different scale goes to `secondary`: a separate small
//   column panel under the chart, never a second axis.
// - kind "bars": one series as horizontal bars (funnel / stages) in one
//   accent hue; earlier stages use the stronger step of the ramp.
// Every chart has a legend for two or more series and a table view.
const props = defineProps({
  title: { type: String, default: '' },
  subtitle: { type: String, default: '' },
  kind: {
    type: String,
    default: 'line',
    validator: value => ['line', 'bars'].includes(value),
  },
  labels: { type: Array, default: () => [] },
  series: {
    type: Array,
    default: () => [],
    validator: series =>
      series.length <= 2 &&
      series.every(
        item => item.key && item.label && Array.isArray(item.values)
      ),
  },
  secondary: { type: Object, default: null },
  categoryLabel: { type: String, default: '' },
  formatValue: { type: Function, default: null },
  height: { type: Number, default: 170 },
  loading: { type: Boolean, default: false },
  error: { type: Boolean, default: false },
});

const emit = defineEmits(['hover', 'retry']);

const { t, locale } = useI18n();

const showTable = ref(false);
const hoverIndex = ref(null);
const barTooltipTop = ref(0);

const SERIES_STROKES = ['stroke-n-brand', 'stroke-n-slate-9'];
const SERIES_SWATCHES = ['bg-n-brand', 'bg-n-slate-9'];
const RAMP_CLASSES = [
  'bg-n-chart-1',
  'bg-n-chart-2',
  'bg-n-chart-3',
  'bg-n-chart-4',
  'bg-n-chart-5',
];

const numberFormat = computed(() => new Intl.NumberFormat(locale.value));
const format = value => {
  if (value === null || value === undefined) return '—';
  return props.formatValue
    ? props.formatValue(value)
    : numberFormat.value.format(value);
};

const isLine = computed(() => props.kind === 'line');
const count = computed(() => props.labels.length);
const hasData = computed(
  () =>
    count.value > 0 &&
    props.series.some(item =>
      item.values.some(value => value !== null && value !== undefined)
    )
);

const legendItems = computed(() => {
  if (!isLine.value) return [];
  const items = props.series.map((item, index) => ({
    key: item.key,
    label: item.label,
    swatch: SERIES_SWATCHES[index],
    mark: 'line',
  }));
  if (props.secondary) {
    items.push({
      key: props.secondary.key,
      label: props.secondary.label,
      swatch: 'bg-n-slate-11',
      mark: 'bar',
    });
  }
  return items.length >= 2 ? items : [];
});

// ---- line chart geometry -------------------------------------------------
const plotBottom = computed(() => PAD_TOP + props.height);
const mainHeight = computed(
  () => plotBottom.value + (props.secondary ? 6 : AXIS_BAND)
);
const yMax = computed(() =>
  niceMax(
    Math.max(
      0,
      ...props.series.flatMap(item =>
        item.values.filter(value => typeof value === 'number')
      )
    )
  )
);
const toX = index => xPosition(index, count.value);
const toY = value => PAD_TOP + props.height * (1 - value / yMax.value);
const gridLines = computed(() =>
  [0, 0.5, 1].map(level => ({
    y: toY(yMax.value * level),
    label: format(yMax.value * level),
  }))
);
const paths = computed(() =>
  props.series.map((item, index) => ({
    key: item.key,
    d: linePath(item.values, toX, toY),
    stroke: SERIES_STROKES[index],
  }))
);
const endPoint = computed(() => {
  const values = props.series[0]?.values || [];
  for (let index = values.length - 1; index >= 0; index -= 1) {
    if (typeof values[index] === 'number') {
      return { x: toX(index), y: toY(values[index]) };
    }
  }
  return null;
});
const ticks = computed(() =>
  visibleTickIndexes(count.value).map(index => ({
    index,
    x: toX(index),
    label: props.labels[index],
  }))
);

const SECONDARY_HEIGHT = 56;
const secondaryMax = computed(() =>
  niceMax(
    Math.max(
      0,
      ...(props.secondary?.values || []).filter(
        value => typeof value === 'number'
      )
    )
  )
);
const secondaryBottom = PAD_TOP + SECONDARY_HEIGHT;
const columnWidth = computed(() =>
  Math.min(
    MAX_BAR_WIDTH,
    ((CHART_WIDTH - PAD_LEFT - PAD_RIGHT) / Math.max(1, count.value)) * 0.5
  )
);
const columns = computed(() =>
  (props.secondary?.values || []).map((value, index) => {
    const height =
      typeof value === 'number'
        ? (SECONDARY_HEIGHT * value) / secondaryMax.value
        : 0;
    return {
      index,
      d: columnPath(
        toX(index) - columnWidth.value / 2,
        secondaryBottom - height,
        columnWidth.value,
        height
      ),
    };
  })
);

// ---- hover / keyboard ------------------------------------------------------
const setHover = index => {
  if (hoverIndex.value === index) return;
  hoverIndex.value = index;
  emit('hover', index);
};

const onPointerMove = event => {
  const box = event.currentTarget.getBoundingClientRect();
  if (!box.width) return;
  const x = ((event.clientX - box.left) / box.width) * CHART_WIDTH;
  setHover(nearestIndex(x, count.value));
};

const onKeydown = event => {
  const step = { ArrowRight: 1, ArrowLeft: -1 }[event.key];
  if (!step || !count.value) return;
  event.preventDefault();
  const current = hoverIndex.value ?? count.value - 1;
  setHover(Math.min(count.value - 1, Math.max(0, current + step)));
};

const tooltipRows = computed(() => {
  const index = hoverIndex.value;
  if (index === null) return [];
  if (!isLine.value) {
    const first = props.series[0]?.values[0];
    const value = props.series[0]?.values[index];
    const rows = [
      {
        key: props.series[0].key,
        label: props.series[0].label,
        value: format(value),
        swatch: RAMP_CLASSES[rampStep(index, count.value) - 1],
        mark: 'bar',
      },
    ];
    if (index > 0 && first) {
      rows.push({
        key: 'share',
        label: t('DESIGN_SYSTEM.CHART.SHARE'),
        value: `${Math.round((value / first) * 100)}%`,
        swatch: '',
        mark: 'none',
      });
    }
    return rows;
  }
  const rows = props.series.map((item, seriesIndex) => ({
    key: item.key,
    label: item.label,
    value: format(item.values[index]),
    swatch: SERIES_SWATCHES[seriesIndex],
    mark: 'line',
  }));
  if (props.secondary) {
    rows.push({
      key: props.secondary.key,
      label: props.secondary.label,
      value: format(props.secondary.values[index]),
      swatch: 'bg-n-slate-11',
      mark: 'bar',
    });
  }
  return rows;
});

const tooltipStyle = computed(() => {
  if (!isLine.value) return { top: `${barTooltipTop.value}px`, right: '0px' };
  const percent = (toX(hoverIndex.value) / CHART_WIDTH) * 100;
  return percent > 60
    ? { top: '8px', right: `calc(${100 - percent}% + 12px)` }
    : { top: '8px', left: `calc(${percent}% + 12px)` };
});

// ---- bars ------------------------------------------------------------------
const bars = computed(() => {
  const values = props.series[0]?.values || [];
  const max = Math.max(0, ...values.filter(value => typeof value === 'number'));
  const first = values[0];
  return values.map((value, index) => ({
    index,
    label: props.labels[index],
    value: format(value),
    width: max ? `${(Math.max(0, value || 0) / max) * 100}%` : '0%',
    share: first ? `${Math.round(((value || 0) / first) * 100)}%` : '',
    fill: RAMP_CLASSES[rampStep(index, values.length) - 1],
  }));
});

const onBarEnter = (event, index) => {
  barTooltipTop.value =
    event.currentTarget.offsetTop + event.currentTarget.offsetHeight + 4;
  setHover(index);
};

// ---- table view ------------------------------------------------------------
const tableColumns = computed(() => {
  const category = {
    key: 'category',
    label:
      props.categoryLabel ||
      (isLine.value
        ? t('DESIGN_SYSTEM.CHART.CATEGORY')
        : t('DESIGN_SYSTEM.CHART.STAGE')),
  };
  if (!isLine.value) {
    return [
      category,
      { key: 'value', label: props.series[0]?.label || '', numeric: true },
      { key: 'share', label: t('DESIGN_SYSTEM.CHART.SHARE'), numeric: true },
    ];
  }
  const columnsList = props.series.map(item => ({
    key: item.key,
    label: item.label,
    numeric: true,
  }));
  if (props.secondary) {
    columnsList.push({
      key: props.secondary.key,
      label: props.secondary.label,
      numeric: true,
    });
  }
  return [category, ...columnsList];
});

const tableRows = computed(() =>
  props.labels.map((label, index) => {
    if (!isLine.value) {
      return {
        id: index,
        category: label,
        value: bars.value[index]?.value,
        share: bars.value[index]?.share,
      };
    }
    const row = { id: index, category: label };
    props.series.forEach(item => {
      row[item.key] = format(item.values[index]);
    });
    if (props.secondary) {
      row[props.secondary.key] = format(props.secondary.values[index]);
    }
    return row;
  })
);
</script>

<template>
  <DsCard :title="title" :subtitle="subtitle" as="figure" class="m-0">
    <template #actions>
      <ul
        v-if="legendItems.length && !showTable"
        class="reset-base m-0 flex list-none flex-wrap gap-x-3.5 gap-y-1 p-0"
        :aria-label="t('DESIGN_SYSTEM.CHART.LEGEND')"
        data-test-id="ds-chart-legend"
      >
        <li
          v-for="item in legendItems"
          :key="item.key"
          class="inline-flex items-center gap-1.5 text-ds-caption text-n-slate-11"
        >
          <span
            class="inline-block flex-shrink-0"
            :class="[
              item.swatch,
              item.mark === 'line'
                ? 'h-0.5 w-3.5 rounded-full'
                : 'size-2 rounded-sm',
            ]"
            aria-hidden="true"
          />
          {{ item.label }}
        </li>
      </ul>
      <button
        v-if="hasData && !error"
        type="button"
        class="m-0 rounded-ds-control bg-transparent px-1.5 py-0.5 text-ds-caption text-n-slate-11 hover:bg-n-slate-3 hover:text-n-slate-12 focus-visible:outline focus-visible:outline-2 focus-visible:outline-n-brand"
        :aria-pressed="showTable"
        data-test-id="ds-chart-table-toggle"
        @click="showTable = !showTable"
      >
        {{
          showTable
            ? t('DESIGN_SYSTEM.CHART.SHOW_CHART')
            : t('DESIGN_SYSTEM.CHART.SHOW_TABLE')
        }}
      </button>
    </template>

    <DsState v-if="error" state="error" compact @retry="emit('retry')" />
    <DsState v-else-if="!hasData && loading" state="loading" compact />
    <DsState v-else-if="!hasData" state="empty" compact />

    <div
      v-else
      class="relative transition-opacity duration-200"
      :class="{ 'opacity-60': loading }"
      :aria-busy="loading || undefined"
    >
      <div v-if="showTable" class="-mx-5">
        <DsTable
          :columns="tableColumns"
          :rows="tableRows"
          :caption="title"
          data-test-id="ds-chart-table"
        />
      </div>

      <div
        v-else-if="isLine"
        class="relative outline-none focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-n-brand"
        tabindex="0"
        role="group"
        :aria-label="title || undefined"
        @keydown="onKeydown"
        @focus="setHover(count - 1)"
        @blur="setHover(null)"
      >
        <svg
          :viewBox="`0 0 ${CHART_WIDTH} ${mainHeight}`"
          class="block h-auto w-full overflow-visible"
          aria-hidden="true"
          data-test-id="ds-chart-main"
        >
          <g data-test-id="ds-chart-grid">
            <g v-for="line in gridLines" :key="line.y">
              <line
                :x1="PAD_LEFT"
                :x2="CHART_WIDTH - PAD_RIGHT"
                :y1="line.y"
                :y2="line.y"
                class="stroke-n-weak"
                stroke-width="1"
                shape-rendering="crispEdges"
              />
              <text
                :x="PAD_LEFT - 8"
                :y="line.y + 4"
                text-anchor="end"
                class="fill-n-slate-11 text-[12px] tabular-nums"
              >
                {{ line.label }}
              </text>
            </g>
          </g>
          <line
            v-if="hoverIndex !== null"
            :x1="toX(hoverIndex)"
            :x2="toX(hoverIndex)"
            :y1="PAD_TOP"
            :y2="plotBottom"
            class="stroke-n-slate-9"
            stroke-width="1"
            shape-rendering="crispEdges"
          />
          <path
            v-for="(path, index) in paths"
            :key="path.key"
            :d="path.d"
            fill="none"
            :class="path.stroke"
            stroke-width="2"
            stroke-linejoin="round"
            stroke-linecap="round"
            :data-test-id="`ds-chart-line-${index}`"
          />
          <circle
            v-if="endPoint"
            :cx="endPoint.x"
            :cy="endPoint.y"
            r="4"
            class="fill-n-brand stroke-n-solid-2"
            stroke-width="2"
          />
          <template v-if="!secondary">
            <text
              v-for="tick in ticks"
              :key="tick.index"
              :x="tick.x"
              :y="mainHeight - 4"
              text-anchor="middle"
              class="fill-n-slate-11 text-[12px]"
            >
              {{ tick.label }}
            </text>
          </template>
          <rect
            :x="PAD_LEFT"
            y="0"
            :width="CHART_WIDTH - PAD_LEFT - PAD_RIGHT"
            :height="mainHeight"
            class="fill-transparent"
            @pointermove="onPointerMove"
            @pointerleave="setHover(null)"
          />
        </svg>

        <div v-if="secondary" class="mt-3" data-test-id="ds-chart-secondary">
          <div class="text-ds-caption text-n-slate-11">
            {{ secondary.label }}
          </div>
          <svg
            :viewBox="`0 0 ${CHART_WIDTH} ${secondaryBottom + AXIS_BAND}`"
            class="block h-auto w-full overflow-visible"
            aria-hidden="true"
          >
            <text
              :x="PAD_LEFT - 8"
              :y="PAD_TOP + 4"
              text-anchor="end"
              class="fill-n-slate-11 text-[12px] tabular-nums"
            >
              {{ format(secondaryMax) }}
            </text>
            <line
              :x1="PAD_LEFT"
              :x2="CHART_WIDTH - PAD_RIGHT"
              :y1="secondaryBottom"
              :y2="secondaryBottom"
              class="stroke-n-weak"
              stroke-width="1"
              shape-rendering="crispEdges"
            />
            <line
              v-if="hoverIndex !== null"
              :x1="toX(hoverIndex)"
              :x2="toX(hoverIndex)"
              :y1="PAD_TOP"
              :y2="secondaryBottom"
              class="stroke-n-slate-9"
              stroke-width="1"
              shape-rendering="crispEdges"
            />
            <path
              v-for="column in columns"
              :key="column.index"
              :d="column.d"
              :class="
                hoverIndex === column.index
                  ? 'fill-n-slate-12'
                  : 'fill-n-slate-11'
              "
            />
            <text
              v-for="tick in ticks"
              :key="tick.index"
              :x="tick.x"
              :y="secondaryBottom + AXIS_BAND - 4"
              text-anchor="middle"
              class="fill-n-slate-11 text-[12px]"
            >
              {{ tick.label }}
            </text>
            <rect
              :x="PAD_LEFT"
              y="0"
              :width="CHART_WIDTH - PAD_LEFT - PAD_RIGHT"
              :height="secondaryBottom + AXIS_BAND"
              class="fill-transparent"
              @pointermove="onPointerMove"
              @pointerleave="setHover(null)"
            />
          </svg>
        </div>
      </div>

      <div v-else class="relative grid gap-[11px]" data-test-id="ds-chart-bars">
        <div
          v-for="bar in bars"
          :key="bar.index"
          class="grid grid-cols-[minmax(0,9rem)_minmax(0,1fr)_auto] items-center gap-3 rounded-sm outline-none focus-visible:outline focus-visible:outline-2 focus-visible:outline-n-brand"
          tabindex="0"
          @pointerenter="onBarEnter($event, bar.index)"
          @pointerleave="setHover(null)"
          @focus="onBarEnter($event, bar.index)"
          @blur="setHover(null)"
        >
          <span class="truncate text-sm text-n-slate-12">{{ bar.label }}</span>
          <span class="block h-2.5">
            <span
              class="block h-full rounded-e transition-opacity"
              :class="[
                bar.fill,
                {
                  'opacity-70': hoverIndex !== null && hoverIndex !== bar.index,
                },
              ]"
              :style="{ width: bar.width }"
              data-test-id="ds-chart-bar"
            />
          </span>
          <span
            class="whitespace-nowrap text-end text-sm font-medium tabular-nums text-n-slate-12"
          >
            {{ bar.value }}
            <span class="text-xs font-normal text-n-slate-11">
              {{ `· ${bar.share}` }}
            </span>
          </span>
        </div>
      </div>

      <div
        v-if="hoverIndex !== null && !showTable"
        class="pointer-events-none absolute z-10 min-w-[140px] rounded-ds-control border border-solid border-n-weak bg-n-solid-2 px-2.5 py-2 text-ds-caption"
        :style="tooltipStyle"
        role="status"
        aria-live="polite"
        data-test-id="ds-chart-tooltip"
      >
        <slot
          name="tooltip"
          :index="hoverIndex"
          :label="labels[hoverIndex]"
          :rows="tooltipRows"
        >
          <div class="mb-1 font-semibold text-n-slate-12">
            {{ labels[hoverIndex] }}
          </div>
          <div
            v-for="row in tooltipRows"
            :key="row.key"
            class="flex items-center gap-2 leading-5"
          >
            <span
              v-if="row.mark !== 'none'"
              class="inline-block flex-shrink-0"
              :class="[
                row.swatch,
                row.mark === 'line'
                  ? 'h-0.5 w-2.5 rounded-full'
                  : 'size-2 rounded-sm',
              ]"
              aria-hidden="true"
            />
            <span class="text-n-slate-11">{{ row.label }}</span>
            <span class="font-semibold tabular-nums text-n-slate-12 ms-auto">
              {{ row.value }}
            </span>
          </div>
        </slot>
      </div>
    </div>
  </DsCard>
</template>
