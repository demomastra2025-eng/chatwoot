<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import Avatar from 'dashboard/components-next/avatar/Avatar.vue';

const props = defineProps({
  dropdownStyle: {
    type: Object,
    default: () => ({}),
  },
  teleportTarget: {
    type: [String, Object],
    default: 'body',
  },
  open: {
    type: Boolean,
    required: true,
  },
  inline: {
    type: Boolean,
    default: false,
  },
  options: {
    type: Array,
    required: true,
  },
  remoteOptions: { type: Array, default: () => [] },
  remoteTitle: { type: String, default: '' },
  remoteLoading: { type: Boolean, default: false },
  remoteError: { type: Boolean, default: false },
  remoteTruncated: { type: Boolean, default: false },
  remoteLoadingLabel: { type: String, default: '' },
  remoteErrorLabel: { type: String, default: '' },
  remoteTruncatedLabel: { type: String, default: '' },
  remotePhoneLabel: { type: String, default: '' },
  remoteHint: { type: String, default: '' },
  remoteBusyToken: { type: String, default: '' },
  searchPlaceholder: {
    type: String,
    default: '',
  },
  showSearchInput: {
    type: Boolean,
    default: true,
  },
  emptyState: {
    type: String,
    default: '',
  },
  selectedLabelPreview: {
    type: String,
    default: '',
  },
  createOptionLabel: {
    type: String,
    default: '',
  },
  showCreateAlways: { type: Boolean, default: false },
  multiple: {
    type: Boolean,
    default: false,
  },
  selectedValues: {
    type: [String, Number, Array],
    default: () => [],
  },
});

const emit = defineEmits(['create', 'select', 'selectRemote', 'search']);

const { t } = useI18n();

const searchValue = defineModel('searchValue', {
  type: String,
  default: '',
});

const searchInput = ref(null);
const activeIndex = ref(-1);
const selectable = computed(() => [
  ...props.options.map(option => ({ option, remote: false })),
  ...props.remoteOptions.map(option => ({ option, remote: true })),
]);
watch(
  () => [props.options, props.remoteOptions],
  () => {
    activeIndex.value = -1;
  }
);

const onKeydown = event => {
  if (!selectable.value.length) return;
  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
    event.preventDefault();
    const offset = event.key === 'ArrowDown' ? 1 : -1;
    if (activeIndex.value < 0) {
      activeIndex.value =
        event.key === 'ArrowDown' ? 0 : selectable.value.length - 1;
    } else {
      activeIndex.value =
        (activeIndex.value + offset + selectable.value.length) %
        selectable.value.length;
    }
  } else if (event.key === 'Enter' && activeIndex.value >= 0) {
    event.preventDefault();
    const selected = selectable.value[activeIndex.value];
    emit(selected.remote ? 'selectRemote' : 'select', selected.option);
  }
};

const isSelected = option => {
  if (Array.isArray(props.selectedValues)) {
    return props.selectedValues.includes(option.value);
  }
  return option.value === props.selectedValues;
};

const onInputSearch = event => {
  searchValue.value = event.target.value;
  emit('search', event.target.value);
};

const createOption = () => emit('create', searchValue.value.trim());

defineExpose({
  focus: () => searchInput.value?.focus(),
});
</script>

