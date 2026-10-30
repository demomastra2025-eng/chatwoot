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

const clearSearch = async () => {
  searchQuery.value = '';
  await focusSearchInput();
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
  <div class="flex md:relative">
    <NextButton
      v-tooltip.right="$t('CHAT_LIST.LOCAL_SEARCH.TOOLTIP_LABEL')"
      :aria-label="$t('CHAT_LIST.LOCAL_SEARCH.TOOLTIP_LABEL')"
      :aria-pressed="hasSearchQuery"
      icon="i-lucide-search"
      variant="faded"
      :color="hasSearchQuery ? 'blue' : 'slate'"
      xs
      @click="toggleSearch"
    />
    <div
      v-if="isOpen"
      v-on-click-outside="closeSearch"
      class="mt-1 bg-n-alpha-3 backdrop-blur-[100px] border border-n-weak inset-x-3 w-auto md:inset-x-auto md:w-[26rem] rounded-xl p-3 absolute z-40 top-full"
      :class="{
        'md:ltr:left-0 md:rtl:right-0': !isOnExpandedLayout,
        'md:ltr:right-0 md:rtl:left-0': isOnExpandedLayout,
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
        <button
          v-if="hasSearchQuery"
          type="button"
          data-test-id="local-search-clear-input"
          class="inline-flex size-5 shrink-0 items-center justify-center rounded text-n-slate-10 transition-colors hover:bg-n-alpha-3 hover:text-n-slate-12"
          :aria-label="t('CHAT_LIST.LOCAL_SEARCH.CLEAR_BUTTON_LABEL')"
          @click="clearSearch"
        >
          <span class="i-lucide-x size-3.5" aria-hidden="true" />
        </button>
        <span v-else class="i-lucide-search text-sm text-n-slate-10" />
      </div>
    </div>
  </div>
</template>
