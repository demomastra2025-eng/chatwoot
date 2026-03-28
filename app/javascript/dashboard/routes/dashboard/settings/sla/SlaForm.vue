<script>
import { mapGetters } from 'vuex';
import { convertSecondsToTimeUnit } from '@chatwoot/utils';
import validations from './validations';
import SlaTimeInput from './SlaTimeInput.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import { useVuelidate } from '@vuelidate/core';
import ToggleSwitch from 'dashboard/components-next/switch/Switch.vue';
import NextInput from 'dashboard/components-next/input/Input.vue';

export default {
  components: {
    SlaTimeInput,
    NextButton,
    ToggleSwitch,
    NextInput,
  },
  props: {
    selectedResponse: {
      type: Object,
      default: () => ({}),
    },
    submitLabel: {
      type: String,
      required: true,
    },
  },
  emits: ['close', 'submitSla'],
  setup() {
    return { v$: useVuelidate() };
  },
  data() {
    return {
      name: '',
      description: '',
      isSlaTimeInputsInvalid: false,
      slaTimeInputsValidation: {},
      slaTimeInputs: [
        {
          threshold: null,
          unit: 'Minutes',
          label: 'SLA.FORM.FIRST_RESPONSE_TIME.LABEL',
          placeholder: 'SLA.FORM.FIRST_RESPONSE_TIME.PLACEHOLDER',
        },
        {
          threshold: null,
          unit: 'Minutes',
          label: 'SLA.FORM.NEXT_RESPONSE_TIME.LABEL',
          placeholder: 'SLA.FORM.NEXT_RESPONSE_TIME.PLACEHOLDER',
        },
        {
          threshold: null,
          unit: 'Minutes',
          label: 'SLA.FORM.RESOLUTION_TIME.LABEL',
          placeholder: 'SLA.FORM.RESOLUTION_TIME.PLACEHOLDER',
        },
      ],
      onlyDuringBusinessHours: false,
    };
  },
  validations,
  computed: {
    ...mapGetters({
      uiFlags: 'sla/getUIFlags',
    }),
    isSubmitDisabled() {
      return (
        this.v$.name.$invalid ||
        this.isSlaTimeInputsInvalid ||
        this.uiFlags.isUpdating
      );
    },
    localizedSlaTimeInputs() {
      return [
        {
          ...this.slaTimeInputs[0],
          translatedLabel: this.$t('SLA.FORM.FIRST_RESPONSE_TIME.LABEL'),
          translatedPlaceholder: this.$t(
            'SLA.FORM.FIRST_RESPONSE_TIME.PLACEHOLDER'
          ),
        },
        {
          ...this.slaTimeInputs[1],
          translatedLabel: this.$t('SLA.FORM.NEXT_RESPONSE_TIME.LABEL'),
          translatedPlaceholder: this.$t(
            'SLA.FORM.NEXT_RESPONSE_TIME.PLACEHOLDER'
          ),
        },
        {
          ...this.slaTimeInputs[2],
          translatedLabel: this.$t('SLA.FORM.RESOLUTION_TIME.LABEL'),
          translatedPlaceholder: this.$t(
            'SLA.FORM.RESOLUTION_TIME.PLACEHOLDER'
          ),
        },
      ];
    },
    slaNameErrorMessage() {
      let errorMessage = '';
      if (this.v$.name.$error) {
        if (!this.v$.name.required) {
          errorMessage = this.$t('SLA.FORM.NAME.REQUIRED_ERROR');
        } else if (!this.v$.name.minLength) {
          errorMessage = this.$t('SLA.FORM.NAME.MINIMUM_LENGTH_ERROR');
        }
      }
      return errorMessage;
    },
  },
  mounted() {
    if (this.selectedResponse?.id) {
      this.setFormValues();
    }
  },
  methods: {
    onClose() {
      this.$emit('close');
    },
    resetFormValues() {
      this.name = '';
      this.description = '';
      this.onlyDuringBusinessHours = false;
      this.isSlaTimeInputsInvalid = false;
      this.slaTimeInputsValidation = {};
      this.slaTimeInputs.forEach(input => {
        input.threshold = null;
        input.unit = 'Minutes';
      });
      this.v$?.$reset?.();
    },
    setFormValues() {
      const {
        name,
        description,
        first_response_time_threshold: firstResponseTimeThreshold,
        next_response_time_threshold: nextResponseTimeThreshold,
        resolution_time_threshold: resolutionTimeThreshold,
        only_during_business_hours: onlyDuringBusinessHours,
      } = this.selectedResponse;

      this.name = name;
      this.description = description;
      this.onlyDuringBusinessHours = onlyDuringBusinessHours;

      const thresholds = [
        firstResponseTimeThreshold,
        nextResponseTimeThreshold,
        resolutionTimeThreshold,
      ];
      this.slaTimeInputs.forEach((input, index) => {
        const converted = convertSecondsToTimeUnit(thresholds[index], {
          minute: 'Minutes',
          hour: 'Hours',
          day: 'Days',
        });
        input.threshold = converted.time;
        input.unit = converted.unit;
      });
      this.v$?.$reset?.();
    },
    updateThreshold(index, value) {
      this.slaTimeInputs[index].threshold = value;
    },
    updateUnit(index, unit) {
      this.slaTimeInputs[index].unit = unit;
    },
    onSubmit() {
      const payload = {
        name: this.name,
        description: this.description,
        first_response_time_threshold: this.convertToSeconds(0),
        next_response_time_threshold: this.convertToSeconds(1),
        resolution_time_threshold: this.convertToSeconds(2),
        only_during_business_hours: this.onlyDuringBusinessHours,
      };
      this.$emit('submitSla', payload);
    },
    convertToSeconds(index) {
      const { threshold, unit } = this.slaTimeInputs[index];
      if (threshold === null || threshold === 0) return null;
      const unitsToSeconds = { Minutes: 60, Hours: 3600, Days: 86400 };
      return Number(threshold * (unitsToSeconds[unit] || 1));
    },
    handleIsInvalid(index, isInvalid) {
      this.slaTimeInputsValidation = {
        ...this.slaTimeInputsValidation,
        [index]: isInvalid,
      };

      this.checkValidationState();
    },
    checkValidationState() {
      const isAnyInvalid = Object.values(this.slaTimeInputsValidation).some(
        isInvalid => isInvalid
      );
      this.isSlaTimeInputsInvalid = isAnyInvalid;
    },
  },
};
</script>

