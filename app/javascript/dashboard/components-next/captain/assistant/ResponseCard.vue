<script setup>
import { computed } from 'vue';
import { useToggle } from '@vueuse/core';
import { useI18n } from 'vue-i18n';
import { dynamicTime } from 'shared/helpers/timeHelper';

import CardLayout from 'dashboard/components-next/CardLayout.vue';
import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Policy from 'dashboard/components/policy.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';

const props = defineProps({
  id: {
    type: Number,
    required: true,
  },
  question: {
    type: String,
    required: true,
  },
  answer: {
    type: String,
    required: true,
  },
  compact: {
    type: Boolean,
    default: false,
  },
  status: {
    type: String,
    default: 'approved',
  },
  documentable: {
    type: Object,
    default: null,
  },
  assistant: {
    type: Object,
    default: () => ({}),
  },
  updatedAt: {
    type: Number,
    required: true,
  },
  createdAt: {
    type: Number,
    required: true,
  },
  isSelected: {
    type: Boolean,
    default: false,
  },
  selectable: {
    type: Boolean,
    default: false,
  },
  showMenu: {
    type: Boolean,
    default: true,
  },
  showActions: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['action', 'navigate', 'select', 'hover']);

const { t } = useI18n();

const [showActionsDropdown, toggleDropdown] = useToggle();

const modelValue = computed({
  get: () => props.isSelected,
  set: () => emit('select', props.id),
});

const statusAction = computed(() => {
  if (props.status === 'pending') {
    return [
      {
        label: t('CAPTAIN.RESPONSES.OPTIONS.APPROVE'),
        value: 'approve',
        action: 'approve',
        icon: 'i-lucide-circle-check-big',
      },
    ];
  }
  return [];
});

const menuItems = computed(() => [
  ...statusAction.value,
  {
    label: t('CAPTAIN.RESPONSES.OPTIONS.EDIT_RESPONSE'),
    value: 'edit',
    action: 'edit',
    icon: 'i-lucide-pencil-line',
  },
  {
    label: t('CAPTAIN.RESPONSES.OPTIONS.DELETE_RESPONSE'),
    value: 'delete',
    action: 'delete',
    icon: 'i-lucide-trash',
  },
]);

const timestamp = computed(() =>
  dynamicTime(props.updatedAt || props.createdAt)
);

const handleAssistantAction = ({ action, value }) => {
  toggleDropdown(false);
  emit('action', { action, value, id: props.id });
};

const handleDocumentableClick = () => {
  emit('navigate', {
    id: props.documentable.id,
    type: props.documentable.type,
  });
};
</script>

<template>
  <CardLayout
    selectable
    class="relative [&>div]:!py-3"
    :class="{ 'rounded-md [&>div]:!py-2.5': compact }"
    @mouseenter="emit('hover', true)"
    @mouseleave="emit('hover', false)"
  >
    <div
      v-show="selectable"
      class="absolute top-5 ltr:left-3 rtl:right-3"
      :class="{ 'top-4': compact }"
    >
      <Checkbox v-model="modelValue" />
    </div>
    <div class="flex w-full flex-col gap-2">
      <div class="flex items-start justify-between gap-3">
        <span class="min-w-0 flex-1 text-base text-n-slate-12 line-clamp-1">
          {{ question }}
        </span>
        <div class="flex min-w-0 shrink-0 items-center gap-4">
          <div
            v-if="!compact"
            class="hidden min-w-0 items-center gap-3 md:flex"
          >
            <span
              v-if="status === 'approved'"
              class="inline-flex max-w-40 shrink items-center gap-1 truncate text-sm text-n-slate-11"
            >
              <Icon icon="i-woot-captain" class="size-3.5 shrink-0" />
              {{ assistant?.name || '' }}
            </span>
            <div
              v-if="documentable"
              class="grid min-w-0 max-w-56 grid-cols-[auto_1fr] items-center gap-1 text-sm text-n-slate-11"
            >
              <Icon
                v-if="documentable.type === 'Captain::Document'"
                icon="i-ph-files-light"
                class="size-3.5 shrink-0"
              />
              <Icon
                v-else-if="documentable.type === 'User'"
                icon="i-ph-user-circle-plus"
                class="size-3.5 shrink-0"
              />
              <Icon
                v-else-if="documentable.type === 'Conversation'"
                icon="i-ph-chat-circle-dots"
                class="size-3.5 shrink-0"
              />
              <span
                v-if="documentable.type === 'Captain::Document'"
                class="truncate"
                :title="documentable.name"
              >
                {{ documentable.name }}
              </span>
              <span
                v-else-if="documentable.type === 'User'"
                class="truncate"
                :title="documentable.available_name"
              >
                {{ documentable.available_name }}
              </span>
              <span
                v-else-if="documentable.type === 'Conversation'"
                class="cursor-pointer truncate hover:underline"
                role="button"
                @click="handleDocumentableClick"
              >
                {{
                  t(`CAPTAIN.RESPONSES.DOCUMENTABLE.CONVERSATION`, {
                    id: documentable.display_id,
                  })
                }}
              </span>
            </div>
          </div>
          <div v-if="!compact && showMenu" class="flex items-center gap-2">
            <Policy
              v-on-clickaway="() => toggleDropdown(false)"
              :permissions="['administrator']"
              class="relative flex items-center group"
            >
              <Button
                icon="i-lucide-ellipsis-vertical"
                color="slate"
                size="xs"
                class="rounded-md group-hover:bg-n-alpha-2"
                @click="toggleDropdown()"
              />
              <DropdownMenu
                v-if="showActionsDropdown"
                :menu-items="menuItems"
                class="mt-1 ltr:right-0 rtl:right-0 top-full"
                @action="handleAssistantAction($event)"
              />
            </Policy>
          </div>
        </div>
      </div>
      <div class="flex items-start justify-between gap-3">
        <span
          class="min-w-0 flex-1 text-[13px] leading-5 text-n-slate-11 line-clamp-4"
        >
          {{ answer }}
        </span>
        <div
          v-if="!compact"
          class="inline-flex shrink-0 items-center gap-1 text-[13px] text-n-slate-11 line-clamp-1"
        >
          <Icon icon="i-ph-calendar-dot" class="size-3" />
          {{ timestamp }}
        </div>
      </div>
      <div
        v-if="!compact && status === 'approved'"
        class="flex items-center gap-1 text-sm text-n-slate-11 md:hidden"
      >
        <Icon icon="i-woot-captain" class="size-3.5 shrink-0" />
        <span class="truncate">
          {{ assistant?.name || '' }}
        </span>
      </div>
      <div
        v-if="!compact && documentable"
        class="flex min-w-0 items-center gap-2 text-sm text-n-slate-11 md:hidden"
      >
        <Icon
          v-if="documentable.type === 'Captain::Document'"
          icon="i-ph-files-light"
          class="size-3.5 shrink-0"
        />
        <Icon
          v-else-if="documentable.type === 'User'"
          icon="i-ph-user-circle-plus"
          class="size-3.5 shrink-0"
        />
        <Icon
          v-else-if="documentable.type === 'Conversation'"
          icon="i-ph-chat-circle-dots"
          class="size-3.5 shrink-0"
        />
        <span
          v-if="documentable.type === 'Captain::Document'"
          class="truncate"
          :title="documentable.name"
        >
          {{ documentable.name }}
        </span>
        <span
          v-else-if="documentable.type === 'User'"
          class="truncate"
          :title="documentable.available_name"
        >
          {{ documentable.available_name }}
        </span>
        <span
          v-else-if="documentable.type === 'Conversation'"
          class="cursor-pointer truncate hover:underline"
          role="button"
          @click="handleDocumentableClick"
        >
          {{
            t(`CAPTAIN.RESPONSES.DOCUMENTABLE.CONVERSATION`, {
              id: documentable.display_id,
            })
          }}
        </span>
      </div>
      <Policy v-if="!compact && showActions" :permissions="['administrator']">
        <div class="flex items-center gap-2 pt-1 sm:gap-5">
          <Button
            v-if="status === 'pending'"
            :label="$t('CAPTAIN.RESPONSES.OPTIONS.APPROVE')"
            icon="i-lucide-circle-check-big"
            sm
            link
            class="hover:!no-underline"
            @click="
              handleAssistantAction({ action: 'approve', value: 'approve' })
            "
          />
          <Button
            :label="$t('CAPTAIN.RESPONSES.OPTIONS.EDIT_RESPONSE')"
            icon="i-lucide-pencil-line"
            sm
            slate
            link
            class="hover:!no-underline"
            @click="
              handleAssistantAction({
                action: 'edit',
                value: 'edit',
              })
            "
          />
          <Button
            :label="$t('CAPTAIN.RESPONSES.OPTIONS.DELETE_RESPONSE')"
            icon="i-lucide-trash"
            sm
            ruby
            link
            class="hover:!no-underline"
            @click="
              handleAssistantAction({ action: 'delete', value: 'delete' })
            "
          />
        </div>
      </Policy>
    </div>
  </CardLayout>
</template>
