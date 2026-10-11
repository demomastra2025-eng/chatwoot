<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import ChannelIcon from 'dashboard/components-next/icon/ChannelIcon.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import ChannelMatrixAgentHeader from 'dashboard/components-next/captain/channels/ChannelMatrixAgentHeader.vue';
import { isDraftMember } from 'dashboard/helper/captainChannelMatrix';

// Desktop matrix: rows = text channels, columns = agents. One report block;
// only the table scrolls horizontally inside it. Rendering only: every change
// is emitted and applied to the page draft.

const props = defineProps({
  channels: {
    type: Array,
    default: () => [],
  },
  assistants: {
    type: Array,
    default: () => [],
  },
  errorsByInbox: {
    type: Object,
    default: () => ({}),
  },
  missingMainIds: {
    type: Array,
    default: () => [],
  },
  inboxLookup: {
    type: Object,
    default: () => ({}),
  },
  disabled: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits([
  'toggleAi',
  'updateMode',
  'toggleMember',
  'setMain',
  'setScope',
]);

const { t } = useI18n();

const membershipDraft = computed(() => ({ assistants: props.assistants }));

const autoReplyOptions = computed(() => [
  {
    value: 'always',
    label: t('CAPTAIN.INBOXES.AUTO_REPLY_MODE.OPTIONS.ALWAYS'),
  },
  {
    value: 'working_hours',
    label: t('CAPTAIN.INBOXES.AUTO_REPLY_MODE.OPTIONS.WORKING_HOURS'),
  },
  {
    value: 'outside_working_hours',
    label: t('CAPTAIN.INBOXES.AUTO_REPLY_MODE.OPTIONS.OUTSIDE_WORKING_HOURS'),
  },
]);

const isMember = (assistant, channel) =>
  isDraftMember(membershipDraft.value, assistant.id, channel.inbox_id);

const isMain = (assistant, channel) =>
  channel.main_assistant_id === assistant.id;

const iconInbox = channel => ({
  ...(props.inboxLookup[channel.inbox_id] || {}),
  channel_type: channel.channel_type,
});

const rowErrors = channel => props.errorsByInbox[channel.inbox_id] || [];

const errorText = error =>
  error.message || t('CAPTAIN.CHANNEL_MATRIX.SAVE_ERROR');

const agentName = assistant => assistant.name || `#${assistant.id}`;

const aiLabel = channel =>
  t('CAPTAIN.CHANNEL_MATRIX.AI_TOGGLE', { channel: channel.name });

const cellLabel = (assistant, channel) =>
  t('CAPTAIN.CHANNEL_MATRIX.WORKS_HERE_LABEL', {
    agent: agentName(assistant),
    channel: channel.name,
  });

const starLabel = (assistant, channel) => {
  if (!assistant.active) return t('CAPTAIN.CHANNEL_MATRIX.MAIN_INACTIVE');
  return isMain(assistant, channel)
    ? t('CAPTAIN.CHANNEL_MATRIX.MAIN')
    : t('CAPTAIN.CHANNEL_MATRIX.MAKE_MAIN');
};

const starIcon = (assistant, channel) =>
  isMain(assistant, channel) ? 'i-ri-star-fill' : 'i-ri-star-line';

const cellTestId = (channel, assistant) =>
  `matrix-cell-${channel.inbox_id}-${assistant.id}`;

const starTestId = (channel, assistant) =>
  `matrix-star-${channel.inbox_id}-${assistant.id}`;

const toggleMember = (assistant, channel, member) =>
  emit('toggleMember', assistant.id, channel.inbox_id, member);
</script>

<template>
  <div
    class="min-w-0 rounded-xl bg-n-solid-2 px-6 py-5 shadow outline outline-1 -outline-offset-1 outline-n-container"
    data-testid="matrix-table"
  >
    <div class="overflow-x-auto">
      <table class="w-full min-w-max border-collapse text-left">
        <thead>
          <tr class="border-b border-n-weak">
            <th
              scope="col"
              class="sticky left-0 z-[1] bg-n-solid-2 py-3 pr-4 align-bottom text-body-main font-normal text-n-slate-11"
            >
              {{ t('CAPTAIN.CHANNEL_MATRIX.CHANNEL_COLUMN') }}
            </th>
            <th
              v-for="assistant in assistants"
              :key="assistant.id"
              scope="col"
              class="min-w-[9rem] px-3 py-3 align-bottom font-normal"
            >
              <ChannelMatrixAgentHeader
                :assistant="assistant"
                :disabled="disabled"
                @update:scope="scope => emit('setScope', assistant.id, scope)"
              />
            </th>
          </tr>
        </thead>
        <tbody class="divide-y divide-n-weak">
          <tr
            v-for="channel in channels"
            :key="channel.inbox_id"
            :data-testid="`matrix-row-${channel.inbox_id}`"
          >
            <th
              scope="row"
              class="sticky left-0 z-[1] bg-n-solid-2 py-3 pr-4 align-top font-normal"
            >
              <div class="flex w-72 flex-col gap-2">
                <div class="flex items-center justify-between gap-3">
                  <span class="flex min-w-0 items-center gap-2">
                    <ChannelIcon
                      :inbox="iconInbox(channel)"
                      class="size-4 shrink-0 text-n-slate-11"
                    />
                    <span
                      class="truncate text-heading-3 text-n-slate-12"
                      :title="channel.name"
                    >
                      {{ channel.name }}
                    </span>
                  </span>
                  <span class="flex shrink-0 items-center gap-2">
                    <span class="text-body-main text-n-slate-11">
                      {{ t('CAPTAIN.CHANNEL_MATRIX.AI') }}
                    </span>
                    <Switch
                      :model-value="channel.ai_enabled"
                      :disabled="disabled"
                      :aria-label="aiLabel(channel)"
                      :data-testid="`matrix-ai-${channel.inbox_id}`"
                      @update:model-value="
                        value => emit('toggleAi', channel.inbox_id, value)
                      "
                    />
                  </span>
                </div>
                <Select
                  v-if="channel.ai_enabled"
                  :model-value="channel.auto_reply_mode"
                  :options="autoReplyOptions"
                  :disabled="disabled"
                  :aria-label="t('CAPTAIN.INBOXES.AUTO_REPLY_MODE.LABEL')"
                  :data-testid="`matrix-mode-${channel.inbox_id}`"
                  class="w-full"
                  @update:model-value="
                    mode => emit('updateMode', channel.inbox_id, mode)
                  "
                />
                <p
                  v-if="missingMainIds.includes(channel.inbox_id)"
                  class="mb-0 text-xs text-n-amber-11"
                  :data-testid="`matrix-main-hint-${channel.inbox_id}`"
                >
                  {{ t('CAPTAIN.CHANNEL_MATRIX.MAIN_MISSING_HINT') }}
                </p>
                <p
                  v-for="(error, index) in rowErrors(channel)"
                  :key="`${error.code}-${index}`"
                  class="mb-0 whitespace-normal text-xs text-n-ruby-11"
                  role="alert"
                  :data-testid="`matrix-row-error-${channel.inbox_id}`"
                >
                  {{ errorText(error) }}
                </p>
              </div>
            </th>
            <td
              v-for="assistant in assistants"
              :key="assistant.id"
              class="px-3 py-3 align-top"
            >
              <div class="flex h-6 items-center justify-center gap-2">
                <Checkbox
                  :model-value="isMember(assistant, channel)"
                  :disabled="disabled"
                  :aria-label="cellLabel(assistant, channel)"
                  :title="t('CAPTAIN.CHANNEL_MATRIX.WORKS_HERE')"
                  :data-testid="cellTestId(channel, assistant)"
                  @update:model-value="
                    member => toggleMember(assistant, channel, member)
                  "
                />
                <Button
                  v-if="isMember(assistant, channel)"
                  :icon="starIcon(assistant, channel)"
                  variant="ghost"
                  :color="isMain(assistant, channel) ? 'amber' : 'slate'"
                  size="xs"
                  :class="{ '!text-n-slate-10': !isMain(assistant, channel) }"
                  :disabled="disabled || !assistant.active"
                  :aria-label="starLabel(assistant, channel)"
                  :aria-pressed="isMain(assistant, channel)"
                  :title="starLabel(assistant, channel)"
                  :data-testid="starTestId(channel, assistant)"
                  @click="emit('setMain', channel.inbox_id, assistant.id)"
                />
                <span v-else class="size-6 shrink-0" aria-hidden="true" />
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
