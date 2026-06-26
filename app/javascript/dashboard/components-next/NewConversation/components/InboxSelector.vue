<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { vOnClickOutside } from '@vueuse/components';
import { generateLabelForContactableInboxesList } from 'dashboard/components-next/NewConversation/helpers/composeConversationHelper.js';

import Button from 'dashboard/components-next/button/Button.vue';
import ChannelIcon from 'dashboard/components-next/icon/ChannelIcon.vue';
import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

const props = defineProps({
  targetInbox: {
    type: Object,
    default: null,
  },
  selectedContact: {
    type: Object,
    default: null,
  },
  showInboxesDropdown: {
    type: Boolean,
    required: true,
  },
  contactableInboxesList: {
    type: Array,
    default: () => [],
  },
  hasErrors: {
    type: Boolean,
    default: false,
  },
  isFetchingInboxes: {
    type: Boolean,
    default: false,
  },
  variant: {
    type: String,
    default: 'default',
    validator: value => ['default', 'touch'].includes(value),
  },
});

const emit = defineEmits([
  'updateInbox',
  'toggleDropdown',
  'handleInboxAction',
]);

const { t } = useI18n();

const isTouchVariant = computed(() => props.variant === 'touch');

const targetInboxLabel = computed(() => {
  return generateLabelForContactableInboxesList(props.targetInbox);
});
</script>

<template>
  <div
    class="flex flex-1 w-full gap-3 overflow-y-visible"
    :class="
      isTouchVariant ? 'items-center px-3 py-2' : 'items-center px-4 py-3'
    "
  >
    <label
      class="mb-0.5 text-sm font-medium whitespace-nowrap"
      :class="isTouchVariant ? 'text-n-slate-12 min-w-14' : 'text-n-slate-11'"
    >
      {{ t('COMPOSE_NEW_CONVERSATION.FORM.INBOX_SELECTOR.LABEL') }}
    </label>
    <div
      v-if="targetInbox"
      class="flex items-center gap-1.5 truncate min-w-0"
      :class="
        isTouchVariant
          ? 'h-9 flex-1 rounded-lg border border-n-weak bg-n-solid-1 ltr:pl-2 rtl:pr-2 ltr:pr-1.5 rtl:pl-1.5'
          : 'rounded-md bg-n-alpha-2 ltr:pl-4 rtl:pr-4 ltr:pr-1.5 rtl:pl-1.5 h-7'
      "
    >
      <span
        v-if="isTouchVariant"
        class="flex size-6 shrink-0 items-center justify-center rounded-md bg-n-alpha-black2 text-n-slate-11"
      >
        <ChannelIcon :inbox="targetInbox" class="size-4" />
      </span>
      <span class="text-sm truncate text-n-slate-12">
        {{ targetInboxLabel }}
      </span>
      <Button
        variant="ghost"
        icon="i-lucide-x"
        color="slate"
        size="xs"
        class="flex-shrink-0"
        @click="emit('updateInbox', null)"
      />
    </div>
    <div
      v-else
      v-on-click-outside="() => emit('toggleDropdown', false)"
      class="relative flex items-center"
      :class="isTouchVariant ? 'h-9 flex-1' : 'h-7'"
    >
      <Spinner v-if="isFetchingInboxes" :size="16" />
      <Button
        v-else
        :label="t('COMPOSE_NEW_CONVERSATION.FORM.INBOX_SELECTOR.BUTTON')"
        :icon="isTouchVariant ? 'i-lucide-inbox' : undefined"
        :variant="isTouchVariant ? 'faded' : 'link'"
        size="sm"
        :color="hasErrors ? 'ruby' : 'slate'"
        :disabled="!selectedContact"
        :class="isTouchVariant ? 'w-full justify-start' : 'hover:!no-underline'"
        @click="emit('toggleDropdown', !showInboxesDropdown)"
      />
      <DropdownMenu
        v-if="contactableInboxesList?.length > 0 && showInboxesDropdown"
        :menu-items="contactableInboxesList"
        class="ltr:left-0 rtl:right-0 z-[100] top-8 overflow-y-auto max-h-56 w-fit max-w-sm dark:!outline-n-slate-5"
        @action="emit('handleInboxAction', $event)"
      />
    </div>
  </div>
</template>
