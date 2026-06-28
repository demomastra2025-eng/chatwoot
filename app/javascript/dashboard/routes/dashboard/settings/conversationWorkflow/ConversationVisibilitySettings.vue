<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useAccount } from 'dashboard/composables/useAccount';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import Button from 'next/button/Button.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';
import {
  CONVERSATION_APPOINTMENT_STATUSES_VISIBILITY_KEY,
  CONVERSATION_APPOINTMENT_STATUS_VISIBILITY_KEYS,
  CONVERSATION_SIDEBAR_VISIBILITY_ITEMS,
  SIDEBAR_VISIBILITY_CURRENT_VERSION,
  SIDEBAR_VISIBILITY_UI_SETTINGS_KEY,
  SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY,
  buildSidebarVisibilityState,
  getConversationSidebarHiddenItems,
  getConversationSidebarHiddenItemsFromState,
  getSidebarHiddenItems,
} from 'dashboard/components-next/sidebar/sidebarVisibility';

const CONVERSATION_VISIBILITY_GROUPS = Object.freeze([
  {
    key: 'assignee',
    labelKey: 'CONVERSATION_WORKFLOW.VISIBILITY.SECTIONS.ASSIGNEE',
    descriptionKey: 'CONVERSATION_WORKFLOW.VISIBILITY.DESCRIPTIONS.ASSIGNEE',
    itemKeys: [
      'Conversation:Assignee:all',
      'Conversation:Assignee:me',
      'Conversation:Assignee:unassigned',
    ],
  },
  {
    key: 'statuses',
    labelKey: 'CONVERSATION_WORKFLOW.VISIBILITY.SECTIONS.STATUSES',
    descriptionKey: 'CONVERSATION_WORKFLOW.VISIBILITY.DESCRIPTIONS.STATUSES',
    itemKeys: [
      'Conversation:Statuses',
      'Conversation:Pending',
      'Conversation:Open',
      'Conversation:Snoozed',
      'Conversation:Resolved',
    ],
  },
  {
    key: 'pipeline',
    labelKey: 'CONVERSATION_WORKFLOW.VISIBILITY.SECTIONS.PIPELINE',
    descriptionKey: 'CONVERSATION_WORKFLOW.VISIBILITY.DESCRIPTIONS.PIPELINE',
    itemKeys: ['Conversation:Pipelines'],
  },
  {
    key: 'appointments',
    labelKey: 'CONVERSATION_WORKFLOW.VISIBILITY.SECTIONS.APPOINTMENTS',
    descriptionKey:
      'CONVERSATION_WORKFLOW.VISIBILITY.DESCRIPTIONS.APPOINTMENTS',
    itemKeys: [
      CONVERSATION_APPOINTMENT_STATUSES_VISIBILITY_KEY,
      CONVERSATION_APPOINTMENT_STATUS_VISIBILITY_KEYS.scheduled,
      CONVERSATION_APPOINTMENT_STATUS_VISIBILITY_KEYS.confirmed,
      CONVERSATION_APPOINTMENT_STATUS_VISIBILITY_KEYS.completed,
      CONVERSATION_APPOINTMENT_STATUS_VISIBILITY_KEYS.cancelled,
      CONVERSATION_APPOINTMENT_STATUS_VISIBILITY_KEYS.no_show,
    ],
  },
  {
    key: 'organization',
    labelKey: 'CONVERSATION_WORKFLOW.VISIBILITY.SECTIONS.ORGANIZATION',
    descriptionKey:
      'CONVERSATION_WORKFLOW.VISIBILITY.DESCRIPTIONS.ORGANIZATION',
    itemKeys: [
      'Conversation:Folders',
      'Conversation:Teams',
      'Conversation:Labels',
    ],
  },
]);

const { t } = useI18n();
const { currentAccount, updateAccount } = useAccount();

const visibilityDraft = ref({});

const conversationVisibilityKeys = computed(
  () => new Set(CONVERSATION_SIDEBAR_VISIBILITY_ITEMS.map(item => item.key))
);

const conversationVisibilityItemsByKey = computed(
  () =>
    new Map(CONVERSATION_SIDEBAR_VISIBILITY_ITEMS.map(item => [item.key, item]))
);

const savedConversationHiddenItems = computed(() =>
  getConversationSidebarHiddenItems(currentAccount.value?.settings || {})
);

const draftConversationHiddenItems = computed(() =>
  getConversationSidebarHiddenItemsFromState(visibilityDraft.value)
);

const hasChanges = computed(
  () =>
    JSON.stringify(savedConversationHiddenItems.value) !==
    JSON.stringify(draftConversationHiddenItems.value)
);

