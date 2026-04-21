<script setup>
import { computed, nextTick, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import TeleportWithDirection from 'dashboard/components-next/TeleportWithDirection.vue';

const props = defineProps({
  items: {
    type: Array,
    required: true,
  },
  overlay: {
    type: Boolean,
    default: false,
  },
  selectedIndex: {
    type: Number,
    default: 0,
  },
  searchPlaceholder: {
    type: String,
    default: '',
  },
  emptyState: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['close', 'select', 'update:searchValue']);

const { t } = useI18n();

const toolsDropdownRef = ref(null);
const searchValue = defineModel('searchValue', {
  type: String,
  default: '',
});

const onItemClick = idx => emit('select', idx);
const closeOverlay = () => emit('close');

const onSearchInput = event => {
  searchValue.value = event.target.value;
};

const groupedItems = computed(() => {
  return props.items.reduce((sections, item, flatIndex) => {
    const groupName = item.group_label || item.group_name || '';
    const lastSection = sections[sections.length - 1];

    if (!lastSection || lastSection.groupName !== groupName) {
      sections.push({
        key: item.group_name || item.group_label || `group-${sections.length}`,
        groupName,
        items: [{ ...item, flatIndex }],
      });
      return sections;
    }

    lastSection.items.push({ ...item, flatIndex });
    return sections;
  }, []);
});

const dropdownClass = computed(() => {
  if (props.overlay) {
    return 'relative z-[1201] flex w-full max-w-xl flex-col gap-1 overflow-hidden rounded-2xl bg-n-alpha-3 p-2 shadow-xl outline outline-1 outline-n-weak backdrop-blur-[50px]';
  }

  return 'absolute bottom-20 z-50 flex w-[22.5rem] flex-col gap-1 overflow-hidden rounded-xl bg-n-alpha-3 p-2 shadow outline outline-1 outline-n-weak backdrop-blur-[50px]';
});

watch(
  () => props.selectedIndex,
  () => {
    nextTick(() => {
      const el = toolsDropdownRef.value?.querySelector(
        `#tool-item-${props.selectedIndex}`
      );
      if (el) {
        el.scrollIntoView({ block: 'nearest', behavior: 'auto' });
      }
    });
  },
  { immediate: true }
);
</script>

<template>
  <TeleportWithDirection v-if="overlay" to="body">
    <div class="fixed inset-0 z-[1200] flex items-center justify-center p-4">
      <button
        type="button"
        class="absolute inset-0 bg-n-alpha-black1 backdrop-blur-[4px]"
        @click="closeOverlay"
      />

      <div ref="toolsDropdownRef" :class="dropdownClass" @click.stop>
        <div class="border-b border-n-weak pb-2">
          <div class="relative flex items-center">
            <span
              class="pointer-events-none absolute inset-y-0 right-3 left-auto my-auto inline-flex size-4 items-center justify-center i-lucide-search text-n-slate-10 rtl:right-auto rtl:left-3"
            />
            <input
              :value="searchValue"
              type="text"
              :placeholder="
                searchPlaceholder || t('COMBOBOX.SEARCH_PLACEHOLDER')
              "
              class="reset-base h-10 w-full appearance-none rounded-lg border-none bg-n-alpha-black2 py-2 pl-5 pr-10 text-sm text-n-slate-12 outline outline-1 outline-n-weak focus:outline-n-brand rtl:pr-5 rtl:pl-10"
              @input="onSearchInput"
            />
          </div>
        </div>

        <div class="max-h-[80vh] overflow-y-auto pt-2">
          <template v-if="groupedItems.length">
            <div
              v-for="(section, sectionIndex) in groupedItems"
              :key="section.key"
              class="flex flex-col"
              :class="sectionIndex === 0 ? '' : 'mt-3'"
            >
              <p
                v-if="section.groupName"
                class="px-3 pb-1 text-xs font-semibold text-n-slate-11"
              >
                {{ section.groupName }}
              </p>

              <div
                class="flex flex-col gap-1"
                :class="
                  section.groupName ? 'ml-3 border-l border-n-weak pl-3' : ''
                "
              >
                <div
                  v-for="entry in section.items"
                  :id="`tool-item-${entry.flatIndex}`"
                  :key="entry.id || entry.flatIndex"
                  :class="{
                    'bg-n-alpha-black2': entry.flatIndex === selectedIndex,
                  }"
                  class="flex cursor-pointer flex-col gap-1 rounded-md px-3 py-2 hover:bg-n-alpha-black2"
                  @click="onItemClick(entry.flatIndex)"
                >
                  <div class="flex items-center gap-2">
                    <span class="text-sm font-medium text-n-slate-12">
                      {{ entry.title }}
                    </span>
                  </div>
                  <span
                    v-if="entry.description"
                    class="text-sm text-n-slate-11"
                  >
                    {{ entry.description }}
                  </span>
                </div>
              </div>
            </div>
          </template>

          <p v-else class="px-3 py-3 text-sm text-n-slate-11">
            {{ emptyState || t('COMBOBOX.EMPTY_STATE') }}
          </p>
        </div>
      </div>
    </div>
  </TeleportWithDirection>

  <div v-else ref="toolsDropdownRef" :class="dropdownClass">
    <div class="border-b border-n-weak pb-2">
      <div class="relative flex items-center">
        <span
          class="pointer-events-none absolute inset-y-0 right-3 left-auto my-auto inline-flex size-4 items-center justify-center i-lucide-search text-n-slate-10 rtl:right-auto rtl:left-3"
        />
        <input
          :value="searchValue"
          type="text"
          :placeholder="searchPlaceholder || t('COMBOBOX.SEARCH_PLACEHOLDER')"
          class="reset-base h-10 w-full appearance-none rounded-lg border-none bg-n-alpha-black2 py-2 pl-5 pr-10 text-sm text-n-slate-12 outline outline-1 outline-n-weak focus:outline-n-brand rtl:pr-5 rtl:pl-10"
          @input="onSearchInput"
        />
      </div>
    </div>

    <div class="max-h-[80vh] overflow-y-auto pt-2">
      <template v-if="groupedItems.length">
        <div
          v-for="(section, sectionIndex) in groupedItems"
          :key="section.key"
          class="flex flex-col"
          :class="sectionIndex === 0 ? '' : 'mt-3'"
        >
          <p
            v-if="section.groupName"
            class="px-3 pb-1 text-xs font-semibold text-n-slate-11"
          >
            {{ section.groupName }}
          </p>

          <div
            class="flex flex-col gap-1"
            :class="section.groupName ? 'ml-3 border-l border-n-weak pl-3' : ''"
          >
            <div
              v-for="entry in section.items"
              :id="`tool-item-${entry.flatIndex}`"
              :key="entry.id || entry.flatIndex"
              :class="{
                'bg-n-alpha-black2': entry.flatIndex === selectedIndex,
              }"
              class="flex cursor-pointer flex-col gap-1 rounded-md px-3 py-2 hover:bg-n-alpha-black2"
              @click="onItemClick(entry.flatIndex)"
            >
              <div class="flex items-center gap-2">
                <span class="text-sm font-medium text-n-slate-12">
                  {{ entry.title }}
                </span>
              </div>
              <span v-if="entry.description" class="text-sm text-n-slate-11">
                {{ entry.description }}
              </span>
            </div>
          </div>
        </div>
      </template>

      <p v-else class="px-3 py-3 text-sm text-n-slate-11">
        {{ emptyState || t('COMBOBOX.EMPTY_STATE') }}
      </p>
    </div>
  </div>
</template>
