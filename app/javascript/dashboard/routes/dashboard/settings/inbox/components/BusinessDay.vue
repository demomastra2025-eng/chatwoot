<script>
import differenceInMinutes from 'date-fns/differenceInMinutes';
import {
  generateTimeSlots,
  parseBusinessHourTime,
} from '../helpers/businessHour';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import NextSelect from 'dashboard/components-next/select/Select.vue';

const timeSlots = generateTimeSlots(30);

const groupByPeriod = slots => [
  {
    label: '24h',
    options: slots.map(s => ({ value: s, label: s })),
  },
];

export default {
  components: {
    Icon,
    Checkbox,
    NextSelect,
  },
  props: {
    dayName: {
      type: String,
      required: true,
    },
    timeSlot: {
      type: Object,
      default: () => ({
        from: '',
        to: '',
      }),
    },
  },
  emits: ['update'],
  computed: {
    fromTimeSlots() {
      return groupByPeriod(timeSlots);
    },
    toTimeSlots() {
      return groupByPeriod(timeSlots.filter(slot => slot !== '00:00'));
    },
    isDayEnabled: {
      get() {
        return Boolean(this.timeSlot.from && this.timeSlot.to);
      },
      set(value) {
        const newSlot = value
          ? {
              ...this.timeSlot,
              from: timeSlots[0],
              to: timeSlots[16],
              valid: true,
              openAllDay: false,
            }
          : {
              ...this.timeSlot,
              from: '',
              to: '',
              valid: false,
              openAllDay: false,
            };
        this.$emit('update', newSlot);
      },
    },
    fromTime: {
      get() {
        return this.timeSlot.from;
      },
      set(value) {
        const fromDate = parseBusinessHourTime(value);
        const valid = differenceInMinutes(this.toDate, fromDate) / 60 > 0;
        this.$emit('update', {
          ...this.timeSlot,
          from: value,
          valid,
        });
      },
    },
    toTime: {
      get() {
        return this.timeSlot.to;
      },
      set(value) {
        const toDate = parseBusinessHourTime(value);
        if (value === '23:59') {
          this.$emit('update', {
            ...this.timeSlot,
            to: value,
            valid: true,
          });
        } else {
          const valid = differenceInMinutes(toDate, this.fromDate) / 60 > 0;
          this.$emit('update', {
            ...this.timeSlot,
            to: value,
            valid,
          });
        }
      },
    },
    fromDate() {
      return parseBusinessHourTime(this.fromTime);
    },
    toDate() {
      return parseBusinessHourTime(this.toTime);
    },
    totalHours() {
      if (this.timeSlot.openAllDay) return '24h';

      const totalMinutes = differenceInMinutes(this.toDate, this.fromDate);
      const [h, m] = [Math.floor(totalMinutes / 60), totalMinutes % 60];

      return [h && `${h}h`, m && `${m}m`].filter(Boolean).join(' ') || '0m';
    },
    hasError() {
      return !this.timeSlot.valid;
    },
    isOpenAllDay: {
      get() {
        return this.timeSlot.openAllDay;
      },
      set(value) {
        if (value) {
          this.$emit('update', {
            ...this.timeSlot,
            from: '00:00',
            to: '23:59',
            valid: true,
            openAllDay: value,
          });
        } else {
          this.$emit('update', {
            ...this.timeSlot,
            from: '09:00',
            to: '17:00',
            valid: true,
            openAllDay: value,
          });
        }
      },
    },
  },
};
</script>

<template>
  <tr>
    <td class="ltr:pl-4 ltr:pr-3 rtl:pl-3 rtl:pr-4">
      <div class="flex items-center gap-2 min-h-16">
        <Checkbox
          v-model="isDayEnabled"
          name="enable-day"
          class="!m-0 shrink-0"
          :title="$t('INBOX_MGMT.BUSINESS_HOURS.DAY.ENABLE')"
        />
        <span class="text-body-main text-n-slate-12 font-medium">
          {{ dayName }}
        </span>
      </div>
    </td>
    <td class="py-3 ltr:pr-3 rtl:pl-3">
      <div v-if="isDayEnabled" class="flex flex-col gap-1.5">
        <div class="flex items-center gap-4">
          <div class="flex items-center gap-2">
            <Checkbox
              v-model="isOpenAllDay"
              name="enable-open-all-day"
              class="!m-0 shrink-0"
              :title="$t('INBOX_MGMT.BUSINESS_HOURS.ALL_DAY')"
            />
            <span class="text-body-main text-n-slate-12">{{
              $t('INBOX_MGMT.BUSINESS_HOURS.ALL_DAY')
            }}</span>
          </div>
          <NextSelect
            v-model="fromTime"
            :groups="fromTimeSlots"
            :placeholder="$t('INBOX_MGMT.BUSINESS_HOURS.DAY.CHOOSE')"
            :disabled="isOpenAllDay"
          />
          <div class="flex items-center">
            <Icon icon="i-lucide-minus size-4" />
          </div>
          <NextSelect
            v-model="toTime"
            :groups="toTimeSlots"
            :placeholder="$t('INBOX_MGMT.BUSINESS_HOURS.DAY.CHOOSE')"
            :disabled="isOpenAllDay"
          />
        </div>
        <span v-if="hasError" class="error text-label-small text-n-ruby-9">
          {{ $t('INBOX_MGMT.BUSINESS_HOURS.DAY.VALIDATION_ERROR') }}
        </span>
      </div>
      <span v-else class="text-body-main text-n-slate-11">
        {{ $t('INBOX_MGMT.BUSINESS_HOURS.DAY.UNAVAILABLE') }}
      </span>
    </td>
    <td class="py-3 ltr:pr-3 rtl:pl-3">
      <span
        v-if="isDayEnabled && !hasError"
        class="label bg-n-blue-3 text-n-blue-11 text-label-small inline-block px-2 py-1 rounded-lg cursor-default whitespace-nowrap"
      >
        {{ totalHours }}
      </span>
    </td>
  </tr>
</template>
