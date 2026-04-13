<script setup>
import { computed } from 'vue';
import { Line } from 'vue-chartjs';
import {
  Chart as ChartJS,
  Title,
  Tooltip,
  Legend,
  LineElement,
  PointElement,
  CategoryScale,
  LinearScale,
  Filler,
} from 'chart.js';

const props = defineProps({
  collection: {
    type: Object,
    default: () => ({}),
  },
  chartOptions: {
    type: Object,
    default: () => ({}),
  },
});

ChartJS.register(
  Title,
  Tooltip,
  Legend,
  LineElement,
  PointElement,
  CategoryScale,
  LinearScale,
  Filler
);

const fontFamily =
  'Geist,-apple-system,system-ui,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif';

const defaultChartOptions = {
  responsive: true,
  maintainAspectRatio: false,
  animation: {
    duration: 0,
  },
  plugins: {
    legend: {
      display: false,
      labels: {
        font: {
          family: fontFamily,
        },
      },
    },
  },
  elements: {
    point: {
      radius: 2,
      hoverRadius: 4,
    },
    line: {
      tension: 0.35,
      borderWidth: 2,
    },
  },
  scales: {
    x: {
      ticks: {
        font: {
          family: fontFamily,
        },
      },
      grid: {
        display: false,
      },
    },
    y: {
      ticks: {
        font: {
          family: fontFamily,
        },
      },
      grid: {
        drawOnChartArea: false,
      },
    },
  },
};

const options = computed(() => ({
  ...defaultChartOptions,
  ...props.chartOptions,
}));
</script>

<template>
  <Line :data="collection" :options="options" />
</template>
