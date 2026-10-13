<script setup>
import { defineModel, computed, ref, watch, onBeforeUnmount } from 'vue';
import { useI18n } from 'vue-i18n';
import { picoSearch } from '@scmmishra/pico-search';
import Icon from 'next/icon/Icon.vue';
import Button from 'next/button/Button.vue';
import DropdownContainer from 'next/dropdown-menu/base/DropdownContainer.vue';
import DropdownSection from 'next/dropdown-menu/base/DropdownSection.vue';
import DropdownBody from 'next/dropdown-menu/base/DropdownBody.vue';
import DropdownItem from 'next/dropdown-menu/base/DropdownItem.vue';

const {
  options,
  maxChips,
  dropdownMaxHeight,
  dropdownPosition,
  searchable,
  fetchOptions,
  searchPlaceholder,
} = defineProps({
  options: {
    type: Array,
    required: true,
  },
  // Adds a search box above the options (long lists such as cabinets).
  searchable: {
    type: Boolean,
    default: false,
  },
  // Server-side search for lists too long to load (contacts):
  // `(query, page) => Promise<{ options, hasMore }>`. The list then shows what
  // the server answers while the user types instead of filtering `options`
  // here; `options` only names the chips of already selected items.
  fetchOptions: {
    type: Function,
    default: null,
  },
  searchPlaceholder: {
    type: String,
    default: '',
  },
  maxChips: {
    type: Number,
    default: 3,
  },
  dropdownMaxHeight: {
    type: String,
    default: 'max-h-80',
  },
  dropdownPosition: {
    type: String,
    default: '',
  },
});

// How long to wait after the last keystroke before asking the server.
const SEARCH_DEBOUNCE_MS = 300;

const { t } = useI18n();
const selected = defineModel({
  type: [Array, String],
  required: true,
});

const searchTerm = ref('');
const isRemote = computed(() => typeof fetchOptions === 'function');
const showSearch = computed(() => searchable || isRemote.value);

// Server-side search state.
const remoteOptions = ref([]);
const remotePage = ref(1);
const hasMore = ref(false);
const isLoading = ref(false);
const loadFailed = ref(false);
let hasLoadedOnce = false;
let requestCounter = 0;
let debounceTimer = null;

const mergeById = (current, incoming) => {
  const knownIds = new Set(current.map(option => option.id));
  return [...current, ...incoming.filter(option => !knownIds.has(option.id))];
};

const loadRemote = async ({ append = false } = {}) => {
  // Only the answer to the latest request is used: a slower, older one must
  // not overwrite what the user searched for since.
  requestCounter += 1;
  const requestId = requestCounter;
  const page = append ? remotePage.value + 1 : 1;
  isLoading.value = true;
  loadFailed.value = false;

  try {
    const result = await fetchOptions(searchTerm.value.trim(), page);
    if (requestId !== requestCounter) return;

    const incoming = result?.options || [];
    remoteOptions.value = append
      ? mergeById(remoteOptions.value, incoming)
      : incoming;
    remotePage.value = page;
    hasMore.value = Boolean(result?.hasMore);
  } catch (_error) {
    if (requestId !== requestCounter) return;

    loadFailed.value = true;
    if (!append) {
      remoteOptions.value = [];
      hasMore.value = false;
    }
  } finally {
    if (requestId === requestCounter) isLoading.value = false;
  }
};

watch(searchTerm, () => {
  if (!isRemote.value) return;

  clearTimeout(debounceTimer);
  debounceTimer = setTimeout(() => loadRemote(), SEARCH_DEBOUNCE_MS);
});

onBeforeUnmount(() => {
  clearTimeout(debounceTimer);
  requestCounter += 1;
});

// The first opening (and any opening after a failed load) fetches the list.
const openMenu = toggle => {
  toggle();
  if (isRemote.value && (!hasLoadedOnce || loadFailed.value)) {
    hasLoadedOnce = true;
    loadRemote();
  }
};

const visibleOptions = computed(() => {
  if (isRemote.value) return remoteOptions.value;
  return searchTerm.value
    ? picoSearch(options, searchTerm.value, ['name'])
    : options;
});

const hasItems = computed(() => {
  if (!selected.value) return false;
  if (!Array.isArray(selected.value)) return false;
  if (selected.value.length === 0) return false;

  return true;
});

const selectedIds = computed(() => {
  if (!hasItems.value) return [];
  return selected.value.map(value => value.id);
});

const selectedItems = computed(() => {
  // Options has additional properties, so we need to use them directly.
  // If an edit flow references a legacy option that is no longer in the
  // dropdown list, keep the selected chip visible without re-adding it to the
  // selectable options.
  if (!hasItems.value) return [];
  return selected.value
    .map(value => options.find(option => option.id === value.id) || value)
    .filter(value => value?.name);
});

// A selected item that is not in the list (a deleted contact, an archived
// option, a contact found by an earlier search) is listed first so that it can
// always be unselected.
const pinnedItems = computed(() => {
  if (searchTerm.value) return [];

  const listedIds = new Set(visibleOptions.value.map(option => option.id));
  return selectedItems.value.filter(item => !listedIds.has(item.id));
});

const listedItems = computed(() => [
  ...pinnedItems.value,
  ...visibleOptions.value,
]);

