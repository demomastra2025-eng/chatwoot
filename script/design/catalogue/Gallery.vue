<script setup>
/* eslint-disable @intlify/vue-i18n/no-missing-keys -- This standalone host loads the adjacent messages.js, outside the app localeDir. */
import { computed, onBeforeUnmount, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import SelectMenu from 'dashboard/components-next/selectmenu/SelectMenu.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Radio from 'dashboard/components-next/radio/Radio.vue';
import RadioCard from 'dashboard/components-next/radioCard/RadioCard.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';
import Banner from 'dashboard/components-next/banner/Banner.vue';
import PaginationFooter from 'dashboard/components-next/pagination/PaginationFooter.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import DsTable from 'dashboard/components-next/ds/DsTable.vue';
import DsState from 'dashboard/components-next/ds/DsState.vue';
import DsStatusDot from 'dashboard/components-next/ds/DsStatusDot.vue';
import DsMeter from 'dashboard/components-next/ds/DsMeter.vue';
import DsSegmented from 'dashboard/components-next/ds/DsSegmented.vue';
import DsStatGroup from 'dashboard/components-next/ds/DsStatGroup.vue';
import DsChartFrame from 'dashboard/components-next/ds/DsChartFrame.vue';
import CardLayout from 'dashboard/components-next/CardLayout.vue';
import SettingsToggleSection from 'dashboard/components-next/Settings/SettingsToggleSection.vue';
import SectionLayout from 'dashboard/routes/dashboard/settings/account/components/SectionLayout.vue';

// Dashboard catalogue: the existing settings, toggle, compact, object and report
// recipes from the skill. Source examples: SettingsForm.vue, DependentSetting.vue,
// ToggleGroup.vue, EditDialog.vue and ReportTable.vue in its assets/examples.
// BaseSettingsHeader imports the live app router through BackButton, so this
// standalone host uses its canonical heading token without that dependency.
defineProps({ dark: { type: Boolean, default: false } });
const emit = defineEmits(['theme']);
const { t, locale } = useI18n({ useScope: 'global' });

const groupKeys = ['FOUNDATIONS', 'ACTIONS', 'FIELDS', 'LAYOUTS', 'DATA'];
const activeGroup = ref(0);
const groupTabs = computed(() =>
  groupKeys.map(key => ({ label: t(`CATALOGUE.GROUPS.${key}`) }))
);
const changeGroup = tab => {
  activeGroup.value = groupTabs.value.findIndex(item => item === tab);
};
const languageOptions = computed(() =>
  ['ru', 'kk', 'en'].map(value => ({
    value,
    label: t(`CATALOGUE.LANGUAGES.${value.toUpperCase()}`),
  }))
);

const semanticTokens = [
  { token: 'n-background', color: 'bg-n-background', label: 'BACKGROUND' },
  { token: 'n-solid-1', color: 'bg-n-solid-1', label: 'SOLID_1' },
  { token: 'n-solid-2', color: 'bg-n-solid-2', label: 'SOLID_2' },
  { token: 'n-brand', color: 'bg-n-brand', label: 'BRAND' },
  { token: 'n-brand-solid', color: 'bg-n-brand-solid', label: 'BRAND_SOLID' },
  { token: 'n-slate-12', color: 'bg-n-slate-12', label: 'INK' },
  { token: 'n-slate-11', color: 'bg-n-slate-11', label: 'MUTED' },
  { token: 'n-status-good', color: 'bg-n-status-good', label: 'GOOD' },
  { token: 'n-status-warn', color: 'bg-n-status-warn', label: 'WARN' },
  { token: 'n-status-bad', color: 'bg-n-status-bad', label: 'BAD' },
];
const slateTokens = [
  'bg-n-slate-1',
  'bg-n-slate-2',
  'bg-n-slate-3',
  'bg-n-slate-4',
  'bg-n-slate-5',
  'bg-n-slate-6',
  'bg-n-slate-7',
  'bg-n-slate-8',
  'bg-n-slate-9',
  'bg-n-slate-10',
  'bg-n-slate-11',
  'bg-n-slate-12',
];
const typeRoles = [
  {
    token: 'text-heading-1',
    style: 'text-heading-1 text-n-slate-12',
    key: 'PAGE_TITLE',
  },
  {
    token: 'text-heading-2',
    style: 'text-heading-2 text-n-slate-12',
    key: 'SECTION_TITLE',
  },
  {
    token: 'text-heading-3',
    style: 'text-heading-3 text-n-slate-12',
    key: 'FIELD_TITLE',
  },
  {
    token: 'text-body-main',
    style: 'text-body-main text-n-slate-12',
    key: 'BODY',
  },
  {
    token: 'text-body-para',
    style: 'text-body-para text-n-slate-11',
    key: 'HELP',
  },
];
const componentNames = {
  actions: 'Button',
  messages: 'Banner',
  navigation: 'TabBar · DropdownMenu · Dialog',
  text: 'Input · TextArea',
  selection: 'Select · ComboBox · SelectMenu',
  choices: 'Checkbox · Radio · RadioCard',
  dependent: 'SettingsToggleSection · #editor',
  toggles: 'Switch',
  objects: 'CardLayout',
  statistics: 'DsStatGroup',
  table: 'DsTable · DsState · DsStatusDot · DsMeter · PaginationFooter',
  charts: 'DsChartFrame',
};
const icons = [
  'i-lucide-search',
  'i-lucide-settings',
  'i-lucide-check',
  'i-lucide-info',
  'i-lucide-pencil',
];

const timers = new Set();
const later = (callback, delay = 800) => {
  const timer = setTimeout(() => {
    timers.delete(timer);
    callback();
  }, delay);
  timers.add(timer);
  return timer;
};
onBeforeUnmount(() => timers.forEach(timer => clearTimeout(timer)));

const actionSaving = ref(false);
const actionNotice = ref('');
const saveAction = () => {
  if (actionSaving.value) return;
  actionSaving.value = true;
  actionNotice.value = '';
  later(() => {
    actionSaving.value = false;
    actionNotice.value = 'SAVED';
  });
};
const resetAction = () => {
  if (!actionSaving.value) actionNotice.value = '';
};

const demoName = ref('OneLink');
const editName = ref('');
const dialog = ref(null);
const dialogSaving = ref(false);
const dialogSaved = ref(false);
let dialogTimer;
const openDialog = () => {
  editName.value = demoName.value;
  dialogSaved.value = false;
  dialog.value?.open();
};
const saveDialog = () => {
  if (dialogSaving.value || !editName.value.trim()) return;
  dialogSaving.value = true;
  dialogTimer = later(() => {
    demoName.value = editName.value.trim();
    dialogSaving.value = false;
    dialogSaved.value = true;
    dialog.value?.close();
  });
};
const closeDialog = () => {
  if (!dialogSaving.value) return;
  clearTimeout(dialogTimer);
  timers.delete(dialogTimer);
  dialogSaving.value = false;
};
const activeExampleTab = ref(0);
const exampleTabs = computed(() => [
  { label: t('CATALOGUE.ACTIONS.OVERVIEW') },
  { label: t('CATALOGUE.ACTIONS.HISTORY') },
]);
const changeExampleTab = tab => {
  activeExampleTab.value = exampleTabs.value.findIndex(item => item === tab);
};
const menuOpen = ref(false);
const menuItems = computed(() => [
  {
    action: 'edit',
    value: 'edit',
    label: t('CATALOGUE.ACTIONS.EDIT'),
    icon: 'i-lucide-pencil',
  },
  {
    action: 'reset',
    value: 'reset',
    label: t('CATALOGUE.ACTIONS.RESET'),
    icon: 'i-lucide-rotate-ccw',
  },
  {
    action: 'unavailable',
    value: 'unavailable',
    label: t('CATALOGUE.ACTIONS.UNAVAILABLE'),
    disabled: true,
  },
]);
const handleMenuAction = ({ action }) => {
  menuOpen.value = false;
  if (action === 'edit') openDialog();
  if (action === 'reset') {
    demoName.value = 'OneLink';
    dialogSaved.value = false;
  }
};

const formName = ref('OneLink');
const requiredName = ref('');
const notes = ref('');
const channel = ref('website');
const searchedChannel = ref('');
const menuChannel = ref('website');
const channelKeys = [
  'WEBSITE',
  'MESSAGING',
  'EMAIL',
  'FORM',
  'DEMO_1',
  'DEMO_2',
];
const channels = computed(() =>
  channelKeys.map(key => ({
    value: key.toLowerCase(),
    label: t(`CATALOGUE.FORM.CHANNELS.${key}`),
  }))
);
const menuChannelLabel = computed(
  () =>
    channels.value.find(item => item.value === menuChannel.value)?.label ||
    t('CATALOGUE.FORM.CHOOSE')
);
const notifications = ref(true);
const mode = ref('standard');
const cardChoice = ref('manual');
const cardOptions = computed(() => [
  {
    id: 'manual',
    label: t('CATALOGUE.FORM.MANUAL'),
    description: t('CATALOGUE.FORM.MANUAL_DESCRIPTION'),
  },
  {
    id: 'scheduled',
    label: t('CATALOGUE.FORM.SCHEDULED'),
    description: t('CATALOGUE.FORM.SCHEDULED_DESCRIPTION'),
  },
]);

const dependentEnabled = ref(false);
const dependentName = ref('OneLink');
const weekly = ref(false);
const featureName = ref('OneLink');
const featureChannel = ref('website');
const prefix = ref('OneLink');
const suffix = ref('');

const reportState = ref('filled');
const reportStates = ['filled', 'empty', 'loading', 'error'];
const currentPage = ref(1);
const period = ref(7);
const periodOptions = computed(() =>
  [7, 14, 30].map(value => ({
    value,
    label: t(`CATALOGUE.DATA.DAYS_${value}`),
  }))
);
let retryTimer;
const chooseReportState = state => {
  clearTimeout(retryTimer);
  timers.delete(retryTimer);
  reportState.value = state;
};
const retryReport = () => {
  chooseReportState('loading');
  retryTimer = later(() => {
    reportState.value = 'filled';
  }, 700);
};
const statusLabel = status =>
  t(`CATALOGUE.DATA.STATUS_${status.toUpperCase()}`);
const reportColumns = computed(() => [
  { key: 'name', label: t('CATALOGUE.DATA.CHANNEL') },
  { key: 'count', label: t('CATALOGUE.DATA.COUNT'), numeric: true },
  { key: 'load', label: t('CATALOGUE.DATA.LOAD') },
  { key: 'status', label: t('CATALOGUE.DATA.STATUS') },
]);
const reportRows = computed(() =>
  channels.value.map((item, index) => ({
    id: item.value,
    name: item.label,
    count: [128, 96, 64, 42, 24, 16][index],
    load: [72, 84, 97, 38, 56, 0][index],
    status: ['good', 'warn', 'bad', 'good', 'good', 'neutral'][index],
  }))
);
const pageRows = computed(() =>
  reportRows.value.slice((currentPage.value - 1) * 3, currentPage.value * 3)
);
const stats = computed(() => [
  {
    key: 'conversations',
    label: t('CATALOGUE.DATA.STATS_COUNT'),
    value: new Intl.NumberFormat(locale.value).format(
      { 7: 370, 14: 740, 30: 1584 }[period.value]
    ),
    note: t('CATALOGUE.DATA.STATS_PERIOD'),
  },
  {
    key: 'channels',
    label: t('CATALOGUE.DATA.STATS_CHANNELS'),
    value: '6',
    note: t('CATALOGUE.DATA.STATS_DEMO'),
  },
  {
    key: 'replies',
    label: t('CATALOGUE.DATA.STATS_REPLY'),
    value: '92%',
    note: t('CATALOGUE.DATA.STATS_DEMO'),
  },
]);
const chartLabels = computed(() => {
  if (reportState.value !== 'filled') return [];
  return Array.from({ length: 7 }, (_, index) =>
    t('CATALOGUE.DATA.DAY', {
      number: Math.round(((index + 1) * period.value) / 7),
    })
  );
});
const chartSeries = computed(() => {
  const factor = period.value / 7;
  return [
    {
      key: 'current',
      label: t('CATALOGUE.DATA.CURRENT'),
      values: [30, 48, 42, 64, 51, 72, 63].map(value =>
        Math.round(value * factor)
      ),
    },
    {
      key: 'previous',
      label: t('CATALOGUE.DATA.PREVIOUS'),
      values: [25, 34, 39, 45, 41, 56, 54].map(value =>
        Math.round(value * factor)
      ),
    },
  ];
});
const stageLabels = computed(() =>
  ['NEW', 'PROGRESS', 'COMPLETE'].map(key => t(`CATALOGUE.DATA.STAGE_${key}`))
);
const stageSeries = computed(() => [
  { key: 'stages', label: t('CATALOGUE.DATA.COUNT'), values: [370, 280, 240] },
]);
</script>

<template>
  <main
    class="flex w-full min-w-0 flex-col gap-4 bg-n-background px-6 pb-8 pt-4 text-n-slate-12"
    data-test="gallery"
  >
    <header class="flex min-w-0 flex-col gap-4">
      <div class="flex flex-col gap-1">
        <h1 class="text-heading-1 text-n-slate-12">
          {{ t('CATALOGUE.TITLE') }}
        </h1>
        <p class="mb-0 max-w-3xl text-body-main text-n-slate-11">
          {{ t('CATALOGUE.DESCRIPTION') }}
        </p>
      </div>
      <div class="flex flex-wrap items-center gap-4">
        <div class="flex items-center gap-3">
          <label
            for="gallery-language"
            class="text-heading-3 text-n-slate-12"
            >{{ t('CATALOGUE.LANGUAGE') }}</label
          >
          <Select
            id="gallery-language"
            v-model="locale"
            :options="languageOptions"
            data-test="gallery-locale"
          />
        </div>
        <div class="flex items-center gap-3">
          <label
            for="gallery-dark-theme"
            class="text-heading-3 text-n-slate-12"
            >{{ t('CATALOGUE.THEME') }}</label
          >
          <Switch
            id="gallery-dark-theme"
            :model-value="dark"
            :aria-label="t('CATALOGUE.THEME')"
            data-test="gallery-theme"
            @update:model-value="emit('theme', $event)"
          />
        </div>
      </div>
      <div class="min-w-0 overflow-x-auto pb-1">
        <TabBar
          :tabs="groupTabs"
          :initial-active-tab="activeGroup"
          data-test="gallery-groups"
          @tab-changed="changeGroup"
        />
      </div>
    </header>

    <div v-show="activeGroup === 0" id="gallery-foundations" class="min-w-0">
      <SectionLayout
        :title="t('CATALOGUE.FOUNDATIONS.TITLE')"
        :description="t('CATALOGUE.FOUNDATIONS.DESCRIPTION')"
      >
        <div class="flex min-w-0 flex-col gap-6">
          <div class="flex flex-col gap-4">
            <h2 class="text-heading-2 text-n-slate-12">
              {{ t('CATALOGUE.FOUNDATIONS.SEMANTIC') }}
            </h2>
            <ul
              class="m-0 grid list-none grid-cols-2 gap-4 p-0 sm:grid-cols-3 lg:grid-cols-5"
            >
              <li
                v-for="token in semanticTokens"
                :key="token.token"
                class="flex min-w-0 flex-col gap-1"
              >
                <span
                  class="block h-10 w-full outline outline-1 -outline-offset-1 outline-n-weak"
                  :class="token.color"
                  aria-hidden="true"
                />
                <span class="mb-0 text-body-main text-n-slate-12">{{
                  t(`CATALOGUE.FOUNDATIONS.TOKENS.${token.label}`)
                }}</span>
                <code class="break-words text-body-main text-n-slate-11">{{
                  token.token
                }}</code>
              </li>
            </ul>
          </div>
          <div class="flex flex-col gap-4">
            <h2 class="text-heading-2 text-n-slate-12">
              {{ t('CATALOGUE.FOUNDATIONS.SLATE') }}
            </h2>
            <ul
              class="m-0 grid list-none grid-cols-4 gap-4 p-0 sm:grid-cols-6 lg:grid-cols-12"
            >
              <li
                v-for="(color, index) in slateTokens"
                :key="color"
                class="flex min-w-0 flex-col gap-1"
              >
                <span
                  class="block h-10 w-full"
                  :class="color"
                  aria-hidden="true"
                />
                <code class="break-words text-body-main text-n-slate-11">{{
                  `slate-${index + 1}`
                }}</code>
              </li>
            </ul>
          </div>
          <div class="flex flex-col gap-4">
            <h2 class="text-heading-2 text-n-slate-12">
              {{ t('CATALOGUE.FOUNDATIONS.TYPE') }}
            </h2>
            <div class="divide-y divide-n-weak">
              <div
                v-for="role in typeRoles"
                :key="role.token"
                class="flex flex-col gap-1 py-3 sm:flex-row sm:items-center sm:justify-between sm:gap-4"
              >
                <p :class="role.style">
                  {{ t(`CATALOGUE.FOUNDATIONS.${role.key}`) }}
                </p>
                <code class="mb-0 text-body-main text-n-slate-11">{{
                  role.token
                }}</code>
              </div>
            </div>
          </div>
          <div class="flex flex-col gap-4">
            <h2 class="text-heading-2 text-n-slate-12">
              {{ t('CATALOGUE.FOUNDATIONS.ICONS') }}
            </h2>
            <p class="mb-0 text-body-main text-n-slate-11">
              {{ t('CATALOGUE.FOUNDATIONS.ICON_DESCRIPTION') }}
            </p>
            <ul class="m-0 flex list-none flex-wrap gap-4 p-0">
              <li
                v-for="icon in icons"
                :key="icon"
                class="flex items-center gap-2"
              >
                <Icon :icon="icon" aria-hidden="true" />
                <code class="mb-0 text-body-main text-n-slate-11">{{
                  icon
                }}</code>
              </li>
            </ul>
          </div>
        </div>
      </SectionLayout>
    </div>

    <div v-show="activeGroup === 1" id="gallery-actions" class="min-w-0">
      <SectionLayout
        :title="t('CATALOGUE.ACTIONS.TITLE')"
        :description="t('CATALOGUE.ACTIONS.DESCRIPTION')"
      >
        <div class="flex max-w-3xl flex-col gap-4">
          <code class="mb-0 text-body-main text-n-slate-11">{{
            componentNames.actions
          }}</code>
          <div class="flex flex-wrap items-center gap-4">
            <Button
              type="button"
              variant="solid"
              color="blue"
              size="md"
              icon="i-lucide-check"
              :label="
                t(
                  actionSaving
                    ? 'CATALOGUE.ACTIONS.SAVING'
                    : 'CATALOGUE.ACTIONS.SAVE'
                )
              "
              :is-loading="actionSaving"
              :disabled="actionSaving"
              data-test="gallery-save"
              @click="saveAction"
            />
            <Button
              type="button"
              variant="ghost"
              color="slate"
              size="md"
              :label="t('CATALOGUE.ACTIONS.CANCEL')"
              :disabled="actionSaving"
              @click="resetAction"
            />
            <Button
              type="button"
              variant="outline"
              color="slate"
              size="md"
              :label="t('CATALOGUE.ACTIONS.OUTLINE')"
              @click="actionNotice = 'SECONDARY_DONE'"
            />
          </div>
          <div class="flex flex-wrap items-center gap-4">
            <Button
              type="button"
              variant="solid"
              color="ruby"
              size="md"
              :label="t('CATALOGUE.ACTIONS.DELETE')"
              disabled
            />
            <Button
              type="button"
              variant="outline"
              color="slate"
              size="md"
              :label="t('CATALOGUE.ACTIONS.DISABLED')"
              disabled
            />
            <Button
              v-tooltip.top="t('CATALOGUE.ACTIONS.EDIT_TOOLTIP')"
              type="button"
              variant="ghost"
              color="slate"
              size="md"
              icon="i-lucide-pencil"
              :aria-label="t('CATALOGUE.ACTIONS.EDIT')"
              @click="openDialog"
            />
          </div>
          <p class="mb-0 text-body-main text-n-slate-11">
            {{ t('CATALOGUE.ACTIONS.DISABLED_REASON') }}
          </p>
          <p
            v-if="actionNotice"
            role="status"
            class="mb-0 text-body-main text-n-slate-12"
            data-test="gallery-action-result"
          >
            {{ t(`CATALOGUE.ACTIONS.${actionNotice}`) }}
          </p>
          <h2 class="text-heading-2 text-n-slate-12">
            {{ t('CATALOGUE.ACTIONS.MESSAGES') }}
          </h2>
          <code class="mb-0 text-body-main text-n-slate-11">{{
            componentNames.messages
          }}</code>
          <Banner color="slate">{{ t('CATALOGUE.ACTIONS.INFO') }}</Banner>
          <Banner color="amber">{{ t('CATALOGUE.ACTIONS.WARNING') }}</Banner>
          <Banner
            color="ruby"
            :action-label="t('CATALOGUE.ACTIONS.RETRY')"
            @action="saveAction"
          >
            {{ t('CATALOGUE.ACTIONS.ERROR') }}
          </Banner>
          <Banner color="teal">{{ t('CATALOGUE.ACTIONS.SUCCESS') }}</Banner>
        </div>
      </SectionLayout>
      <SectionLayout
        :title="t('CATALOGUE.ACTIONS.MENU_TITLE')"
        :description="t('CATALOGUE.ACTIONS.MENU_DESCRIPTION')"
        with-border
      >
        <div class="flex max-w-3xl flex-col gap-4">
          <code class="mb-0 text-body-main text-n-slate-11">{{
            componentNames.navigation
          }}</code>
          <div class="flex flex-wrap items-center justify-between gap-4">
            <TabBar
              :tabs="exampleTabs"
              :initial-active-tab="activeExampleTab"
              data-test="gallery-example-tabs"
              @tab-changed="changeExampleTab"
            />
            <div
              v-on-clickaway="() => (menuOpen = false)"
              class="relative"
              @keydown.esc="menuOpen = false"
            >
              <Button
                type="button"
                variant="outline"
                color="slate"
                size="sm"
                icon="i-lucide-chevron-down"
                trailing-icon
                :label="t('CATALOGUE.ACTIONS.MENU')"
                :aria-expanded="menuOpen"
                aria-controls="gallery-actions-menu"
                data-test="gallery-menu-open"
                @click="menuOpen = !menuOpen"
              />
              <DropdownMenu
                v-if="menuOpen"
                id="gallery-actions-menu"
                class="right-0 top-full mt-1"
                :menu-items="menuItems"
                @action="handleMenuAction"
              />
            </div>
          </div>
          <p class="mb-0 text-body-main text-n-slate-11">
            {{
              t(
                activeExampleTab === 0
                  ? 'CATALOGUE.ACTIONS.OVERVIEW_TEXT'
                  : 'CATALOGUE.ACTIONS.HISTORY_TEXT'
              )
            }}
          </p>
          <div class="flex flex-wrap items-center gap-4">
            <p class="mb-0 text-body-main text-n-slate-12">
              {{ t('CATALOGUE.ACTIONS.NAME') }}
              <span data-test="gallery-demo-name">{{ demoName }}</span>
            </p>
            <Button
              type="button"
              variant="solid"
              color="blue"
              size="md"
              :label="t('CATALOGUE.ACTIONS.OPEN_DIALOG')"
              data-test="gallery-dialog-open"
              @click="openDialog"
            />
          </div>
          <p
            v-if="dialogSaved"
            role="status"
            class="mb-0 text-body-main text-n-slate-12"
            data-test="gallery-dialog-result"
          >
            {{ t('CATALOGUE.DIALOG.SUCCESS', { name: demoName }) }}
          </p>
        </div>
      </SectionLayout>
    </div>

    <div v-show="activeGroup === 2" id="gallery-fields" class="min-w-0">
      <SectionLayout
        :title="t('CATALOGUE.FORM.TITLE')"
        :description="t('CATALOGUE.FORM.DESCRIPTION')"
      >
        <div class="grid max-w-3xl grid-cols-1 gap-6 sm:grid-cols-2">
          <div class="flex min-w-0 flex-col gap-4">
            <code class="mb-0 text-body-main text-n-slate-11">{{
              componentNames.text
            }}</code>
            <Input
              id="gallery-name"
              v-model="formName"
              :label="t('CATALOGUE.FORM.NAME')"
              :placeholder="t('CATALOGUE.FORM.NAME_PLACEHOLDER')"
              data-test="gallery-input"
            />
            <Input
              id="gallery-required"
              v-model="requiredName"
              :label="t('CATALOGUE.FORM.REQUIRED_NAME')"
              :message="
                t(
                  requiredName.trim()
                    ? 'CATALOGUE.FORM.VALID'
                    : 'CATALOGUE.FORM.REQUIRED'
                )
              "
              :message-type="requiredName.trim() ? 'success' : 'error'"
              :aria-invalid="!requiredName.trim()"
              data-test="gallery-input-error"
            />
            <Input
              id="gallery-locked"
              model-value="OneLink"
              :label="t('CATALOGUE.FORM.LOCKED')"
              :message="t('CATALOGUE.FORM.LOCKED_REASON')"
              disabled
            />
            <TextArea
              id="gallery-description"
              v-model="notes"
              :label="t('CATALOGUE.FORM.NOTES')"
              :placeholder="t('CATALOGUE.FORM.NOTES_PLACEHOLDER')"
              :max-length="200"
              show-character-count
              auto-height
              data-test="gallery-textarea"
            />
          </div>
          <div class="flex min-w-0 flex-col gap-4">
            <code class="mb-0 text-body-main text-n-slate-11">{{
              componentNames.selection
            }}</code>
            <div class="flex flex-col gap-1">
              <label
                for="gallery-channel"
                class="text-heading-3 text-n-slate-12"
                >{{ t('CATALOGUE.FORM.CHANNEL') }}</label
              >
              <Select
                id="gallery-channel"
                v-model="channel"
                :options="channels"
                data-test="gallery-select"
              />
            </div>
            <div class="flex flex-col gap-1">
              <label
                for="gallery-combobox"
                class="text-heading-3 text-n-slate-12"
                >{{ t('CATALOGUE.FORM.SEARCH_CHANNEL') }}</label
              >
              <ComboBox
                id="gallery-combobox"
                v-model="searchedChannel"
                :options="channels"
                :placeholder="t('CATALOGUE.FORM.CHOOSE')"
                :search-placeholder="t('CATALOGUE.FORM.SEARCH_PLACEHOLDER')"
                :empty-state="t('CATALOGUE.FORM.NO_RESULTS')"
                :aria-label="t('CATALOGUE.FORM.SEARCH_CHANNEL')"
                input-like
                data-test="gallery-combobox"
              />
            </div>
            <div class="flex flex-col gap-1">
              <p class="text-heading-3 text-n-slate-12">
                {{ t('CATALOGUE.FORM.SELECT_MENU') }}
              </p>
              <SelectMenu
                v-model="menuChannel"
                :options="channels"
                :label="menuChannelLabel"
                :trigger-aria-label="t('CATALOGUE.FORM.SELECT_MENU')"
                variant="outline"
                sub-menu-position="bottom"
                sub-menu-align="start"
                data-test="gallery-selectmenu"
              />
              <p role="status" class="mb-0 text-body-main text-n-slate-11">
                {{ t('CATALOGUE.FORM.SELECTED', { value: menuChannelLabel }) }}
              </p>
            </div>
          </div>
        </div>
      </SectionLayout>
      <SectionLayout
        :title="t('CATALOGUE.FORM.CHOICES')"
        description=""
        with-border
      >
        <div class="flex max-w-3xl flex-col gap-4">
          <code class="mb-0 text-body-main text-n-slate-11">{{
            componentNames.choices
          }}</code>
          <div class="flex flex-wrap gap-4">
            <div class="flex items-center gap-2">
              <Checkbox
                id="gallery-notifications"
                v-model="notifications"
                data-test="gallery-checkbox"
              />
              <label
                for="gallery-notifications"
                class="mb-0 text-body-main text-n-slate-12"
                >{{ t('CATALOGUE.FORM.CHECKBOX') }}</label
              >
            </div>
            <div class="flex items-center gap-2">
              <Checkbox id="gallery-checkbox-disabled" disabled />
              <label
                for="gallery-checkbox-disabled"
                class="mb-0 text-body-main text-n-slate-11"
                >{{ t('CATALOGUE.FORM.DISABLED_CHECKBOX') }}</label
              >
            </div>
          </div>
          <fieldset class="flex flex-col gap-3">
            <legend class="text-heading-3 text-n-slate-12">
              {{ t('CATALOGUE.FORM.RADIO') }}
            </legend>
            <div class="flex flex-wrap gap-4">
              <div
                v-for="value in ['standard', 'compact']"
                :key="value"
                class="flex items-center gap-2"
              >
                <Radio
                  :id="`gallery-mode-${value}`"
                  v-model="mode"
                  name="gallery-mode"
                  :value="value"
                  :data-test="`gallery-radio-${value}`"
                />
                <label
                  :for="`gallery-mode-${value}`"
                  class="mb-0 text-body-main text-n-slate-12"
                  >{{ t(`CATALOGUE.FORM.${value.toUpperCase()}`) }}</label
                >
              </div>
            </div>
          </fieldset>
          <h2 class="text-heading-3 text-n-slate-12">
            {{ t('CATALOGUE.FORM.CARD_TITLE') }}
          </h2>
          <div
            class="grid grid-cols-1 gap-4 sm:grid-cols-2"
            role="radiogroup"
            :aria-label="t('CATALOGUE.FORM.CARD_TITLE')"
          >
            <label
              v-for="option in cardOptions"
              :key="option.id"
              :for="`gallery-card-${option.id}`"
            >
              <RadioCard
                :id="`gallery-card-${option.id}`"
                :label="option.label"
                :description="option.description"
                :is-active="cardChoice === option.id"
                :data-test="`gallery-radiocard-${option.id}`"
                @select="cardChoice = option.id"
              />
            </label>
          </div>
        </div>
      </SectionLayout>
    </div>

    <div v-show="activeGroup === 3" id="gallery-layouts" class="min-w-0">
      <SectionLayout
        :title="t('CATALOGUE.LAYOUTS.TITLE')"
        :description="t('CATALOGUE.LAYOUTS.DESCRIPTION')"
      >
        <div class="flex max-w-3xl flex-col gap-6">
          <div class="flex flex-col gap-4">
            <code class="mb-0 text-body-main text-n-slate-11">{{
              componentNames.dependent
            }}</code>
            <SettingsToggleSection
              v-model="dependentEnabled"
              :header="t('CATALOGUE.LAYOUTS.DEPENDENT')"
              :description="t('CATALOGUE.LAYOUTS.DEPENDENT_HELP')"
              data-test="gallery-dependent-setting"
            >
              <template v-if="dependentEnabled" #editor>
                <Input
                  id="gallery-dependent-name"
                  v-model="dependentName"
                  :label="t('CATALOGUE.LAYOUTS.DEPENDENT_FIELD')"
                  :placeholder="t('CATALOGUE.LAYOUTS.DEPENDENT_PLACEHOLDER')"
                  data-test="gallery-dependent-input"
                />
              </template>
            </SettingsToggleSection>
          </div>
          <div class="flex flex-col gap-4">
            <h2 class="text-heading-2 text-n-slate-12">
              {{ t('CATALOGUE.LAYOUTS.TOGGLES') }}
            </h2>
            <code class="mb-0 text-body-main text-n-slate-11">{{
              componentNames.toggles
            }}</code>
            <div
              class="divide-y divide-n-weak rounded-xl outline outline-1 -outline-offset-1 outline-n-weak"
            >
              <div class="flex flex-col gap-1 px-4 py-3">
                <div class="flex items-center justify-between gap-3">
                  <label
                    for="gallery-group-notifications"
                    class="text-heading-3 text-n-slate-12"
                    >{{ t('CATALOGUE.LAYOUTS.NOTIFICATIONS') }}</label
                  >
                  <Switch
                    id="gallery-group-notifications"
                    v-model="notifications"
                    :aria-label="t('CATALOGUE.LAYOUTS.NOTIFICATIONS')"
                  />
                </div>
                <p class="mb-0 text-body-main text-n-slate-11">
                  {{ t('CATALOGUE.LAYOUTS.NOTIFICATIONS_HELP') }}
                </p>
              </div>
              <div class="flex flex-col gap-1 px-4 py-3">
                <div class="flex items-center justify-between gap-3">
                  <label
                    for="gallery-group-weekly"
                    class="text-heading-3 text-n-slate-12"
                    >{{ t('CATALOGUE.LAYOUTS.WEEKLY') }}</label
                  >
                  <Switch
                    id="gallery-group-weekly"
                    v-model="weekly"
                    :aria-label="t('CATALOGUE.LAYOUTS.WEEKLY')"
                  />
                </div>
                <p class="mb-0 text-body-main text-n-slate-11">
                  {{ t('CATALOGUE.LAYOUTS.WEEKLY_HELP') }}
                </p>
              </div>
            </div>
          </div>
          <section
            class="divide-y divide-n-weak rounded-xl bg-n-solid-2 outline outline-1 -outline-offset-1 outline-n-container"
          >
            <header class="px-5 py-4">
              <h2 class="text-heading-2 text-n-slate-12">
                {{ t('CATALOGUE.LAYOUTS.FEATURE') }}
              </h2>
              <p class="mb-0 text-body-main text-n-slate-11">
                {{ t('CATALOGUE.LAYOUTS.FEATURE_HELP') }}
              </p>
            </header>
            <div class="grid gap-5 px-5 py-4">
              <Input
                id="gallery-feature-name"
                v-model="featureName"
                :label="t('CATALOGUE.LAYOUTS.FEATURE_NAME')"
              />
              <div class="flex flex-col gap-1">
                <label
                  for="gallery-feature-channel"
                  class="text-heading-3 text-n-slate-12"
                  >{{ t('CATALOGUE.LAYOUTS.FEATURE_CHANNEL') }}</label
                >
                <Select
                  id="gallery-feature-channel"
                  v-model="featureChannel"
                  :options="channels"
                />
              </div>
            </div>
          </section>
          <div class="flex flex-col gap-4">
            <h2 class="text-heading-2 text-n-slate-12">
              {{ t('CATALOGUE.LAYOUTS.COMPACT') }}
            </h2>
            <div
              class="grid grid-cols-1 gap-4 rounded-xl bg-n-solid-1 p-4 outline outline-1 -outline-offset-1 outline-n-weak sm:grid-cols-2"
            >
              <Input
                id="gallery-prefix"
                v-model="prefix"
                :label="t('CATALOGUE.LAYOUTS.PREFIX')"
              />
              <Input
                id="gallery-suffix"
                v-model="suffix"
                :label="t('CATALOGUE.LAYOUTS.SUFFIX')"
              />
            </div>
          </div>
          <div class="flex flex-col gap-4">
            <h2 class="text-heading-2 text-n-slate-12">
              {{ t('CATALOGUE.LAYOUTS.OBJECTS') }}
            </h2>
            <code class="mb-0 text-body-main text-n-slate-11">{{
              componentNames.objects
            }}</code>
            <CardLayout>
              <h3 class="text-heading-3 text-n-slate-12">
                {{ t('CATALOGUE.LAYOUTS.OBJECT_NAME') }}
              </h3>
              <p class="mb-0 text-body-main text-n-slate-11">
                {{ t('CATALOGUE.LAYOUTS.OBJECT_HELP') }}
              </p>
              <div class="flex flex-wrap items-center justify-between gap-4">
                <DsStatusDot
                  status="good"
                  :label="t('CATALOGUE.LAYOUTS.ACTIVE')"
                />
                <Button
                  type="button"
                  variant="outline"
                  color="slate"
                  size="md"
                  :label="t('CATALOGUE.LAYOUTS.OPEN')"
                  @click="openDialog"
                />
              </div>
            </CardLayout>
          </div>
        </div>
      </SectionLayout>
    </div>

    <div v-show="activeGroup === 4" id="gallery-data" class="min-w-0">
      <SectionLayout
        :title="t('CATALOGUE.DATA.TITLE')"
        :description="t('CATALOGUE.DATA.DESCRIPTION')"
      >
        <div class="flex min-w-0 flex-col gap-6">
          <div class="flex flex-wrap items-center justify-between gap-4">
            <div class="flex flex-col gap-1">
              <p class="text-heading-3 text-n-slate-12">
                {{ t('CATALOGUE.DATA.STATE') }}
              </p>
              <div class="flex flex-wrap gap-2">
                <Button
                  v-for="state in reportStates"
                  :key="state"
                  type="button"
                  size="sm"
                  :variant="reportState === state ? 'solid' : 'outline'"
                  :color="reportState === state ? 'blue' : 'slate'"
                  :label="t(`CATALOGUE.DATA.${state.toUpperCase()}`)"
                  :aria-pressed="reportState === state"
                  :data-test="`gallery-state-${state}`"
                  @click="chooseReportState(state)"
                />
              </div>
            </div>
            <div class="flex flex-col gap-1">
              <p class="text-heading-3 text-n-slate-12">
                {{ t('CATALOGUE.DATA.PERIOD') }}
              </p>
              <DsSegmented
                v-model="period"
                :options="periodOptions"
                :label="t('CATALOGUE.DATA.PERIOD')"
                data-test="gallery-period"
              />
            </div>
          </div>
          <code class="mb-0 text-body-main text-n-slate-11">{{
            componentNames.statistics
          }}</code>
          <DsStatGroup :items="stats" />
          <code class="mb-0 text-body-main text-n-slate-11">{{
            componentNames.table
          }}</code>
          <section
            class="min-w-0 rounded-xl bg-n-solid-2 px-6 py-5 shadow outline outline-1 -outline-offset-1 outline-n-container"
            :aria-label="t('CATALOGUE.DATA.REPORT')"
            data-test="gallery-report"
          >
            <h2 class="mb-4 text-heading-2 text-n-slate-12">
              {{ t('CATALOGUE.DATA.REPORT') }}
            </h2>
            <template v-if="reportState === 'filled'">
              <DsTable
                :columns="reportColumns"
                :rows="pageRows"
                :caption="t('CATALOGUE.DATA.REPORT')"
                row-key="id"
              >
                <template #cell-load="{ row }">
                  <DsMeter
                    :value="row.load"
                    tone="auto"
                    :label="`${row.name}: ${t('CATALOGUE.DATA.LOAD')}`"
                  />
                </template>
                <template #cell-status="{ row }">
                  <DsStatusDot
                    :status="row.status"
                    :label="statusLabel(row.status)"
                  />
                </template>
              </DsTable>
              <div
                class="relative min-w-0 overflow-x-auto"
                :aria-label="t('CATALOGUE.DATA.PAGINATION')"
              >
                <PaginationFooter
                  v-model:current-page="currentPage"
                  :total-items="reportRows.length"
                  :items-per-page="3"
                  data-test="gallery-pagination"
                />
              </div>
            </template>
            <DsState
              v-else
              :state="reportState"
              :title="t(`CATALOGUE.DATA.${reportState.toUpperCase()}_TITLE`)"
              :description="
                t(`CATALOGUE.DATA.${reportState.toUpperCase()}_HELP`)
              "
              compact
              @retry="retryReport"
            />
          </section>
          <code class="mb-0 text-body-main text-n-slate-11">{{
            componentNames.charts
          }}</code>
          <div class="grid min-w-0 grid-cols-1 gap-6 lg:grid-cols-2">
            <DsChartFrame
              :title="t('CATALOGUE.DATA.CHART')"
              :subtitle="t('CATALOGUE.DATA.CHART_HELP')"
              :labels="chartLabels"
              :series="chartSeries"
              :category-label="t('CATALOGUE.DATA.CHART_CATEGORY')"
              :loading="reportState === 'loading'"
              :error="reportState === 'error'"
              data-test="gallery-line-chart"
              @retry="retryReport"
            />
            <DsChartFrame
              kind="bars"
              :title="t('CATALOGUE.DATA.FUNNEL')"
              :subtitle="t('CATALOGUE.DATA.FUNNEL_HELP')"
              :labels="reportState === 'filled' ? stageLabels : []"
              :series="stageSeries"
              :category-label="t('CATALOGUE.DATA.STAGE')"
              :loading="reportState === 'loading'"
              :error="reportState === 'error'"
              data-test="gallery-bar-chart"
              @retry="retryReport"
            />
          </div>
        </div>
      </SectionLayout>
    </div>

    <p class="mb-0 text-body-main text-n-slate-11">
      {{ t('CATALOGUE.LOCAL_ONLY') }}
    </p>
    <Dialog
      ref="dialog"
      type="edit"
      :title="t('CATALOGUE.DIALOG.TITLE')"
      :description="t('CATALOGUE.DIALOG.DESCRIPTION')"
      :confirm-button-label="t('CATALOGUE.DIALOG.SAVE')"
      :cancel-button-label="t('CATALOGUE.DIALOG.CANCEL')"
      :is-loading="dialogSaving"
      :disable-confirm-button="dialogSaving || !editName.trim()"
      @confirm="saveDialog"
      @close="closeDialog"
    >
      <div class="flex flex-col gap-4" data-test="gallery-dialog-content">
        <Input
          id="gallery-dialog-name"
          v-model="editName"
          :label="t('CATALOGUE.DIALOG.NAME')"
          :disabled="dialogSaving"
          data-test="gallery-dialog-name"
        />
        <p
          v-if="dialogSaving"
          role="status"
          class="mb-0 text-body-main text-n-slate-11"
        >
          {{ t('CATALOGUE.DIALOG.SAVING') }}
        </p>
      </div>
    </Dialog>
  </main>
</template>