<template>
  <div class="flex flex-col h-auto overflow-auto">
    <form class="flex flex-col gap-3 mx-0" @submit.prevent="onSubmit">
      <NextInput
        v-model="name"
        class="w-full"
        :label="$t('SLA.FORM.NAME.LABEL')"
        :placeholder="$t('SLA.FORM.NAME.PLACEHOLDER')"
        :message="slaNameErrorMessage"
        :message-type="slaNameErrorMessage ? 'error' : 'info'"
        @update:model-value="v$.name.$touch()"
        @blur="v$.name.$touch"
      />
      <NextInput
        v-model="description"
        class="w-full"
        :label="$t('SLA.FORM.DESCRIPTION.LABEL')"
        :placeholder="$t('SLA.FORM.DESCRIPTION.PLACEHOLDER')"
      />

      <div class="grid w-full grid-cols-1 gap-3 md:grid-cols-3 md:gap-3">
        <SlaTimeInput
          v-for="(input, index) in localizedSlaTimeInputs"
          :key="index"
          :threshold="input.threshold"
          :threshold-unit="input.unit"
          :label="input.translatedLabel"
          :placeholder="input.translatedPlaceholder"
          @update-threshold="updateThreshold(index, $event)"
          @unit="updateUnit(index, $event)"
          @is-in-valid="handleIsInvalid(index, $event)"
        />
      </div>

      <div
        class="mt-1 flex h-10 items-center justify-between gap-2 rounded-xl border border-solid border-n-strong px-3 py-1.5 text-sm w-full"
      >
        <span for="sla_bh" class="text-n-slate-11">
          {{ $t('SLA.FORM.BUSINESS_HOURS.PLACEHOLDER') }}
        </span>
        <ToggleSwitch id="sla_bh" v-model="onlyDuringBusinessHours" />
      </div>

      <div class="mt-5 flex w-full items-center justify-end gap-2">
        <NextButton
          faded
          slate
          type="reset"
          :label="$t('SLA.FORM.CANCEL')"
          @click.prevent="onClose"
        />
        <NextButton
          type="submit"
          :label="submitLabel"
          :disabled="isSubmitDisabled"
          :is-loading="uiFlags.isUpdating"
        />
      </div>
    </form>
  </div>
</template>