const statusMessage = computed(() => {
  if (isLoading.value) return t('DROPDOWN_MENU.SEARCHING');
  if (loadFailed.value) return t('COMBOBOX.LOAD_ERROR');
  if (listedItems.value.length) return '';
  if (searchTerm.value) {
    return t('COMBOBOX.EMPTY_SEARCH_RESULTS', { searchTerm: searchTerm.value });
  }
  return isRemote.value ? t('COMBOBOX.EMPTY_STATE') : '';
});

const selectedVisibleItems = computed(() => {
  if (!hasItems.value) return [];
  // avoid showing "+1 more" coz it takes up space anway, might as well show it
  if (selectedItems.value.length === maxChips + 1) return selectedItems.value;
  // if we have more than maxChips then show only maxChips
  return selectedItems.value.slice(0, maxChips);
});

const remainingItems = computed(() => {
  if (!hasItems.value) return [];
  if (selectedItems.value.length === maxChips + 1) return [];
  return selectedItems.value.slice(maxChips);
});

const remainingTooltip = computed(() => {
  if (!hasItems.value) return '';
  return remainingItems.value.map(item => item.name).join(', ');
});

const toggleOption = option => {
  // Ensure that the `icon` prop is not included, icon is a VNode which has circular references
  // This causes an error when creating a clone using JSON.parse(JSON.stringify())
  const optionToToggle = {
    id: option.id,
    name: option.name,
    ...(option.description ? { description: option.description } : {}),
  };

  const idToToggle = optionToToggle.id;

  if (!hasItems.value) {
    selected.value = [optionToToggle];
    return;
  }

  if (selectedIds.value.includes(idToToggle)) {
    selected.value = selected.value.filter(value => value.id !== idToToggle);
  } else {
    selected.value = [...selected.value, optionToToggle];
  }
};
</script>

<template>
  <DropdownContainer :menu-class="dropdownPosition">
    <template #trigger="{ toggle }">
      <button
        v-if="hasItems"
        class="bg-n-alpha-2 py-2 rounded-lg h-8 flex items-center px-0"
        @click="openMenu(toggle)"
      >
        <div
          v-for="item in selectedVisibleItems"
          :key="item.id ?? item.name"
          v-tooltip.top="item.name"
          class="px-3 border-r rtl:border-l rtl:border-r-0 border-n-weak text-sm flex gap-2 items-center max-w-[100px]"
          :class="item.deleted ? 'text-n-ruby-11' : 'text-n-slate-12'"
        >
          <Icon v-if="item.icon" :icon="item.icon" class="flex-shrink-0" />
          <span class="truncate">{{ item.name }}</span>
        </div>
        <div
          v-if="remainingItems.length > 0"
          v-tooltip.top="remainingTooltip"
          class="px-3 border-r rtl:border-l rtl:border-r-0 border-n-weak text-n-slate-12 text-sm flex gap-2 items-center max-w-[100px]"
        >
          <span class="truncate">{{
            t('COMBOBOX.MORE', { count: remainingItems.length })
          }}</span>
        </div>
        <div class="flex items-center border-none px-3 gap-2">
          <Icon icon="i-lucide-plus" />
        </div>
      </button>
      <Button v-else sm slate faded @click="openMenu(toggle)">
        <template #icon>
          <Icon icon="i-lucide-plus" class="text-n-slate-11" />
        </template>
        <span class="text-n-slate-11">{{ t('COMBOBOX.PLACEHOLDER') }}</span>
      </Button>
    </template>
    <DropdownBody class="min-w-56 z-[1200]" strong>
      <div v-if="showSearch" class="relative">
        <Icon
          class="absolute size-4 top-2 ltr:right-2 rtl:left-2"
          icon="i-lucide-search"
        />
        <input
          v-model="searchTerm"
          autofocus
          class="w-full rounded-lg bg-n-alpha-1 p-1.5 text-n-slate-11 ltr:pl-3 rtl:pr-3 ltr:pr-8 rtl:pl-8"
          :placeholder="searchPlaceholder || t('COMBOBOX.SEARCH_PLACEHOLDER')"
        />
      </div>
      <DropdownSection :height="dropdownMaxHeight">
        <DropdownItem
          v-for="option in listedItems"
          :key="option.id"
          :icon="option.icon"
          preserve-open
          @click="toggleOption(option)"
        >
          <template #label>
            <span v-if="option.description" class="grow min-w-0 flex flex-col">
              <span
                class="truncate"
                :class="{ 'text-n-ruby-11': option.deleted }"
              >
                {{ option.name }}
              </span>
              <span class="truncate text-xs text-n-slate-11">
                {{ option.description }}
              </span>
            </span>
            <span v-else :class="{ 'text-n-ruby-11': option.deleted }">
              {{ option.name }}
            </span>
            <Icon
              v-if="selectedIds.includes(option.id)"
              icon="i-lucide-check"
              class="bg-n-blue-text pointer-events-none"
            />
          </template>
        </DropdownItem>
        <DropdownItem v-if="statusMessage" disabled>
          {{ statusMessage }}
        </DropdownItem>
        <DropdownItem
          v-if="isRemote && hasMore && !isLoading"
          preserve-open
          @click="loadRemote({ append: true })"
        >
          <span class="text-n-blue-text">{{ t('COMBOBOX.LOAD_MORE') }}</span>
        </DropdownItem>
      </DropdownSection>
    </DropdownBody>
  </DropdownContainer>
</template>
