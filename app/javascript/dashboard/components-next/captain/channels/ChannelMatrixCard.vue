<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import CardLayout from 'dashboard/components-next/CardLayout.vue';
import ChannelIcon from 'dashboard/components-next/icon/ChannelIcon.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import { isDraftMember } from 'dashboard/helper/captainChannelMatrix';

// Phone layout of one matrix row: AI switch, agent chips (membership), the
// main agent among the members and the reply mode. Same events as the table.

const props = defineProps({
  channel: {
    type: Object,
    required: true,
  },
  assistants: {
    type: Array,
    default: () => [],
  },
  errors: {
    type: Array,
    default: () => [],
  },
  missingMain: {
    type: Boolean,
    default: false,
  },
  iconInbox: {
    type: Object,
    default: () => ({}),
  },
  disabled: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['toggleAi', 'updateMode', 'toggleMember', 'setMain']);

const { t } = useI18n();

const inboxId = computed(() => props.channel.inbox_id);
const mainSelectId = computed(() => `captain-matrix-main-${inboxId.value}`);
const modeSelectId = computed(() => `captain-matrix-mode-${inboxId.value}`);
const channelIconInbox = computed(() => ({
  ...props.iconInbox,
  channel_type: props.channel.channel_type,
}));

const agentName = assistant => assistant.name || `#${assistant.id}`;

const isMember = assistant =>
  isDraftMember({ assistants: props.assistants }, assistant.id, inboxId.value);

const members = computed(() => props.assistants.filter(isMember));

const mainOptions = computed(() => [
  { value: '', label: t('CAPTAIN.CHANNEL_MATRIX.MAIN_NONE') },
  ...members.value.map(assistant => ({
    value: assistant.id,
    label: agentName(assistant),
    disabled: !assistant.active,
  })),
]);

const mainValue = computed(() => props.channel.main_assistant_id || '');

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

const aiLabel = computed(() =>
  t('CAPTAIN.CHANNEL_MATRIX.AI_TOGGLE', { channel: props.channel.name })
);

const chipTestId = assistant => `matrix-chip-${inboxId.value}-${assistant.id}`;

const errorText = error =>
  error.message || t('CAPTAIN.CHANNEL_MATRIX.SAVE_ERROR');

const toggleMember = assistant =>
  emit('toggleMember', assistant.id, inboxId.value, !isMember(assistant));

const setMain = value => emit('setMain', inboxId.value, value || null);
</script>

<template>
  <CardLayout compact :data-testid="`matrix-card-${inboxId}`">
    <div class="flex items-center justify-between gap-3">
      <span class="flex min-w-0 items-center gap-2">
        <ChannelIcon
          :inbox="channelIconInbox"
          class="size-4 shrink-0 text-n-slate-11"
        />
        <span class="truncate text-heading-3 text-n-slate-12">
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
          :aria-label="aiLabel"
          :data-testid="`matrix-card-ai-${inboxId}`"
          @update:model-value="value => emit('toggleAi', inboxId, value)"
        />
      </span>
    </div>

    <div v-if="assistants.length" class="flex flex-col gap-2">
      <span class="text-body-main text-n-slate-11">
        {{ t('CAPTAIN.CHANNEL_MATRIX.AGENTS_LABEL') }}
      </span>
      <div class="flex flex-wrap gap-2">
        <Button
          v-for="assistant in assistants"
          :key="assistant.id"
          size="sm"
          :variant="isMember(assistant) ? 'faded' : 'outline'"
          :color="isMember(assistant) ? 'blue' : 'slate'"
          :disabled="disabled"
          :aria-pressed="isMember(assistant)"
          :data-testid="chipTestId(assistant)"
          @click="toggleMember(assistant)"
        >
          <Avatar
            :src="assistant.avatar_url || ''"
            :name="assistant.name || ''"
            :size="18"
            rounded-full
          />
          <span class="min-w-0 truncate">{{ agentName(assistant) }}</span>
        </Button>
      </div>
    </div>

    <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
      <div class="flex min-w-0 flex-col gap-1">
        <label :for="mainSelectId" class="mb-0">
          {{ t('CAPTAIN.CHANNEL_MATRIX.MAIN') }}
        </label>
        <Select
          :id="mainSelectId"
          :model-value="mainValue"
          :options="mainOptions"
          :disabled="disabled || !members.length"
          class="w-full"
          :data-testid="`matrix-card-main-${inboxId}`"
          @update:model-value="setMain"
        />
      </div>
      <div v-if="channel.ai_enabled" class="flex min-w-0 flex-col gap-1">
        <label :for="modeSelectId" class="mb-0">
          {{ t('CAPTAIN.INBOXES.AUTO_REPLY_MODE.LABEL') }}
        </label>
        <Select
          :id="modeSelectId"
          :model-value="channel.auto_reply_mode"
          :options="autoReplyOptions"
          :disabled="disabled"
          class="w-full"
          :data-testid="`matrix-card-mode-${inboxId}`"
          @update:model-value="mode => emit('updateMode', inboxId, mode)"
        />
      </div>
    </div>

    <p v-if="missingMain" class="mb-0 text-xs text-n-amber-11">
      {{ t('CAPTAIN.CHANNEL_MATRIX.MAIN_MISSING_HINT') }}
    </p>
    <p
      v-for="(error, index) in errors"
      :key="`${error.code}-${index}`"
      class="mb-0 text-xs text-n-ruby-11"
      role="alert"
      :data-testid="`matrix-card-error-${inboxId}`"
    >
      {{ errorText(error) }}
    </p>
  </CardLayout>
</template>
