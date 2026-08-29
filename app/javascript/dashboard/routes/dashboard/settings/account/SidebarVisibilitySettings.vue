<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useAccount } from 'dashboard/composables/useAccount';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import {
  SIDEBAR_VISIBILITY_CURRENT_VERSION,
  SIDEBAR_VISIBILITY_ITEMS,
  SIDEBAR_VISIBILITY_UI_SETTINGS_KEY,
  SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY,
  buildSidebarVisibilityState,
  getSidebarHiddenItems,
  getSidebarHiddenItemsFromState,
} from 'dashboard/components-next/sidebar/sidebarVisibility';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';

const { t } = useI18n();
const { currentAccount, updateAccount } = useAccount();

const visibilityDraft = ref({});

const savedHiddenItems = computed(() =>
  getSidebarHiddenItems(currentAccount.value?.settings || {})
);
const draftHiddenItems = computed(() =>
  getSidebarHiddenItemsFromState(visibilityDraft.value)
);
const hasChanges = computed(
  () =>
    JSON.stringify(savedHiddenItems.value) !==
    JSON.stringify(draftHiddenItems.value)
);

const checkboxId = itemKey =>
  `workspace-sidebar-visibility-${itemKey
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')}`;

const sidebarItemLabel = item =>
  item.labelKey
    ? // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys -- sidebar items use a fixed internal whitelist of label keys
      t(item.labelKey)
    : item.key;

const saveSidebarVisibility = async () => {
  try {
    await updateAccount({
      [SIDEBAR_VISIBILITY_UI_SETTINGS_KEY]: draftHiddenItems.value,
      [SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY]:
        SIDEBAR_VISIBILITY_CURRENT_VERSION,
    });
    useAlert(t('GENERAL_SETTINGS.SIDEBAR_VISIBILITY.UPDATE_SUCCESS'));
  } catch {
    useAlert(t('GENERAL_SETTINGS.SIDEBAR_VISIBILITY.UPDATE_ERROR'));
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
        :title="$t('GENERAL_SETTINGS.SIDEBAR_VISIBILITY.TITLE')"
        :description="$t('GENERAL_SETTINGS.SIDEBAR_VISIBILITY.DESCRIPTION')"
        feature-name="workspace-sidebar-visibility"
      />
    </template>

    <template #body>
      <div class="flex flex-col gap-4 mt-4">
        <div class="grid grid-cols-1 gap-2 w-full">
          <div
            v-for="item in SIDEBAR_VISIBILITY_ITEMS"
            :key="item.key"
            class="rounded-xl border border-n-weak overflow-hidden"
          >
            <div
              class="flex items-start gap-3 p-3 hover:bg-n-alpha-1 transition-colors"
            >
              <label
                v-if="item.configurable !== false"
                :for="checkboxId(item.key)"
                class="flex flex-1 gap-3 items-start cursor-pointer"
              >
                <Checkbox
                  :id="checkboxId(item.key)"
                  v-model="visibilityDraft[item.key]"
                  class="mt-0.5 shrink-0"
                />
                <span class="text-sm text-n-slate-12 leading-5 font-medium">
                  {{ sidebarItemLabel(item) }}
                </span>
              </label>
              <div v-else class="flex flex-1 gap-3 items-start">
                <span class="text-sm text-n-slate-12 leading-5 font-medium">
                  {{ sidebarItemLabel(item) }}
                </span>
              </div>
            </div>
          </div>
        </div>

        <div class="flex justify-end w-full">
          <Button
            :label="t('GENERAL_SETTINGS.SIDEBAR_VISIBILITY.SAVE')"
            color="slate"
            variant="outline"
            size="sm"
            :disabled="!hasChanges"
            @click="saveSidebarVisibility"
          />
        </div>
      </div>
    </template>
  </SettingsLayout>
</template>
