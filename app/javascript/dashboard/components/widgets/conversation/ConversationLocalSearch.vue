<script setup>
import { computed, nextTick, ref, useTemplateRef } from 'vue';
import { vOnClickOutside } from '@vueuse/components';
import { useI18n } from 'vue-i18n';
import { useEmitter } from 'dashboard/composables/emitter';
import NextButton from 'dashboard/components-next/button/Button.vue';

defineProps({
  isOnExpandedLayout: {
    type: Boolean,
    required: true,
  },
});

const searchQuery = defineModel({
  type: String,
  default: '',
});

const { t } = useI18n();

const isOpen = ref(false);
const searchInputRef = useTemplateRef('searchInputRef');

const hasSearchQuery = computed(() => Boolean(searchQuery.value.trim()));

const focusSearchInput = async () => {
  await nextTick();
  searchInputRef.value?.focus();
};

const openSearch = async () => {
  isOpen.value = true;
  await focusSearchInput();
};

const closeSearch = () => {
  isOpen.value = false;
};

const toggleSearch = async () => {
  if (isOpen.value) {
    closeSearch();
    return;
  }

  await openSearch();
};

useEmitter('clearSearchInput', () => {
  searchQuery.value = '';
  closeSearch();
});
</script>

<template>
  <div class="relative flex">
    <NextButton
      v-tooltip.right="$t('CHAT_LIST.LOCAL_SEARCH.TOOLTIP_LABEL')"
      :aria-label="$t('CHAT_LIST.LOCAL_SEARCH.TOOLTIP_LABEL')"
      icon="i-lucide-search"
      slate
      xs
      :faded="!hasSearchQuery && !isOpen"
      @click="toggleSearch"
    />
    <div
      v-if="isOpen"
      v-on-click-outside="closeSearch"
      class="mt-1 bg-n-alpha-3 backdrop-blur-[100px] border border-n-weak w-[26rem] rounded-xl p-3 absolute z-40 top-full"
      :class="{
        'ltr:left-0 rtl:right-0': !isOnExpandedLayout,
        'ltr:right-0 rtl:left-0': isOnExpandedLayout,
      }"
    >
      <h3 class="mb-2 px-1 text-sm font-medium text-n-slate-12">
        {{ t('CHAT_LIST.LOCAL_SEARCH.TITLE') }}
      </h3>
      <div class="flex h-11 items-center gap-2 rounded-lg bg-n-alpha-2 px-3">
        <input
          ref="searchInputRef"
          v-model="searchQuery"
          type="text"
          class="reset-base outline-none w-full m-0 bg-transparent border-transparent shadow-none text-sm text-n-slate-12 placeholder:text-n-slate-10 active:border-transparent active:shadow-none hover:border-transparent hover:shadow-none focus:border-transparent focus:shadow-none"
          :placeholder="t('CHAT_LIST.LOCAL_SEARCH.PLACEHOLDER')"
          @keydown.escape.prevent="closeSearch"
        />
        <span class="i-lucide-search text-sm text-n-slate-10" />
      </div>
    </div>
  </div>
</template>
