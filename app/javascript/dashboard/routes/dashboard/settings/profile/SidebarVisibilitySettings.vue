<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useAccount } from 'dashboard/composables/useAccount';
import { useUISettings } from 'dashboard/composables/useUISettings';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import {
  PERSONAL_SIDEBAR_VISIBILITY_ITEMS,
  SIDEBAR_VISIBILITY_CURRENT_VERSION,
  buildSidebarVisibilityState,
  buildAccountScopedSidebarUISettings,
  getAccountScopedSidebarHiddenItems,
  getSidebarHiddenItemsFromState,
} from 'dashboard/components-next/sidebar/sidebarVisibility';

const { t } = useI18n();
const { uiSettings, updateUISettings } = useUISettings();
const { accountId } = useAccount();

const visibilityDraft = ref({});
const expandedSections = ref({});

watch(
  [uiSettings, accountId],
  ([value, currentAccountId]) => {
    visibilityDraft.value = buildSidebarVisibilityState({
      dashboard_sidebar_hidden_items: getAccountScopedSidebarHiddenItems(
        value,
        currentAccountId
      ),
      dashboard_sidebar_hidden_items_version:
        SIDEBAR_VISIBILITY_CURRENT_VERSION,
    });
  },
  { immediate: true }
);

const savedHiddenItems = computed(() =>
  getAccountScopedSidebarHiddenItems(uiSettings.value, accountId.value)
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
  `sidebar-visibility-${itemKey.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`;

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

const saveSidebarVisibility = () => {
  updateUISettings(
    buildAccountScopedSidebarUISettings({
      accountId: accountId.value,
      hiddenItems: draftHiddenItems.value,
      uiSettings: uiSettings.value,
    })
  );

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

    <div class="grid grid-cols-1 gap-2 w-full">
      <div
        v-for="item in PERSONAL_SIDEBAR_VISIBILITY_ITEMS"
        :key="item.key"
        class="rounded-xl border border-n-weak overflow-hidden"
      >
        <div
          class="flex items-start gap-3 p-3 hover:bg-n-alpha-1 transition-colors"
        >
          <label
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
          <button
            v-if="item.children?.length"
            type="button"
            class="flex items-center justify-center size-7 rounded-lg text-n-slate-11 hover:bg-n-alpha-2 transition-colors"
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
          <label
            v-for="child in item.children"
            :key="child.key"
            :for="checkboxId(child.key)"
            class="flex gap-3 items-start p-3 pl-8 cursor-pointer transition-colors hover:bg-n-alpha-1"
          >
            <Checkbox
              :id="checkboxId(child.key)"
              v-model="visibilityDraft[child.key]"
              class="mt-0.5 shrink-0"
            />
            <span class="text-sm text-n-slate-11 leading-5">
              {{ sidebarItemLabel(child) }}
            </span>
          </label>
        </div>
      </div>
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
