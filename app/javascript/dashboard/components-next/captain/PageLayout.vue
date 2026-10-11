<script setup>
import { computed } from 'vue';
import { usePolicy } from 'dashboard/composables/usePolicy';
import Button from 'dashboard/components-next/button/Button.vue';
import BackButton from 'dashboard/components/widgets/BackButton.vue';
import PaginationFooter from 'dashboard/components-next/pagination/PaginationFooter.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import Policy from 'dashboard/components/policy.vue';

// Shared shell of the «ИИ-агенты» pages. Agents are picked in the gallery
// (captain/agents) and created there, so the header has no agent switcher and
// no create button of its own.
const props = defineProps({
  currentPage: {
    type: Number,
    default: 1,
  },
  totalCount: {
    type: Number,
    default: 100,
  },
  itemsPerPage: {
    type: Number,
    default: 25,
  },
  headerTitle: {
    type: String,
    default: '',
  },
  backUrl: {
    type: [String, Object],
    default: '',
  },
  buttonPolicy: {
    type: Array,
    default: () => [],
  },
  buttonLabel: {
    type: String,
    default: '',
  },
  buttonIcon: {
    type: String,
    default: 'i-lucide-plus',
  },
  buttonDisabled: {
    type: Boolean,
    default: false,
  },
  buttonLoading: {
    type: Boolean,
    default: false,
  },
  featureFlag: {
    type: String,
    default: '',
  },
  isFetching: {
    type: Boolean,
    default: false,
  },
  showKnowMore: {
    type: Boolean,
    default: true,
  },
  isEmpty: {
    type: Boolean,
    default: false,
  },
  showPaginationFooter: {
    type: Boolean,
    default: true,
  },
  // 'default' (max-w-5xl), 'form' (max-w-3xl) or 'full' (max-w-none).
  contentWidth: {
    type: String,
    default: 'default',
    validator: value => ['default', 'form', 'full'].includes(value),
  },
});

const emit = defineEmits(['click', 'close', 'update:currentPage']);

const CONTENT_WIDTH_CLASSES = {
  default: 'max-w-5xl',
  form: 'max-w-3xl',
  full: 'max-w-none',
};

const { shouldShowPaywall } = usePolicy();

const showPaywall = computed(() => {
  return shouldShowPaywall(props.featureFlag);
});

const contentWidthClass = computed(
  () =>
    CONTENT_WIDTH_CLASSES[props.contentWidth] || CONTENT_WIDTH_CLASSES.default
);

const handleButtonClick = () => {
  emit('click');
};

const handlePageChange = event => {
  emit('update:currentPage', event);
};
</script>

<template>
  <section class="flex flex-col w-full h-full overflow-hidden bg-n-surface-1">
    <header class="sticky top-0 z-10 px-6">
      <div class="w-full mx-auto" :class="contentWidthClass">
        <slot v-if="$slots.header" name="header" :show-paywall="showPaywall" />
        <div
          v-else
          class="flex items-start lg:items-center justify-between w-full py-3 lg:py-0 lg:h-14 gap-4 lg:gap-2 flex-col lg:flex-row"
        >
          <div
            class="flex w-full min-w-0 flex-wrap gap-3 items-center lg:w-auto"
          >
            <BackButton v-if="backUrl" :back-url="backUrl" />
            <div class="flex items-center gap-4">
              <span
                v-if="headerTitle"
                class="text-sm font-medium text-n-slate-12"
              >
                {{ headerTitle }}
              </span>
              <div
                v-if="!isEmpty && showKnowMore"
                class="flex items-center gap-2"
              >
                <div class="w-0.5 h-4 rounded-2xl bg-n-weak" />
                <slot name="knowMore" />
              </div>
            </div>
          </div>

          <div class="flex gap-2">
            <slot name="search" />
            <div
              v-if="!showPaywall && buttonLabel"
              v-on-clickaway="() => emit('close')"
              class="relative group/captain-button"
            >
              <Policy :permissions="buttonPolicy">
                <Button
                  :label="buttonLabel"
                  :icon="buttonIcon || undefined"
                  size="sm"
                  :disabled="buttonDisabled || buttonLoading"
                  :is-loading="buttonLoading"
                  class="group-hover/captain-button:brightness-110"
                  @click="handleButtonClick"
                />
              </Policy>
              <slot name="action" />
            </div>
          </div>
        </div>
        <slot name="subHeader" />
      </div>
    </header>
    <main class="flex-1 px-6 overflow-y-auto">
      <div class="w-full h-full mx-auto py-4" :class="contentWidthClass">
        <slot v-if="!showPaywall" name="controls" />
        <div
          v-if="isFetching"
          class="flex items-center justify-center py-10 text-n-slate-11"
        >
          <Spinner />
        </div>
        <div v-else-if="showPaywall">
          <slot name="paywall" />
        </div>
        <div v-else-if="isEmpty">
          <slot name="emptyState" />
        </div>
        <slot v-else name="body" />
        <slot />
      </div>
    </main>
    <footer v-if="showPaginationFooter" class="sticky bottom-0 z-10">
      <PaginationFooter
        :current-page="currentPage"
        :total-items="totalCount"
        :items-per-page="itemsPerPage"
        class="max-w-[67rem]"
        @update:current-page="handlePageChange"
      />
    </footer>
  </section>
</template>
