<script>
import { mapGetters } from 'vuex';
import { useAlert } from 'dashboard/composables';
import SectionLayout from './SectionLayout.vue';
import SettingsToggleSection from 'dashboard/components-next/Settings/SettingsToggleSection.vue';
import SettingsFieldSection from 'dashboard/components-next/Settings/SettingsFieldSection.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import BusinessDay from '../../inbox/components/BusinessDay.vue';
import {
  timeSlotParse,
  timeSlotTransform,
  timeZoneOptions,
} from '../../inbox/helpers/businessHour';

const WORKSPACE_DEFAULT_TIMEZONE = 'Asia/Almaty';

const defaultWorkspaceSchedule = () =>
  Array.from({ length: 7 }, (_, day) => ({
    day,
    from: day > 0 && day < 6 ? '09:00' : '',
    to: day > 0 && day < 6 ? '17:00' : '',
    valid: day > 0 && day < 6,
    openAllDay: false,
  }));

export default {
  components: {
    SectionLayout,
    SettingsToggleSection,
    SettingsFieldSection,
    ComboBox,
    NextButton,
    BusinessDay,
  },
  props: {
    account: {
      type: Object,
      required: true,
    },
    readOnly: {
      type: Boolean,
      default: false,
    },
  },
  data() {
    return {
      enabled: false,
      timezone: WORKSPACE_DEFAULT_TIMEZONE,
      timeSlots: defaultWorkspaceSchedule(),
    };
  },
  computed: {
    ...mapGetters({ uiFlags: 'accounts/getUIFlags' }),
    timeZones() {
      return timeZoneOptions();
    },
    hasError() {
      return (
        this.enabled && this.timeSlots.some(slot => slot.from && !slot.valid)
      );
    },
    dayNames() {
      return [
        this.$t('INBOX_MGMT.BUSINESS_HOURS.DAY_NAMES.SUNDAY'),
        this.$t('INBOX_MGMT.BUSINESS_HOURS.DAY_NAMES.MONDAY'),
        this.$t('INBOX_MGMT.BUSINESS_HOURS.DAY_NAMES.TUESDAY'),
        this.$t('INBOX_MGMT.BUSINESS_HOURS.DAY_NAMES.WEDNESDAY'),
        this.$t('INBOX_MGMT.BUSINESS_HOURS.DAY_NAMES.THURSDAY'),
        this.$t('INBOX_MGMT.BUSINESS_HOURS.DAY_NAMES.FRIDAY'),
        this.$t('INBOX_MGMT.BUSINESS_HOURS.DAY_NAMES.SATURDAY'),
      ];
    },
  },
  watch: {
    account: {
      immediate: true,
      deep: true,
      handler() {
        this.hydrate();
      },
    },
  },
  methods: {
    hydrate() {
      const settings = this.account.settings || {};
      this.enabled = Boolean(settings.workspace_working_hours_enabled);
      this.timezone = settings.workspace_timezone || WORKSPACE_DEFAULT_TIMEZONE;
      const schedule = settings.workspace_working_hours;
      this.timeSlots =
        Array.isArray(schedule) && schedule.length === 7
          ? timeSlotParse(schedule)
          : defaultWorkspaceSchedule();
    },
    onSlotUpdate(day, value) {
      this.timeSlots = this.timeSlots.map(slot =>
        slot.day === day ? value : slot
      );
    },
    async save() {
      try {
        await this.$store.dispatch('accounts/update', {
          id: this.account.id,
          workspace_working_hours_enabled: this.enabled,
          workspace_timezone: this.timezone,
          workspace_working_hours: timeSlotTransform(this.timeSlots),
        });
        useAlert(this.$t('GENERAL_SETTINGS.WORKING_HOURS.UPDATE_SUCCESS'));
      } catch (error) {
        useAlert(
          error.message ||
            this.$t('GENERAL_SETTINGS.WORKING_HOURS.UPDATE_ERROR')
        );
      }
    },
  },
};
</script>

<template>
  <SectionLayout
    :title="$t('GENERAL_SETTINGS.WORKING_HOURS.TITLE')"
    :description="$t('GENERAL_SETTINGS.WORKING_HOURS.DESCRIPTION')"
  >
    <div class="space-y-6">
      <SettingsToggleSection
        v-model="enabled"
        :disabled="readOnly"
        :header="$t('GENERAL_SETTINGS.WORKING_HOURS.ENABLE')"
        :description="$t('GENERAL_SETTINGS.WORKING_HOURS.ENABLE_HELP')"
      />

      <template v-if="enabled">
        <SettingsFieldSection
          :label="$t('GENERAL_SETTINGS.WORKING_HOURS.TIMEZONE')"
        >
          <ComboBox
            v-model="timezone"
            :options="timeZones"
            :disabled="readOnly"
            class="[&>div>button]:!bg-n-alpha-black2"
          />
        </SettingsFieldSection>

        <div class="overflow-x-auto">
          <table
            class="min-w-full table-auto rounded-xl outline outline-1 -outline-offset-1 outline-n-weak"
          >
            <thead>
              <tr class="border-b border-n-weak">
                <th
                  class="py-3 pl-4 pr-3 text-start text-heading-3 text-n-slate-12"
                >
                  {{ $t('INBOX_MGMT.BUSINESS_HOURS.DAY.DAY') }}
                </th>
                <th class="py-3 pr-3 text-start text-heading-3 text-n-slate-12">
                  {{ $t('INBOX_MGMT.BUSINESS_HOURS.DAY.AVAILABILITY') }}
                </th>
                <th class="py-3 pr-3 text-start text-heading-3 text-n-slate-12">
                  {{ $t('INBOX_MGMT.BUSINESS_HOURS.DAY.HOURS') }}
                </th>
              </tr>
            </thead>
            <tbody
              class="divide-y divide-n-weak"
              :class="{ 'pointer-events-none opacity-60': readOnly }"
            >
              <BusinessDay
                v-for="slot in timeSlots"
                :key="slot.day"
                :day-name="dayNames[slot.day]"
                :time-slot="slot"
                @update="value => onSlotUpdate(slot.day, value)"
              />
            </tbody>
          </table>
        </div>
      </template>

      <div class="flex justify-end">
        <NextButton
          :label="$t('GENERAL_SETTINGS.WORKING_HOURS.SAVE')"
          :disabled="readOnly || hasError"
          :is-loading="uiFlags.isUpdating"
          @click="save"
        />
      </div>
    </div>
  </SectionLayout>
</template>
