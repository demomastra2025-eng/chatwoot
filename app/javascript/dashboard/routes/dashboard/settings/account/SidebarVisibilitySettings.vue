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
const expandedSections = ref({});

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

const isExpanded = item => expandedSections.value[item.key] === true;

const toggleSection = item => {
  if (!item.children?.length) return;

  expandedSections.value = {
    ...expandedSections.value,
    [item.key]: !isExpanded(item),
  };
};

const isDisabledByAncestors = ancestors =>
  ancestors.some(
    ancestor =>
      ancestor.configurable !== false &&
      visibilityDraft.value[ancestor.key] === false
  );

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
        <p class="text-sm text-n-slate-11">
          {{ $t('GENERAL_SETTINGS.SIDEBAR_VISIBILITY.NOTE') }}
        </p>

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
              <button
                v-if="item.children?.length"
                type="button"
                class="flex items-center justify-center size-7 rounded-lg text-n-slate-11 hover:bg-n-alpha-2 transition-colors"
                :aria-label="sidebarItemLabel(item)"
                :aria-expanded="isExpanded(item)"
                @click="toggleSection(item)"
              >
                <span
                  class="i-lucide-chevron-down size-4 transition-transform"
                  :class="{ 'rotate-180': isExpanded(item) }"
                />
              </button>
            </div>
            <div
              v-show="item.children?.length"
              class="border-t border-n-weak bg-n-alpha-1/40"
              :class="{ hidden: !isExpanded(item) }"
            >
              <div
                v-for="child in item.children"
                :key="child.key"
                class="border-b border-n-weak last:border-b-0"
              >
                <label
                  :for="checkboxId(child.key)"
                  class="flex gap-3 items-start p-3 pl-8 cursor-pointer transition-colors hover:bg-n-alpha-1"
                  :class="{
                    'opacity-60': isDisabledByAncestors([item]),
                  }"
                >
                  <Checkbox
                    :id="checkboxId(child.key)"
                    v-model="visibilityDraft[child.key]"
                    :disabled="isDisabledByAncestors([item])"
                    class="mt-0.5 shrink-0"
                  />
                  <span class="text-sm text-n-slate-11 leading-5">
                    {{ sidebarItemLabel(child) }}
                  </span>
                </label>

                <div
                  v-if="child.children?.length"
                  class="border-t border-n-weak bg-n-alpha-1/40"
                >
                  <label
                    v-for="grandchild in child.children"
                    :key="grandchild.key"
                    :for="checkboxId(grandchild.key)"
                    class="flex gap-3 items-start p-3 pl-14 cursor-pointer transition-colors hover:bg-n-alpha-1"
                    :class="{
                      'opacity-60': isDisabledByAncestors([item, child]),
                    }"
                  >
                    <Checkbox
                      :id="checkboxId(grandchild.key)"
                      v-model="visibilityDraft[grandchild.key]"
                      :disabled="isDisabledByAncestors([item, child])"
                      class="mt-0.5 shrink-0"
                    />
                    <span class="text-sm text-n-slate-11 leading-5">
                      {{ sidebarItemLabel(grandchild) }}
                    </span>
                  </label>
                </div>
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
