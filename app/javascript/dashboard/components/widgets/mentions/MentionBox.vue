<script setup>
import { ref, watch, computed, nextTick } from 'vue';
import { useKeyboardNavigableList } from 'dashboard/composables/useKeyboardNavigableList';
import { useMessageFormatter } from 'shared/composables/useMessageFormatter';

const props = defineProps({
  items: {
    type: Array,
    default: () => [],
  },
  placement: {
    type: String,
    default: 'top',
    validator: value => ['top', 'bottom'].includes(value),
  },
  maxVisibleItems: {
    type: Number,
    default: 0,
  },
  type: {
    type: String,
    default: 'canned',
  },
});

const emit = defineEmits(['mentionSelect']);

const { getPlainText } = useMessageFormatter();

const mentionsListContainerRef = ref(null);
const selectedIndex = ref(0);

const placementClass = computed(() => {
  return props.placement === 'bottom'
    ? 'top-full mt-2 bottom-auto'
    : 'bottom-full mb-2 top-auto';
});

const maxHeightStyle = computed(() => {
  if (!props.maxVisibleItems || props.maxVisibleItems <= 0) {
    return {};
  }

  return {
    maxHeight: `${props.maxVisibleItems * 3.25 + 0.5}rem`,
  };
});

const adjustScroll = () => {
  nextTick(() => {
    const container = mentionsListContainerRef.value;
    if (!container) return;
    const selectedElement = container.querySelector(
      `#mention-item-${selectedIndex.value}`
    );
    if (selectedElement) {
      selectedElement.scrollIntoView({ block: 'nearest', behavior: 'auto' });
    }
  });
};

const onSelect = () => {
  emit('mentionSelect', props.items[selectedIndex.value]);
};

useKeyboardNavigableList({
  items: computed(() => props.items),
  onSelect,
  adjustScroll,
  selectedIndex,
});

watch(
  () => props.items,
  newItems => {
    if (newItems.length < selectedIndex.value + 1) {
      selectedIndex.value = 0;
    }
  }
);

watch(selectedIndex, adjustScroll);

const onHover = index => {
  selectedIndex.value = index;
};

const onListItemSelection = index => {
  selectedIndex.value = index;
  onSelect();
};

const variableKey = (item = {}) => {
  return props.type === 'variable' ? `{{${item.label}}}` : `/${item.label}`;
};
</script>

<template>
  <div
    ref="mentionsListContainerRef"
    class="bg-n-solid-1 p-1 rounded-xl overflow-auto absolute w-full z-20 shadow-md left-0 max-h-[80vh] border border-solid border-n-strong mention--box"
    :class="placementClass"
    :style="maxHeightStyle"
  >
    <ul class="mb-0 vertical dropdown menu">
      <woot-dropdown-item
        v-for="(item, index) in items"
        :id="`mention-item-${index}`"
        :key="item.key"
        class="!mb-1"
        @mouseover="onHover(index)"
      >
        <button
          class="flex rounded-lg group flex-col gap-0.5 overflow-hidden cursor-pointer items-start px-3 py-2 justify-center w-full h-full text-left hover:bg-n-alpha-black2"
          :class="{
            'bg-n-alpha-black2': index === selectedIndex,
          }"
          @click="onListItemSelection(index)"
        >
          <slot :item="item" :index="index" :selected="index === selectedIndex">
            <p
              class="max-w-full min-w-0 mb-0 overflow-hidden text-sm font-medium text-n-slate-11 group-hover:text-n-slate-12 text-ellipsis whitespace-nowrap"
              :class="{
                'text-n-slate-12': index === selectedIndex,
              }"
            >
              {{ getPlainText(item.description) }}
            </p>
            <p
              class="max-w-full min-w-0 mb-0 overflow-hidden text-xs text-n-slate-11 group-hover:text-n-slate-12 text-ellipsis whitespace-nowrap"
              :class="{
                'text-n-slate-12': index === selectedIndex,
              }"
            >
              {{ variableKey(item) }}
            </p>
          </slot>
        </button>
      </woot-dropdown-item>
    </ul>
  </div>
</template>

<style scoped lang="scss">
.mention--box {
  .dropdown-menu__item:last-child > button {
    @apply border-0;
  }
}

.canned-item__button::v-deep .button__content {
  @apply overflow-hidden text-ellipsis whitespace-nowrap;
}
</style>