<template>
  <Teleport :to="teleportTarget" :disabled="inline">
    <div
      v-show="open"
      data-modal-safe-interaction
      class="dashboard-combobox-dropdown flex flex-col overflow-hidden border border-n-weak bg-n-solid-2"
      :class="
        inline
          ? 'absolute left-0 top-full z-30 mt-1 max-h-64 w-full rounded-md p-1 shadow-lg'
          : 'fixed z-[170] rounded-lg bg-n-solid-2/95 p-2 shadow-xl outline outline-1 outline-n-container transition-opacity duration-150 backdrop-blur-[16px]'
      "
      :style="[
        inline ? undefined : props.dropdownStyle,
        {
          '--combobox-dropdown-max-height': inline
            ? '256px'
            : props.dropdownStyle.maxHeight || '320px',
        },
      ]"
      @mousedown.stop
      @mouseup.stop
      @click.stop
    >
      <div
        v-if="selectedLabelPreview"
        tabindex="0"
        class="combobox-selected-label-preview mb-2 shrink-0 overflow-y-auto overscroll-contain break-words whitespace-pre-line rounded-md bg-n-alpha-black2 px-3 text-sm leading-5 text-n-slate-12"
        :title="selectedLabelPreview"
      >
        {{ selectedLabelPreview }}
      </div>
      <div v-if="showSearchInput" class="shrink-0 border-b border-n-weak pb-2">
        <div class="relative flex items-center">
          <span
            class="pointer-events-none absolute inset-y-0 right-3 left-auto my-auto inline-flex size-4 items-center justify-center i-lucide-search text-n-slate-10 rtl:right-auto rtl:left-3"
          />
          <input
            ref="searchInput"
            :value="searchValue"
            type="text"
            :placeholder="searchPlaceholder || t('COMBOBOX.SEARCH_PLACEHOLDER')"
            class="reset-base h-10 w-full appearance-none rounded-lg border-none bg-n-alpha-black2 py-2 pl-5 pr-10 text-sm text-n-slate-12 outline outline-1 outline-n-weak focus:outline-n-brand rtl:pr-5 rtl:pl-10"
            @input="onInputSearch"
            @keydown="onKeydown"
          />
        </div>
      </div>
      <ul
        class="mb-0 min-h-0 flex-1 overflow-auto pt-2"
        role="listbox"
        :aria-multiselectable="multiple"
      >
        <li
          v-for="option in options"
          :key="option.value"
          class="flex w-full cursor-pointer items-center justify-between gap-2 rounded-lg px-3 py-2 text-sm transition-colors duration-150 hover:bg-n-alpha-2"
          :class="{
            'bg-n-alpha-2':
              isSelected(option) || activeIndex === options.indexOf(option),
          }"
          role="option"
          :aria-selected="isSelected(option)"
          @click="emit('select', option)"
        >
          <span class="flex min-w-0 flex-1 items-center gap-2 text-left">
            <Avatar
              v-if="option.thumbnail"
              :name="option.thumbnail.name || option.label"
              :src="option.thumbnail.src"
              :size="20"
              rounded-full
            />
            <span
              v-else-if="option.stageColor"
              class="h-5 w-1 shrink-0 rounded-full"
              :style="{ backgroundColor: option.stageColor }"
              aria-hidden="true"
            />
            <span
              v-if="option.icon"
              class="size-4 flex-shrink-0"
              :class="[option.icon, option.iconClass || 'text-n-slate-11']"
              aria-hidden="true"
            />
            <span
              :class="[
                option.labelClass || 'text-n-slate-12',
                {
                  'font-medium': isSelected(option),
                  truncate: !option.wrapLabel,
                  'whitespace-normal break-words': option.wrapLabel,
                },
              ]"
              class="min-w-0 flex-1 text-left"
              :title="option.label"
            >
              {{ option.label }}
            </span>
          </span>
          <a
            v-if="option.href"
            class="inline-flex size-6 shrink-0 items-center justify-center rounded-md text-n-slate-10 transition-colors hover:bg-n-alpha-black2 hover:text-n-slate-12"
            :href="option.href"
            target="_blank"
            rel="noopener noreferrer"
            :aria-label="$t('COMBOBOX.OPEN_IN_NEW_TAB')"
            @click.stop
          >
            <span class="i-lucide-external-link size-3.5" aria-hidden="true" />
          </a>
          <span
            v-if="isSelected(option)"
            class="flex-shrink-0 i-lucide-check size-4 text-n-slate-11"
          />
        </li>
        <li
          v-if="
            remoteTitle &&
            (remoteLoading ||
              remoteError ||
              remoteOptions.length ||
              remoteTruncated ||
              remoteHint)
          "
          class="border-t border-n-weak px-3 pt-3 pb-1 text-xs font-medium text-n-slate-11"
          role="presentation"
        >
          {{ remoteTitle }}
        </li>
        <li
          v-for="(option, index) in remoteOptions"
          :key="option.token"
          class="min-w-0 cursor-pointer rounded-lg px-3 py-2 text-sm text-n-slate-12 hover:bg-n-alpha-2"
          :class="{
            'bg-n-alpha-2': activeIndex === options.length + index,
            'opacity-60': remoteBusyToken === option.token,
          }"
          role="option"
          :aria-selected="activeIndex === options.length + index"
          @click="emit('selectRemote', option)"
        >
          <div class="min-w-0 break-words font-medium">
            {{ option.fullName }}
          </div>
          <div
            class="flex min-w-0 flex-wrap items-center gap-x-2 text-xs text-n-slate-11"
          >
            <span v-if="option.birthDate">{{ option.birthDate }}</span>
            <span v-if="option.iinMasked">{{ option.iinMasked }}</span>
            <span
              v-if="option.phoneKnown"
              class="inline-flex items-center gap-1"
            >
              <span class="i-lucide-phone size-3" aria-hidden="true" />{{
                remotePhoneLabel
              }}
            </span>
            <span
              v-if="remoteBusyToken === option.token"
              class="i-lucide-loader-circle size-3 animate-spin"
              aria-hidden="true"
            />
          </div>
        </li>
        <li
          v-if="remoteLoading"
          class="px-3 py-2 text-xs text-n-slate-11"
          role="status"
        >
          {{ remoteLoadingLabel }}
        </li>
        <li
          v-if="remoteError"
          class="px-3 py-2 text-xs text-n-slate-11"
          role="status"
        >
          {{ remoteErrorLabel }}
        </li>
        <li
          v-if="remoteTruncated"
          class="px-3 py-2 text-xs text-n-slate-11"
          role="status"
        >
          {{ remoteTruncatedLabel }}
        </li>
        <li
          v-if="remoteHint"
          class="px-3 py-2 text-xs text-n-slate-11"
          role="status"
        >
          {{ remoteHint }}
        </li>
        <li
          v-if="createOptionLabel && (searchValue.trim() || showCreateAlways)"
          data-testid="combobox-create-option"
          class="flex w-full cursor-pointer items-center gap-2 rounded-lg px-3 py-2 text-sm text-n-slate-11 transition-colors duration-150 hover:bg-n-alpha-2 hover:text-n-slate-12"
          role="option"
          tabindex="0"
          :aria-label="
            showCreateAlways
              ? createOptionLabel
              : [createOptionLabel, searchValue.trim()]
                  .filter(Boolean)
                  .join(' ')
          "
          aria-selected="false"
          @click="createOption"
          @keydown.enter.prevent="createOption"
          @keydown.space.prevent="createOption"
        >
          <span
            class="i-lucide-plus-circle size-4 shrink-0"
            aria-hidden="true"
          />
          <span class="flex min-w-0 flex-1 items-center gap-1 text-left">
            <span class="shrink-0">{{ createOptionLabel }}</span>
            <span
              v-if="searchValue.trim() && !showCreateAlways"
              data-testid="combobox-create-option-value"
              class="min-w-0 truncate font-medium text-n-blue-11"
            >
              {{ searchValue.trim() }}
            </span>
          </span>
        </li>
        <li
          v-else-if="
            options.length === 0 &&
            !remoteOptions.length &&
            !remoteLoading &&
            !remoteError &&
            !remoteHint
          "
          class="px-3 py-3 text-sm text-n-slate-11"
        >
          {{ emptyState || t('COMBOBOX.EMPTY_STATE') }}
        </li>
      </ul>
    </div>
  </Teleport>
</template>

<style scoped>
.combobox-selected-label-preview {
  max-height: max(
    20px,
    min(128px, calc(var(--combobox-dropdown-max-height, 320px) - 124px))
  );
}
</style>
