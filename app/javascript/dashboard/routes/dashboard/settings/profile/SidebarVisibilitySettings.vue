<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useUISettings } from 'dashboard/composables/useUISettings';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import {
  SIDEBAR_VISIBILITY_ITEMS,
  SIDEBAR_VISIBILITY_UI_SETTINGS_KEY,
  buildSidebarVisibilityState,
  getSidebarHiddenItems,
  getSidebarHiddenItemsFromState,
} from 'dashboard/components-next/sidebar/sidebarVisibility';

const { t } = useI18n();
const { uiSettings, updateUISettings } = useUISettings();

const visibilityDraft = ref({});

watch(
  uiSettings,
  value => {
    visibilityDraft.value = buildSidebarVisibilityState(value);
  },
  { immediate: true }
);

const savedHiddenItems = computed(() =>
  getSidebarHiddenItems(uiSettings.value)
);
const draftHiddenItems = computed(() =>
  getSidebarHiddenItemsFromState(visibilityDraft.value)
);

const sidebarItemLabels = computed(() => ({
  Inbox: t('SIDEBAR.INBOX'),
  Conversation: t('SIDEBAR.CONVERSATIONS'),
  Captain: t('SIDEBAR.CAPTAIN'),
  Contacts: t('SIDEBAR.CONTACTS'),
  Companies: t('SIDEBAR.COMPANIES'),
  CRM: t('SIDEBAR.PIPELINES'),
  'CRM Tasks': t('SIDEBAR.CRM_TASKS'),
  Scheduling: t('SIDEBAR.SCHEDULING'),
  Reports: t('SIDEBAR.REPORTS'),
  Campaigns: t('SIDEBAR.CAMPAIGNS'),
  Portals: t('SIDEBAR.HELP_CENTER.TITLE'),
  Settings: t('SIDEBAR.SETTINGS'),
}));

const hasChanges = computed(
  () =>
    JSON.stringify(savedHiddenItems.value) !==
    JSON.stringify(draftHiddenItems.value)
);

const checkboxId = itemName =>
  `sidebar-visibility-${itemName.toLowerCase().replace(/\s+/g, '-')}`;

const sidebarItemLabel = itemName =>
  sidebarItemLabels.value[itemName] || itemName;

const saveSidebarVisibility = () => {
  updateUISettings({
    [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: draftHiddenItems.value,
  });

  useAlert(
    t(
      'PROFILE_SETTINGS.FORM.INTERFACE_SECTION.SIDEBAR_VISIBILITY.UPDATE_SUCCESS'
    )
  );
};
</script>

<template>
  <div class="flex flex-col gap-4 w-full">
    <div>
      <label class="text-n-gray-12 font-medium leading-6 text-sm">
        {{
          $t('PROFILE_SETTINGS.FORM.INTERFACE_SECTION.SIDEBAR_VISIBILITY.TITLE')
        }}
      </label>
      <p class="text-n-gray-11">
        {{
          $t('PROFILE_SETTINGS.FORM.INTERFACE_SECTION.SIDEBAR_VISIBILITY.NOTE')
        }}
      </p>
    </div>

    <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 w-full">
      <label
        v-for="item in SIDEBAR_VISIBILITY_ITEMS"
        :key="item.name"
        :for="checkboxId(item.name)"
        class="flex gap-3 items-start p-3 rounded-xl border border-n-weak cursor-pointer transition-colors hover:bg-n-alpha-1"
      >
        <Checkbox
          :id="checkboxId(item.name)"
          v-model="visibilityDraft[item.name]"
          class="mt-0.5 shrink-0"
        />
        <span class="text-sm text-n-slate-12 leading-5">
          {{ sidebarItemLabel(item.name) }}
        </span>
      </label>
    </div>

    <div class="flex justify-end w-full">
      <Button
        :label="
          t('PROFILE_SETTINGS.FORM.INTERFACE_SECTION.SIDEBAR_VISIBILITY.SAVE')
        "
        color="slate"
        variant="outline"
        size="sm"
        :disabled="!hasChanges"
        @click="saveSidebarVisibility"
      />
    </div>
  </div>
</template>