const groupedVisibilityItems = computed(() =>
  CONVERSATION_VISIBILITY_GROUPS.map(group => ({
    ...group,
    items: group.itemKeys
      .map(key => conversationVisibilityItemsByKey.value.get(key))
      .filter(Boolean),
  }))
);

const switchId = itemKey =>
  `conversation-visibility-${itemKey
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')}`;

const visibilityLabel = item =>
  item.labelKey
    ? // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys -- visibility items use a fixed internal whitelist of label keys
      t(item.labelKey)
    : item.key;

const groupLabel = group =>
  // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys -- visibility groups use a fixed internal whitelist of label keys
  t(group.labelKey);

const groupDescription = group =>
  // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys -- visibility groups use a fixed internal whitelist of description keys
  t(group.descriptionKey);

const isStatusChild = item =>
  [
    'Conversation:Pending',
    'Conversation:Open',
    'Conversation:Snoozed',
    'Conversation:Resolved',
  ].includes(item.key);

const isStatusChildDisabled = item =>
  isStatusChild(item) &&
  visibilityDraft.value['Conversation:Statuses'] === false;

const isAppointmentStatusChild = item =>
  Object.values(CONVERSATION_APPOINTMENT_STATUS_VISIBILITY_KEYS).includes(
    item.key
  );

const isAppointmentStatusChildDisabled = item =>
  isAppointmentStatusChild(item) &&
  visibilityDraft.value[CONVERSATION_APPOINTMENT_STATUSES_VISIBILITY_KEY] ===
    false;

const isChildDisabled = item =>
  isStatusChildDisabled(item) || isAppointmentStatusChildDisabled(item);

const toggleVisibility = item => {
  if (isChildDisabled(item)) return;
  visibilityDraft.value[item.key] = !visibilityDraft.value[item.key];
};

const saveVisibility = async () => {
  const nonConversationHiddenItems = getSidebarHiddenItems(
    currentAccount.value?.settings || {}
  ).filter(key => !conversationVisibilityKeys.value.has(key));

  try {
    await updateAccount({
      [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: [
        ...nonConversationHiddenItems,
        ...draftConversationHiddenItems.value,
      ],
      [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
        SIDEBAR_VISIBILITY_CURRENT_VERSION,
    });

    useAlert(t('CONVERSATION_WORKFLOW.VISIBILITY.SAVE.SUCCESS'));
  } catch {
    useAlert(t('GENERAL_SETTINGS.UPDATE.ERROR'));
  }
};

watch(
  () => currentAccount.value?.settings,
  value => {
    visibilityDraft.value = buildSidebarVisibilityState(value || {});
  },
  { immediate: true }
);
</script>

<template>
  <SettingsLayout :no-records-found="false" class="gap-8">
    <template #header>
      <BaseSettingsHeader
        :title="$t('CONVERSATION_WORKFLOW.VISIBILITY.HEADER.TITLE')"
        :description="$t('CONVERSATION_WORKFLOW.VISIBILITY.HEADER.DESCRIPTION')"
        feature-name="conversation-visibility"
      />
    </template>

    <template #body>
      <div class="flex flex-col gap-5 mt-4">
        <section
          v-for="group in groupedVisibilityItems"
          :key="group.key"
          class="flex flex-col gap-3 border-b border-n-weak pb-5 last:border-b-0 last:pb-0"
        >
          <div>
            <h3 class="text-sm font-medium text-n-slate-12">
              {{ groupLabel(group) }}
            </h3>
            <p class="text-sm text-n-slate-11">
              {{ groupDescription(group) }}
            </p>
          </div>

          <div class="grid grid-cols-1 gap-2">
            <div
              v-for="item in group.items"
              :key="item.key"
              class="flex cursor-pointer items-center justify-between gap-3 rounded-lg border border-n-weak px-3 py-2 transition-colors"
              :class="
                isChildDisabled(item) ? 'opacity-60' : 'hover:bg-n-alpha-1'
              "
              @click="toggleVisibility(item)"
            >
              <span class="min-w-0 text-sm text-n-slate-12">
                {{ visibilityLabel(item) }}
              </span>
              <Switch
                :id="switchId(item.key)"
                v-model="visibilityDraft[item.key]"
                :disabled="isChildDisabled(item)"
                @click.stop
              />
            </div>
          </div>
        </section>

        <div class="flex justify-end">
          <Button
            :label="t('CONVERSATION_WORKFLOW.VISIBILITY.SAVE.BUTTON')"
            color="slate"
            variant="outline"
            size="sm"
            :disabled="!hasChanges"
            @click="saveVisibility"
          />
        </div>
      </div>
    </template>
  </SettingsLayout>
</template>
