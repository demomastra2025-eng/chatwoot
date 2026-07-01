<script>
const MINUTE_IN_MILLI_SECONDS = 60000;
const HOUR_IN_MILLI_SECONDS = MINUTE_IN_MILLI_SECONDS * 60;
const DAY_IN_MILLI_SECONDS = HOUR_IN_MILLI_SECONDS * 24;

import {
  dynamicTime,
  dateFormat,
  shortTimestamp,
} from 'shared/helpers/timeHelper';

export default {
  name: 'TimeAgo',
  props: {
    displayMode: {
      type: String,
      default: 'range',
      validator: value => ['range', 'compact_elapsed'].includes(value),
    },
    isAutoRefreshEnabled: {
      type: Boolean,
      default: true,
    },
    lastActivityTimestamp: {
      type: [String, Date, Number],
      default: '',
    },
    secondaryActivityTimestamp: {
      type: [String, Date, Number],
      default: '',
    },
    createdAtTimestamp: {
      type: [String, Date, Number],
      default: '',
    },
    conversationId: {
      type: [String, Number],
      default: '',
    },
    tooltipTextOverride: {
      type: String,
      default: '',
    },
    secondaryTooltipTextOverride: {
      type: String,
      default: '',
    },
  },
  data() {
    return {
      lastActivityAtTimeAgo: dynamicTime(this.lastActivityTimestamp),
      createdAtTimeAgo: dynamicTime(this.createdAtTimestamp),
      refreshTick: Date.now(),
      timer: null,
    };
  },
  computed: {
    isCompactElapsed() {
      return this.displayMode === 'compact_elapsed';
    },
    displayText() {
      if (!this.isCompactElapsed) {
        return `${this.createdAtTime} • ${this.lastActivityTime}`;
      }

      const currentTime = this.refreshTick;
      return this.secondaryActivityTimestamp
        ? this.compactElapsedPair(
            this.lastActivityTimestamp,
            this.secondaryActivityTimestamp,
            currentTime
          )
        : this.compactElapsedTime(this.lastActivityTimestamp, currentTime);
    },
    rootClass() {
      return this.isCompactElapsed
        ? 'leading-[10px] text-[9px] tabular-nums text-center text-n-slate-10 hover:text-n-slate-11'
        : 'ml-auto leading-4 text-xxs text-n-slate-10 hover:text-n-slate-11';
    },
    lastActivityTime() {
      return shortTimestamp(this.lastActivityTimestamp);
    },
    createdAtTime() {
      return shortTimestamp(this.createdAtTimestamp);
    },
    createdAt() {
      const createdTimeDiff = Date.now() - this.createdAtTimestamp * 1000;
      const isBeforeAMonth = createdTimeDiff > DAY_IN_MILLI_SECONDS * 30;
      return !isBeforeAMonth
        ? `${this.$t('CHAT_LIST.CHAT_TIME_STAMP.CREATED.LATEST')} ${
            this.createdAtTimeAgo
          }`
        : `${this.$t('CHAT_LIST.CHAT_TIME_STAMP.CREATED.OLDEST')} ${dateFormat(
            this.createdAtTimestamp
          )}`;
    },
    lastActivity() {
      const lastActivityTimeDiff =
        Date.now() - this.lastActivityTimestamp * 1000;
      const isNotActive = lastActivityTimeDiff > DAY_IN_MILLI_SECONDS * 30;
      return !isNotActive
        ? `${this.$t('CHAT_LIST.CHAT_TIME_STAMP.LAST_ACTIVITY.ACTIVE')} ${
            this.lastActivityAtTimeAgo
          }`
        : `${this.$t(
            'CHAT_LIST.CHAT_TIME_STAMP.LAST_ACTIVITY.NOT_ACTIVE'
          )} ${dateFormat(this.lastActivityTimestamp)}`;
    },
    tooltipText() {
      if (this.tooltipTextOverride || this.secondaryTooltipTextOverride) {
        const tooltipLines = [];
        if (
          this.tooltipTextOverride &&
          Number(this.lastActivityTimestamp) > 0
        ) {
          tooltipLines.push(
            `${this.tooltipTextOverride}: ${dateFormat(this.lastActivityTimestamp)}`
          );
        }
        if (
          this.secondaryTooltipTextOverride &&
          Number(this.secondaryActivityTimestamp) > 0
        ) {
          tooltipLines.push(
            `${this.secondaryTooltipTextOverride}: ${dateFormat(this.secondaryActivityTimestamp)}`
          );
        }
        return tooltipLines.join('\n');
      }

      return `${this.createdAt}
              ${this.lastActivity}`;
    },
  },
  watch: {
    lastActivityTimestamp() {
      this.lastActivityAtTimeAgo = dynamicTime(this.lastActivityTimestamp);
    },
    secondaryActivityTimestamp() {
      this.refreshTick = Date.now();
    },
    createdAtTimestamp() {
      this.createdAtTimeAgo = dynamicTime(this.createdAtTimestamp);
    },
    conversationId() {
      // Reset display values and timer when the row is recycled to a different conversation.
      this.lastActivityAtTimeAgo = dynamicTime(this.lastActivityTimestamp);
      this.createdAtTimeAgo = dynamicTime(this.createdAtTimestamp);
      this.refreshTick = Date.now();
      if (this.isAutoRefreshEnabled) {
        clearTimeout(this.timer);
        this.createTimer();
      }
    },
  },
  mounted() {
    if (this.isAutoRefreshEnabled) {
      this.createTimer();
    }
  },
  unmounted() {
    clearTimeout(this.timer);
  },
  methods: {
    createTimer() {
      this.timer = setTimeout(() => {
        this.lastActivityAtTimeAgo = dynamicTime(this.lastActivityTimestamp);
        this.createdAtTimeAgo = dynamicTime(this.createdAtTimestamp);
        this.refreshTick = Date.now();
        this.createTimer();
      }, this.refreshTime());
    },
    refreshTime() {
      const timestamps = [
        this.lastActivityTimestamp,
        this.secondaryActivityTimestamp,
      ]
        .map(Number)
        .filter(timestamp => timestamp > 0);
      const mostRecentTimestamp = Math.max(...timestamps);
      const timestampInMs =
        mostRecentTimestamp > 1e12
          ? mostRecentTimestamp
          : mostRecentTimestamp * 1000;
      const timeDiff = Date.now() - timestampInMs;
      if (timeDiff > DAY_IN_MILLI_SECONDS) {
        return DAY_IN_MILLI_SECONDS;
      }
      if (timeDiff > HOUR_IN_MILLI_SECONDS) {
        return HOUR_IN_MILLI_SECONDS;
      }

      return MINUTE_IN_MILLI_SECONDS;
    },
    compactElapsedTime(timestamp, currentTime = Date.now()) {
      const numericTimestamp = Number(timestamp);
      if (!numericTimestamp) return '';

      const timestampInMs =
        numericTimestamp > 1e12 ? numericTimestamp : numericTimestamp * 1000;
      const elapsedSeconds = Math.max(
        0,
        Math.floor((currentTime - timestampInMs) / 1000)
      );
      const days = Math.floor(elapsedSeconds / 86400);
      const hours = Math.floor((elapsedSeconds % 86400) / 3600);
      const minutes = Math.floor((elapsedSeconds % 3600) / 60);
      const seconds = elapsedSeconds % 60;

      if (days > 0) {
        return `${days}д-${hours}ч`;
      }
      if (hours > 0) {
        return `${hours}ч-${minutes}м`;
      }
      return `${minutes}м-${seconds}с`;
    },
    compactElapsedSingleUnit(timestamp, currentTime = Date.now()) {
      const numericTimestamp = Number(timestamp);
      if (!numericTimestamp) return '';

      const timestampInMs =
        numericTimestamp > 1e12 ? numericTimestamp : numericTimestamp * 1000;
      const elapsedSeconds = Math.max(
        0,
        Math.floor((currentTime - timestampInMs) / 1000)
      );
      const days = Math.floor(elapsedSeconds / 86400);
      const hours = Math.floor((elapsedSeconds % 86400) / 3600);
      const minutes = Math.floor((elapsedSeconds % 3600) / 60);
      const seconds = elapsedSeconds % 60;

      if (days > 0) return `${days}д`;
      if (hours > 0) return `${hours}ч`;
      if (minutes > 0) return `${minutes}м`;
      return `${seconds}с`;
    },
    compactElapsedPair(
      primaryTimestamp,
      secondaryTimestamp,
      currentTime = Date.now()
    ) {
      return [
        this.compactElapsedSingleUnit(primaryTimestamp, currentTime),
        this.compactElapsedSingleUnit(secondaryTimestamp, currentTime),
      ]
        .filter(Boolean)
        .join('-');
    },
  },
};
</script>

<template>
  <div
    v-tooltip.top="{
      content: tooltipText,
      delay: { show: 1000, hide: 0 },
    }"
    :class="rootClass"
  >
    <span>{{ displayText }}</span>
  </div>
</template>
