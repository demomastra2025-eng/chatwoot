<script setup>
import { ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import NextButton from 'dashboard/components-next/button/Button.vue';
import MessageList from './MessageList.vue';
import CaptainAssistant from 'dashboard/api/captain/assistant';

const props = defineProps({
  assistantId: {
    type: Number,
    required: true,
  },
});

const { t } = useI18n();
const messages = ref([]);
const newMessage = ref('');
const isLoading = ref(false);

const formatMessagesForApi = () =>
  messages.value.map(message => ({
    role: message.sender,
    content: message.content,
    ...(message.sender === 'assistant' && message.agentName
      ? { agent_name: message.agentName }
      : {}),
  }));

const resetConversation = () => {
  messages.value = [];
  newMessage.value = '';
};

watch(
  () => props.assistantId,
  (newId, oldId) => {
    if (oldId && newId !== oldId) resetConversation();
  }
);

const sendMessage = async () => {
  if (!newMessage.value.trim() || isLoading.value) return;

  const currentMessage = newMessage.value;
  const messageHistory = formatMessagesForApi();
  messages.value.push({
    content: currentMessage,
    sender: 'user',
    timestamp: new Date().toISOString(),
  });
  newMessage.value = '';

  try {
    isLoading.value = true;
    const { data } = await CaptainAssistant.playground({
      assistantId: props.assistantId,
      messageContent: currentMessage,
      messageHistory,
    });

    messages.value.push({
      content: data.response || t('CAPTAIN.COPILOT.EMPTY_MESSAGE'),
      sender: 'assistant',
      agentName: data.agent_name,
      reasoning: data.reasoning,
      toolTrace: data.tool_trace || [],
      timestamp: new Date().toISOString(),
    });
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error('Error getting assistant response:', error);
    messages.value.push({
      content: t('CAPTAIN.COPILOT.EMPTY_MESSAGE'),
      sender: 'assistant',
      timestamp: new Date().toISOString(),
    });
  } finally {
    isLoading.value = false;
  }
};

const handleEnterKey = event => {
  if (event.isComposing) return;
  event.preventDefault();
  sendMessage();
};
</script>

<template>
  <div class="flex h-full min-h-0 flex-col gap-4">
    <div class="flex items-start justify-between gap-4 px-1">
      <div>
        <h3 class="text-lg font-medium text-n-slate-12">
          {{ t('CAPTAIN.PLAYGROUND.HEADER') }}
        </h3>
        <p class="mt-1 text-sm text-n-slate-11">
          {{ t('CAPTAIN.PLAYGROUND.DESCRIPTION') }}
        </p>
      </div>
      <NextButton
        ghost
        sm
        slate
        icon="i-lucide-rotate-ccw"
        @click="resetConversation"
      />
    </div>

    <div class="grid min-h-0 flex-1 gap-4 lg:grid-cols-[minmax(0,1fr)_22rem]">
      <div
        class="flex min-h-[32rem] flex-col rounded-xl border border-n-weak bg-n-solid-1 py-5"
      >
        <MessageList :messages="messages" :is-loading="isLoading" />
        <div
          class="mx-5 mt-4 flex items-center rounded-xl bg-n-background p-3 outline outline-1 outline-n-weak"
        >
          <input
            v-model="newMessage"
            class="mb-0 flex-1 border-none bg-transparent text-sm text-n-slate-12 placeholder:text-n-slate-10 focus:outline-none"
            :placeholder="t('CAPTAIN.PLAYGROUND.MESSAGE_PLACEHOLDER')"
            @keydown.enter.exact="handleEnterKey"
          />
          <NextButton
            ghost
            sm
            :disabled="!newMessage.trim() || isLoading"
            icon="i-lucide-send"
            @click="sendMessage"
          />
        </div>
      </div>

      <aside
        class="min-h-0 overflow-y-auto rounded-xl border border-n-weak bg-n-solid-1 p-4"
      >
        <h4 class="text-sm font-medium text-n-slate-12">
          {{ t('CAPTAIN.PLAYGROUND.TRACE_TITLE') }}
        </h4>
        <p class="mt-1 text-xs text-n-slate-11">
          {{ t('CAPTAIN.PLAYGROUND.TRACE_DESCRIPTION') }}
        </p>
        <div
          v-if="!messages.some(message => message.sender === 'assistant')"
          class="mt-6 text-sm text-n-slate-10"
        >
          {{ t('CAPTAIN.PLAYGROUND.TRACE_EMPTY') }}
        </div>
        <div
          v-for="(message, index) in messages.filter(
            item => item.sender === 'assistant'
          )"
          :key="`${message.timestamp}-${index}`"
          class="mt-4 border-t border-n-weak/50 pt-4 first:border-0 first:pt-0"
        >
          <p
            class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
          >
            {{ t('CAPTAIN.PLAYGROUND.TRACE_RESPONSE', { number: index + 1 }) }}
          </p>
          <div v-if="message.reasoning" class="mt-2">
            <p class="text-xs font-medium text-n-slate-12">
              {{ t('CAPTAIN.PLAYGROUND.TRACE_REASONING') }}
            </p>
            <p class="mt-1 whitespace-pre-wrap text-xs text-n-slate-11">
              {{ message.reasoning }}
            </p>
          </div>
          <div v-if="message.toolTrace?.length" class="mt-3">
            <p class="text-xs font-medium text-n-slate-12">
              {{ t('CAPTAIN.PLAYGROUND.TRACE_TOOLS') }}
            </p>
            <div
              v-for="(trace, traceIndex) in message.toolTrace"
              :key="`${trace.event}-${traceIndex}`"
              class="mt-1 flex items-center gap-2 rounded-lg bg-n-alpha-1 px-2 py-1.5 text-xs"
            >
              <span
                class="size-2 rounded-full"
                :class="trace.event === 'error' ? 'bg-n-ruby-9' : 'bg-n-teal-9'"
              />
              <span class="font-medium text-n-slate-12">{{ trace.tool }}</span>
              <span class="text-n-slate-10">{{ trace.event }}</span>
            </div>
          </div>
          <p v-else class="mt-2 text-xs text-n-slate-10">
            {{ t('CAPTAIN.PLAYGROUND.TRACE_NO_TOOLS') }}
          </p>
        </div>
      </aside>
    </div>

    <p class="text-center text-xs text-n-slate-11">
      {{ t('CAPTAIN.PLAYGROUND.CREDIT_NOTE') }}
    </p>
  </div>
</template>
