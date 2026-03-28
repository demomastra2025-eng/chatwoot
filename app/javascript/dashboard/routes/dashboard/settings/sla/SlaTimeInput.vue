<script>
import validations from './timeInputValidations';
import { useVuelidate } from '@vuelidate/core';
import WootSelect from 'dashboard/components-next/select/Select.vue';
import NextInput from 'dashboard/components-next/input/Input.vue';

export default {
  components: {
    WootSelect,
    NextInput,
  },
  props: {
    threshold: {
      type: Number,
      default: null,
    },
    thresholdUnit: {
      type: String,
      default: 'Minutes',
    },
    label: {
      type: String,
      default: '',
    },
    placeholder: {
      type: String,
      default: '',
    },
  },
  emits: ['unit', 'isInValid', 'updateThreshold'],
  setup() {
    return { v$: useVuelidate() };
  },
  data() {
    return {
      thresholdTime: this.threshold || '',
      thresholdUnitValue: this.thresholdUnit,
      options: [
        { value: 'Minutes', label: 'SLA.FORM.UNITS.MINUTES' },
        { value: 'Hours', label: 'SLA.FORM.UNITS.HOURS' },
        { value: 'Days', label: 'SLA.FORM.UNITS.DAYS' },
      ],
    };
  },
  validations,
  computed: {
    translatedOptions() {
      return [
        {
          ...this.options[0],
          translatedLabel: this.$t('SLA.FORM.UNITS.MINUTES'),
        },
        {
          ...this.options[1],
          translatedLabel: this.$t('SLA.FORM.UNITS.HOURS'),
        },
        {
          ...this.options[2],
          translatedLabel: this.$t('SLA.FORM.UNITS.DAYS'),
        },
      ];
    },
    thresholdTimeErrorMessage() {
      let errorMessage = '';
      if (this.v$.thresholdTime.$error) {
        if (!this.v$.thresholdTime.decimal || !this.v$.thresholdTime.minValue) {
          errorMessage = this.$t(
            'SLA.FORM.THRESHOLD_TIME.INVALID_FORMAT_ERROR'
          );
        }
      }
      return errorMessage;
    },
  },
  watch: {
    threshold: {
      immediate: true,
      handler(value) {
        if (!Number.isNaN(value)) {
          this.thresholdTime = value;
        }
      },
    },
    thresholdUnit: {
      immediate: true,
      handler(value) {
        this.thresholdUnitValue = value;
      },
    },
  },
  methods: {
    onThresholdUnitChange() {
      this.$emit('unit', this.thresholdUnitValue);
    },
    onThresholdTimeChange() {
      this.v$.thresholdTime.$touch();
      const isInvalid = this.v$.thresholdTime.$invalid;
      this.$emit('isInValid', isInvalid);
      this.$emit(
        'updateThreshold',
        this.thresholdTime ? Number(this.thresholdTime) : null
      );
    },
  },
};
</script>

<template>
  <div class="flex min-w-0 flex-col gap-2">
    <label class="text-sm font-medium leading-none text-n-slate-12">
      {{ label }}
    </label>
    <div class="grid w-full min-w-0 grid-cols-[minmax(0,1fr)_5.25rem] gap-2">
      <NextInput
        v-model="thresholdTime"
        type="number"
        class="min-w-0 w-full"
        :placeholder="placeholder"
        :message="thresholdTimeErrorMessage"
        :message-type="thresholdTimeErrorMessage ? 'error' : 'info'"
        @update:model-value="onThresholdTimeChange"
        @blur="onThresholdTimeChange"
      />
      <WootSelect
        v-model="thresholdUnitValue"
        class="h-10 min-w-[5.25rem] rounded-xl border-0 px-3 py-0 pr-7 text-sm font-medium leading-none hover:cursor-pointer"
        @change="onThresholdUnitChange"
      >
        <option
          v-for="(option, index) in translatedOptions"
          :key="index"
          :value="option.value"
        >
          {{ option.translatedLabel }}
        </option>
      </WootSelect>
    </div>
  </div>
</template>
