<script setup>
import { useI18n } from 'vue-i18n';
import { ref, watch, nextTick } from 'vue';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import { useMessageFormatter } from 'shared/composables/useMessageFormatter';

const props = defineProps({
  messages: {
    type: Array,
    required: true,
  },
  isLoading: {
    type: Boolean,
    default: false,
  },
});

const messageContainer = ref(null);
const { t } = useI18n();
const { formatMessage } = useMessageFormatter();

const isUserMessage = sender => sender === 'user';
const getMessageAlignment = sender =>
  isUserMessage(sender) ? 'justify-end' : 'justify-start';
const getMessageDirection = sender =>
  isUserMessage(sender) ? 'flex-row-reverse' : 'flex-row';
const getAvatarName = sender =>
  isUserMessage(sender)
    ? t('CAPTAIN.PLAYGROUND.USER')
    : t('CAPTAIN.PLAYGROUND.ASSISTANT');
const getMessageStyle = sender =>
  isUserMessage(sender)
    ? 'bg-n-solid-blue text-n-slate-12 rounded-br-sm rounded-bl-xl rounded-t-xl'
    : 'bg-n-solid-iris text-n-slate-12 rounded-bl-sm rounded-br-xl rounded-t-xl';

const scrollToBottom = async () => {
  await nextTick();
  if (messageContainer.value) {
    messageContainer.value.scrollTop = messageContainer.value.scrollHeight;
  }
};

watch(() => props.messages.length, scrollToBottom);
</script>

<template>
  <div
    ref="messageContainer"
    class="mb-4 flex-1 space-y-6 overflow-y-auto px-6"
  >
    <div
      v-for="(message, index) in messages"
      :key="index"
      class="flex"
      :class="getMessageAlignment(message.sender)"
    >
      <div
        class="flex max-w-[90%] items-end gap-1.5 md:max-w-[60%]"
        :class="getMessageDirection(message.sender)"
      >
        <Avatar
          :name="getAvatarName(message.sender)"
          rounded-full
          :size="24"
          :icon-name="isUserMessage(message.sender) ? null : 'i-woot-captain'"
          class="shrink-0"
        />
        <div
          class="px-4 py-3 text-sm [overflow-wrap:break-word]"
          :class="getMessageStyle(message.sender)"
        >
          <div v-html="formatMessage(message.content)" />
        </div>
      </div>
    </div>
    <div v-if="isLoading" class="flex justify-start">
      <div class="flex items-start gap-1.5">
        <Avatar
          :name="getAvatarName('assistant')"
          rounded-full
          :size="24"
          icon-name="i-woot-captain"
        />
        <div
          class="max-w-sm rounded-lg bg-n-solid-iris p-3 text-sm text-n-slate-12"
        >
          <div class="flex gap-1">
            <div class="size-2 animate-bounce rounded-full bg-n-iris-10" />
            <div
              class="size-2 animate-bounce rounded-full bg-n-iris-10 [animation-delay:0.2s]"
            />
            <div
              class="size-2 animate-bounce rounded-full bg-n-iris-10 [animation-delay:0.4s]"
            />
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
