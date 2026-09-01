<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Draggable from 'vuedraggable';
import { useAlert } from 'dashboard/composables';
import { useAccount } from 'dashboard/composables/useAccount';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import {
  SIDEBAR_ORDER_UI_SETTINGS_KEY,
  SIDEBAR_VISIBILITY_CURRENT_VERSION,
  SIDEBAR_VISIBILITY_ITEMS,
  SIDEBAR_VISIBILITY_UI_SETTINGS_KEY,
  SIDEBAR_VISIBILITY_VERSION_UI_SETTINGS_KEY,
  buildSidebarVisibilityState,
  getSidebarHiddenItems,
  getSidebarHiddenItemsFromState,
  getSidebarItemOrder,
} from 'dashboard/components-next/sidebar/sidebarVisibility';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';

const { t } = useI18n();
const { currentAccount, updateAccount } = useAccount();

const visibilityDraft = ref({});
const sidebarItemsDraft = ref([]);

const savedHiddenItems = computed(() =>
  getSidebarHiddenItems(currentAccount.value?.settings || {})
);
const draftHiddenItems = computed(() =>
  getSidebarHiddenItemsFromState(visibilityDraft.value)
);
const savedItemOrder = computed(() =>
  getSidebarItemOrder(currentAccount.value?.settings || {})
);
const draftItemOrder = computed(() =>
  sidebarItemsDraft.value.map(item => item.key)
);
const hasChanges = computed(
  () =>
    JSON.stringify(savedHiddenItems.value) !==
      JSON.stringify(draftHiddenItems.value) ||
    JSON.stringify(savedItemOrder.value) !==
      JSON.stringify(draftItemOrder.value)
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

const moveSidebarItem = (index, offset) => {
  const targetIndex = index + offset;
  if (targetIndex < 0 || targetIndex >= sidebarItemsDraft.value.length) return;

  const nextItems = [...sidebarItemsDraft.value];
  const [movedItem] = nextItems.splice(index, 1);
  nextItems.splice(targetIndex, 0, movedItem);
  sidebarItemsDraft.value = nextItems;
};

const saveSidebarVisibility = async () => {
  try {
    await updateAccount({
      [SIDEBAR_ORDER_UI_SETTINGS_KEY]: draftItemOrder.value,
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
    const itemsByKey = new Map(
      SIDEBAR_VISIBILITY_ITEMS.map(sidebarItem => [
        sidebarItem.key,
        sidebarItem,
      ])
    );
    sidebarItemsDraft.value = getSidebarItemOrder(value || {}).map(itemKey =>
      itemsByKey.get(itemKey)
    );
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
        <p class="m-0 text-sm text-n-slate-11">
          {{ t('GENERAL_SETTINGS.SIDEBAR_VISIBILITY.ORDER_HINT') }}
        </p>
        <Draggable
          v-model="sidebarItemsDraft"
          item-key="key"
          handle=".sidebar-order-drag-handle"
          animation="200"
          ghost-class="opacity-50"
          class="grid grid-cols-1 gap-2 w-full"
        >
          <template #item="{ element: item, index }">
            <div class="rounded-xl border border-n-weak overflow-hidden">
              <div
                class="flex items-center gap-2 p-3 hover:bg-n-alpha-1 transition-colors"
              >
                <button
                  type="button"
                  data-test="sidebar-order-drag-handle"
                  class="sidebar-order-drag-handle inline-flex size-7 shrink-0 cursor-grab items-center justify-center rounded-md text-n-slate-9 hover:bg-n-alpha-2 hover:text-n-slate-12 active:cursor-grabbing"
                  :title="t('GENERAL_SETTINGS.SIDEBAR_VISIBILITY.DRAG')"
                  :aria-label="t('GENERAL_SETTINGS.SIDEBAR_VISIBILITY.DRAG')"
                >
                  <span class="i-lucide-grip-vertical size-4" />
                </button>
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
                <div class="flex shrink-0 items-center gap-1">
                  <button
                    type="button"
                    class="inline-flex size-7 items-center justify-center rounded-md text-n-slate-10 hover:bg-n-alpha-2 hover:text-n-slate-12 disabled:pointer-events-none disabled:opacity-30"
                    data-test="sidebar-order-up"
                    :disabled="index === 0"
                    :title="t('GENERAL_SETTINGS.SIDEBAR_VISIBILITY.MOVE_UP')"
                    :aria-label="
                      t('GENERAL_SETTINGS.SIDEBAR_VISIBILITY.MOVE_UP')
                    "
                    @click="moveSidebarItem(index, -1)"
                  >
                    <span class="i-lucide-chevron-up size-4" />
                  </button>
                  <button
                    type="button"
                    class="inline-flex size-7 items-center justify-center rounded-md text-n-slate-10 hover:bg-n-alpha-2 hover:text-n-slate-12 disabled:pointer-events-none disabled:opacity-30"
                    data-test="sidebar-order-down"
                    :disabled="index === sidebarItemsDraft.length - 1"
                    :title="t('GENERAL_SETTINGS.SIDEBAR_VISIBILITY.MOVE_DOWN')"
                    :aria-label="
                      t('GENERAL_SETTINGS.SIDEBAR_VISIBILITY.MOVE_DOWN')
                    "
                    @click="moveSidebarItem(index, 1)"
                  >
                    <span class="i-lucide-chevron-down size-4" />
                  </button>
                </div>
              </div>
            </div>
          </template>
        </Draggable>

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
