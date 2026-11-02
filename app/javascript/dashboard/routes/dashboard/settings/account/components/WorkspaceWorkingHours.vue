<script>
import { useAlert } from 'dashboard/composables';
import {
  accountSettingsMatch,
  accountSettingsFingerprint,
} from 'dashboard/helper/accountSettings';
import BaseSettingsHeader from '../../components/BaseSettingsHeader.vue';
import SectionLayout from './SectionLayout.vue';
import SettingsFieldSection from 'dashboard/components-next/Settings/SettingsFieldSection.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import ruGeneralSettings from 'dashboard/i18n/locale/ru/generalSettings.json';
import BusinessDay from '../../inbox/components/BusinessDay.vue';
import {
  timeSlotParse,
  timeSlotTransform,
  timeZoneOptions,
} from '../../inbox/helpers/businessHour';

const WORKSPACE_DEFAULT_TIMEZONE = 'Asia/Almaty';
const WORKING_HOURS_MESSAGES = ruGeneralSettings.GENERAL_SETTINGS.WORKING_HOURS;
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
    BaseSettingsHeader,
    SectionLayout,
    SettingsFieldSection,
    ComboBox,
    NextButton,
    Checkbox,
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
      timezone: WORKSPACE_DEFAULT_TIMEZONE,
      timeSlots: defaultWorkspaceSchedule(),
      breaks: [],
      daysOff: [],
      saving: false,
    };
  },
  computed: {
    scheduleFingerprint() {
      return accountSettingsFingerprint(this.account, [
        'workspace_timezone',
        'workspace_working_hours',
        'workspace_breaks',
        'workspace_days_off',
      ]);
    },
    timeZones() {
      return timeZoneOptions();
    },
    workingHoursMessages() {
      return WORKING_HOURS_MESSAGES;
    },
    hasError() {
      return (
        this.timeSlots.some(slot => slot.from && !slot.valid) ||
        this.breaks.some(
          item =>
            !item.days.length ||
            !item.start_time ||
            !item.end_time ||
            item.start_time >= item.end_time
        ) ||
        this.daysOff.some(item => !item.date)
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
    scheduleFingerprint: {
      immediate: true,
      handler() {
        this.hydrate();
      },
    },
  },
  methods: {
    hydrate() {
      const settings = this.account.settings || {};
      this.timezone = settings.workspace_timezone || WORKSPACE_DEFAULT_TIMEZONE;
      const schedule = settings.workspace_working_hours;
      this.timeSlots =
        Array.isArray(schedule) && schedule.length === 7
          ? timeSlotParse(schedule).map(slot =>
              slot.openAllDay ? { ...slot, from: '00:00', to: '23:59' } : slot
            )
          : defaultWorkspaceSchedule();
      this.breaks = Array.isArray(settings.workspace_breaks)
        ? settings.workspace_breaks.map(item => ({
            ...item,
            days: Array.isArray(item.days) ? [...item.days] : [],
          }))
        : [];
      this.daysOff = Array.isArray(settings.workspace_days_off)
        ? settings.workspace_days_off.map(item => ({ ...item }))
        : [];
    },
    onTimezoneChange(value) {
      if (value) this.timezone = value;
    },
    onSlotUpdate(day, value) {
      this.timeSlots = this.timeSlots.map(slot =>
        slot.day === day ? value : slot
      );
    },
    addBreak() {
      this.breaks.push({
        days: [1, 2, 3, 4, 5],
        start_time: '13:00',
        end_time: '14:00',
        title: '',
      });
    },
    removeBreak(index) {
      this.breaks.splice(index, 1);
    },
    toggleBreakDay(item, day) {
      item.days = item.days.includes(day)
        ? item.days.filter(value => value !== day)
        : [...item.days, day].sort();
    },
    addDayOff() {
      this.daysOff.push({ date: '', title: '', recurring_yearly: false });
    },
    removeDayOff(index) {
      this.daysOff.splice(index, 1);
    },
    async save() {
      if (this.readOnly || this.saving || this.hasError) return;
      this.saving = true;
      const accountId = this.account.id;
      try {
        const settings = {
          workspace_timezone: this.timezone,
          workspace_working_hours: timeSlotTransform(this.timeSlots).map(day =>
            Object.fromEntries(
              Object.entries(day).map(([key, value]) => [
                key,
                value === '' || Number.isNaN(value) ? null : value,
              ])
            )
          ),
          workspace_breaks: this.breaks.map(item => ({
            days: item.days,
            start_time: item.start_time,
            end_time: item.end_time,
            title: item.title?.trim() || null,
          })),
          workspace_days_off: this.daysOff.map(item => ({
            date: item.date,
            title: item.title?.trim() || null,
            recurring_yearly: Boolean(item.recurring_yearly),
          })),
        };
        const updatedAccount = await this.$store.dispatch('accounts/update', {
          id: accountId,
          ...settings,
        });
        if (!accountSettingsMatch(updatedAccount, settings)) {
          throw new Error(this.workingHoursMessages.UPDATE_ERROR);
        }
        if (this.account.id === accountId)
          useAlert(this.workingHoursMessages.UPDATE_SUCCESS);
      } catch {
        if (this.account.id === accountId)
          useAlert(this.workingHoursMessages.UPDATE_ERROR);
      } finally {
        this.saving = false;
      }
    },
  },
};
</script>

<template>
  <div class="flex flex-col w-full">
    <BaseSettingsHeader
      :title="workingHoursMessages.TITLE"
      :description="workingHoursMessages.DESCRIPTION"
    />

    <div class="flex flex-col w-full mt-4">
      <SectionLayout
        :title="$t('INBOX_MGMT.BUSINESS_HOURS.WEEKLY_TITLE')"
        :description="
          !account.settings?.workspace_working_hours?.length
            ? workingHoursMessages.EMPTY_HINT
            : ''
        "
        class="!pt-0"
      >
        <div class="space-y-4">
          <SettingsFieldSection :label="workingHoursMessages.TIMEZONE">
            <ComboBox
              :model-value="timezone"
              :options="timeZones"
              :disabled="readOnly"
              class="[&>div>button]:!bg-n-alpha-black2"
              @update:model-value="onTimezoneChange"
            />
          </SettingsFieldSection>

          <div
            class="overflow-x-auto rounded-xl border border-n-weak bg-n-solid-2 px-4 py-2"
          >
            <table class="w-full divide-y divide-n-weak">
              <thead>
                <tr>
                  <th />
                  <th
                    class="py-3 pr-3 text-start text-heading-3 text-n-slate-12"
                  >
                    {{ $t('INBOX_MGMT.BUSINESS_HOURS.DAY.DAY') }}
                  </th>
                  <th
                    class="py-3 pr-3 text-start text-heading-3 text-n-slate-12"
                  >
                    {{ $t('INBOX_MGMT.BUSINESS_HOURS.DAY.AVAILABILITY') }}
                  </th>
                  <th
                    class="py-3 pr-3 text-start text-heading-3 text-n-slate-12"
                  >
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
        </div>
      </SectionLayout>

      <SectionLayout
        :title="workingHoursMessages.BREAKS.TITLE"
        :description="workingHoursMessages.BREAKS.DESCRIPTION"
        with-border
      >
        <template #headerActions>
          <div class="flex justify-end">
            <NextButton
              :label="workingHoursMessages.BREAKS.ADD"
              variant="faded"
              size="sm"
              :disabled="readOnly"
              @click="addBreak"
            />
          </div>
        </template>

        <div class="space-y-3">
          <p v-if="!breaks.length" class="text-sm text-n-slate-11">
            {{ workingHoursMessages.BREAKS.EMPTY }}
          </p>
          <div
            v-for="(item, index) in breaks"
            :key="`break-${index}`"
            class="space-y-3 rounded-xl border border-n-weak bg-n-solid-2 p-4"
          >
            <div
              class="grid items-end gap-3 md:grid-cols-[1fr_140px_140px_auto]"
            >
              <label class="space-y-1 text-xs text-n-slate-11">
                <span>{{ workingHoursMessages.BREAKS.NAME }}</span>
                <input
                  v-model="item.title"
                  type="text"
                  maxlength="80"
                  :disabled="readOnly"
                  :placeholder="workingHoursMessages.BREAKS.NAME"
                  class="h-10 w-full rounded-lg border border-n-weak bg-n-alpha-black2 px-3 text-sm text-n-slate-12"
                />
              </label>
              <label class="space-y-1 text-xs text-n-slate-11">
                <span>{{ workingHoursMessages.START }}</span>
                <input
                  v-model="item.start_time"
                  type="time"
                  :disabled="readOnly"
                  class="h-10 w-full rounded-lg border border-n-weak bg-n-alpha-black2 px-3 text-sm text-n-slate-12"
                />
              </label>
              <label class="space-y-1 text-xs text-n-slate-11">
                <span>{{ workingHoursMessages.END }}</span>
                <input
                  v-model="item.end_time"
                  type="time"
                  :disabled="readOnly"
                  class="h-10 w-full rounded-lg border border-n-weak bg-n-alpha-black2 px-3 text-sm text-n-slate-12"
                />
              </label>
              <button
                type="button"
                class="h-10 px-2 text-sm text-n-ruby-11 disabled:opacity-50"
                :disabled="readOnly"
                @click="removeBreak(index)"
              >
                {{ workingHoursMessages.REMOVE }}
              </button>
            </div>
            <div class="flex flex-wrap gap-2">
              <button
                v-for="day in [1, 2, 3, 4, 5, 6, 0]"
                :key="day"
                type="button"
                class="rounded-full border px-3 py-1 text-xs transition-colors"
                :class="
                  item.days.includes(day)
                    ? 'border-n-blue-8 bg-n-blue-3 text-n-blue-11'
                    : 'border-n-weak text-n-slate-11'
                "
                :disabled="readOnly"
                @click="toggleBreakDay(item, day)"
              >
                {{ dayNames[day] }}
              </button>
            </div>
          </div>
        </div>
      </SectionLayout>

      <SectionLayout
        :title="workingHoursMessages.DAYS_OFF.TITLE"
        :description="workingHoursMessages.DAYS_OFF.DESCRIPTION"
        with-border
      >
        <template #headerActions>
          <div class="flex justify-end">
            <NextButton
              :label="workingHoursMessages.DAYS_OFF.ADD"
              variant="faded"
              size="sm"
              :disabled="readOnly"
              @click="addDayOff"
            />
          </div>
        </template>

        <div class="space-y-3">
          <p v-if="!daysOff.length" class="text-sm text-n-slate-11">
            {{ workingHoursMessages.DAYS_OFF.EMPTY }}
          </p>
          <div
            v-for="(item, index) in daysOff"
            :key="`day-off-${index}`"
            class="grid items-end gap-3 rounded-xl border border-n-weak bg-n-solid-2 p-4 md:grid-cols-[180px_1fr_auto_auto]"
          >
            <label class="space-y-1 text-xs text-n-slate-11">
              <span>{{ workingHoursMessages.DATE }}</span>
              <input
                v-model="item.date"
                type="date"
                :disabled="readOnly"
                class="h-10 w-full rounded-lg border border-n-weak bg-n-alpha-black2 px-3 text-sm text-n-slate-12"
              />
            </label>
            <label class="space-y-1 text-xs text-n-slate-11">
              <span>{{ workingHoursMessages.DAYS_OFF.NAME }}</span>
              <input
                v-model="item.title"
                type="text"
                maxlength="80"
                :disabled="readOnly"
                :placeholder="workingHoursMessages.DAYS_OFF.NAME"
                class="h-10 w-full rounded-lg border border-n-weak bg-n-alpha-black2 px-3 text-sm text-n-slate-12"
              />
            </label>
            <label class="flex h-10 items-center gap-2 text-sm text-n-slate-11">
              <Checkbox v-model="item.recurring_yearly" :disabled="readOnly" />
              {{ workingHoursMessages.DAYS_OFF.YEARLY }}
            </label>
            <button
              type="button"
              class="h-10 px-2 text-sm text-n-ruby-11 disabled:opacity-50"
              :disabled="readOnly"
              @click="removeDayOff(index)"
            >
              {{ workingHoursMessages.REMOVE }}
            </button>
          </div>
        </div>
      </SectionLayout>

      <div class="flex justify-end border-t border-n-weak pt-6">
        <NextButton
          :label="workingHoursMessages.SAVE"
          :disabled="readOnly || hasError || saving"
          :is-loading="saving"
          @click="save"
        />
      </div>
    </div>
  </div>
</template>
