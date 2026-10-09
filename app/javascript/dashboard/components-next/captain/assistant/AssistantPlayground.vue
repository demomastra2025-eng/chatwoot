<script setup>
import { computed, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import NextButton from 'dashboard/components-next/button/Button.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import MessageList from './MessageList.vue';
import CaptainAssistant from 'dashboard/api/captain/assistant';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';

const props = defineProps({
  assistantId: {
    type: Number,
    required: true,
  },
});

const { t } = useI18n();
const captainConfigStore = useCaptainConfigStore();
const messages = ref([]);
const newMessage = ref('');
const isLoading = ref(false);
const isLoadingSettings = ref(true);
const settingsFailed = ref(false);
const assistant = ref(null);
const selectedModel = ref('');
const temperatureOverrideEnabled = ref(false);
const testTemperature = ref(1);
const thinkingEffort = ref('');
let settingsRequestSequence = 0;
let assistantSessionSequence = 0;
let playgroundRequestSequence = 0;

const availableModels = computed(() =>
  captainConfigStore.getModelsForFeature('assistant')
);
const effectiveModel = computed(
  () =>
    selectedModel.value ||
    assistant.value?.config?.model ||
    captainConfigStore.getSelectedModelForFeature('assistant') ||
    ''
);
const effectiveModelMetadata = computed(() =>
  availableModels.value.find(model => model.id === effectiveModel.value)
);
const supportsTemperature = computed(
  () => effectiveModelMetadata.value?.supports_temperature === true
);
const supportsReasoning = computed(() =>
  effectiveModelMetadata.value?.capabilities?.includes('reasoning')
);
const modelOptions = computed(() => [
  {
    value: '',
    label: t('CAPTAIN.PLAYGROUND.USE_ASSISTANT_MODEL'),
  },
  ...availableModels.value
    .filter(
      model =>
        !model.current_only || model.id === assistant.value?.config?.model
    )
    .map(model => ({
      value: model.id,
      label: model.current_only
        ? t('CAPTAIN.PLAYGROUND.CURRENT_MODEL', {
            model: model.display_name || model.id,
          })
        : model.display_name || model.id,
    })),
]);
const savedTemperature = computed(() => {
  const value = Number(assistant.value?.config?.temperature);
  return Number.isFinite(value) ? value : 1;
});
const formattedTemperature = computed(() =>
  Number(testTemperature.value || 0).toFixed(1)
);

const reasoningEffortOptions = computed(() => [
  { value: '', label: t('CAPTAIN.PLAYGROUND.USE_WORKSPACE_REASONING') },
  { value: 'none', label: t('CAPTAIN.PLAYGROUND.REASONING_NONE') },
  { value: 'low', label: t('CAPTAIN.PLAYGROUND.REASONING_LOW') },
  { value: 'medium', label: t('CAPTAIN.PLAYGROUND.REASONING_MEDIUM') },
  { value: 'high', label: t('CAPTAIN.PLAYGROUND.REASONING_HIGH') },
]);

const loadPlaygroundSettings = async (
  assistantId = props.assistantId,
  { force = false } = {}
) => {
  const requestSequence = ++settingsRequestSequence;
  isLoadingSettings.value = true;
  settingsFailed.value = false;
  try {
    const [, response] = await Promise.all([
      captainConfigStore.fetch({
        clientMetadataOnly: true,
        ...(force ? { force: true } : {}),
      }),
      CaptainAssistant.show(assistantId),
    ]);
    if (
      requestSequence !== settingsRequestSequence ||
      assistantId !== props.assistantId
    ) {
      return;
    }

    assistant.value = response.data;
    testTemperature.value = savedTemperature.value;
    settingsFailed.value = captainConfigStore.uiFlags.fetchError === true;
  } catch {
    if (
      requestSequence === settingsRequestSequence &&
      assistantId === props.assistantId
    ) {
      settingsFailed.value = true;
    }
  } finally {
    if (
      requestSequence === settingsRequestSequence &&
      assistantId === props.assistantId
    ) {
      isLoadingSettings.value = false;
    }
  }
};

watch(supportsTemperature, supported => {
  if (!supported) temperatureOverrideEnabled.value = false;
});
watch(supportsReasoning, supported => {
  if (!supported) thinkingEffort.value = '';
});

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

const resetAssistantSession = () => {
  assistantSessionSequence += 1;
  playgroundRequestSequence += 1;
  resetConversation();
  assistant.value = null;
  selectedModel.value = '';
  temperatureOverrideEnabled.value = false;
  testTemperature.value = 1;
  thinkingEffort.value = '';
  isLoading.value = false;
  isLoadingSettings.value = true;
  settingsFailed.value = false;
};

watch(
  () => props.assistantId,
  (newId, oldId) => {
    if (newId === oldId) return;

    settingsRequestSequence += 1;
    resetAssistantSession();
    loadPlaygroundSettings(newId);
  },
  { flush: 'sync' }
);

const sendMessage = async () => {
  if (!newMessage.value.trim() || isLoading.value) return;

  const currentMessage = newMessage.value;
  const requestAssistantId = props.assistantId;
  const sessionSequence = assistantSessionSequence;
  const requestSequence = ++playgroundRequestSequence;
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
      assistantId: requestAssistantId,
      messageContent: currentMessage,
      messageHistory,
      testOptions: {
        ...(selectedModel.value ? { model: selectedModel.value } : {}),
        ...(temperatureOverrideEnabled.value && supportsTemperature.value
          ? { temperature: testTemperature.value }
          : {}),
        ...(thinkingEffort.value && supportsReasoning.value
          ? { thinkingEffort: thinkingEffort.value }
          : {}),
      },
    });

    if (
      sessionSequence !== assistantSessionSequence ||
      requestAssistantId !== props.assistantId ||
      requestSequence !== playgroundRequestSequence
    ) {
      return;
    }

    messages.value.push({
      content: data.response || t('CAPTAIN.COPILOT.EMPTY_MESSAGE'),
      sender: 'assistant',
      agentName: data.agent_name,
      reasoning: data.reasoning,
      responseLatencyMs: data.response_latency_ms,
      reportedReasoningTokens: data.reported_reasoning_tokens,
      toolTrace: data.tool_trace || [],
      timestamp: new Date().toISOString(),
    });
  } catch (error) {
    if (
      sessionSequence !== assistantSessionSequence ||
      requestAssistantId !== props.assistantId ||
      requestSequence !== playgroundRequestSequence
    ) {
      return;
    }

    // eslint-disable-next-line no-console
    console.error('Error getting assistant response:', error);
    messages.value.push({
      content: t('CAPTAIN.COPILOT.EMPTY_MESSAGE'),
      sender: 'assistant',
      timestamp: new Date().toISOString(),
    });
  } finally {
    if (
      sessionSequence === assistantSessionSequence &&
      requestAssistantId === props.assistantId &&
      requestSequence === playgroundRequestSequence
    ) {
      isLoading.value = false;
    }
  }
};

const handleEnterKey = event => {
  if (event.isComposing) return;
  event.preventDefault();
  sendMessage();
};

onMounted(loadPlaygroundSettings);
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
          <div v-if="message.responseLatencyMs != null" class="mt-2">
            <p class="text-xs font-medium text-n-slate-12">
              {{ t('CAPTAIN.PLAYGROUND.RESPONSE_LATENCY') }}
            </p>
            <p class="mt-1 text-xs text-n-slate-11">
              {{
                t('CAPTAIN.PLAYGROUND.RESPONSE_LATENCY_VALUE', {
                  ms: message.responseLatencyMs,
                })
              }}
            </p>
          </div>
          <div v-if="message.reportedReasoningTokens" class="mt-2">
            <p class="text-xs font-medium text-n-slate-12">
              {{ t('CAPTAIN.PLAYGROUND.REPORTED_REASONING_TOKENS') }}
            </p>
            <p class="mt-1 text-xs text-n-slate-11">
              {{ message.reportedReasoningTokens }}
            </p>
          </div>
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

    <section
      v-if="assistant?.usage_mode !== 'internal_assistant'"
      class="rounded-xl border border-n-weak bg-n-solid-1 p-4"
      data-test="playground-test-settings"
    >
      <h4 class="text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN.PLAYGROUND.TEST_SETTINGS') }}
      </h4>
      <p class="mt-1 text-xs text-n-slate-11">
        {{ t('CAPTAIN.PLAYGROUND.TEST_SETTINGS_DESCRIPTION') }}
      </p>
      <p
        v-if="isLoadingSettings"
        class="mt-2 text-xs text-n-slate-11"
        role="status"
      >
        {{ t('CAPTAIN_SETTINGS.LOADING') }}
      </p>
      <div v-if="settingsFailed" class="mt-2 flex flex-wrap items-center gap-3">
        <p class="m-0 text-xs text-n-ruby-9" role="alert">
          {{ t('CAPTAIN.PLAYGROUND.TEST_SETTINGS_ERROR') }}
        </p>
        <button
          type="button"
          class="text-xs font-medium text-n-brand hover:underline"
          @click="loadPlaygroundSettings(props.assistantId, { force: true })"
        >
          {{ t('DESIGN_SYSTEM.STATE.RETRY') }}
        </button>
      </div>
      <div class="mt-3 grid gap-4 md:grid-cols-3">
        <label class="flex min-w-0 flex-col gap-1 text-xs text-n-slate-11">
          {{ t('CAPTAIN.PLAYGROUND.TEST_MODEL') }}
          <Select
            v-model="selectedModel"
            :options="modelOptions"
            :disabled="isLoadingSettings || settingsFailed"
            class="w-full"
          />
        </label>
        <div class="flex min-w-0 flex-col gap-1">
          <label
            class="flex items-center justify-between gap-3 text-xs text-n-slate-11"
          >
            <span>{{ t('CAPTAIN.PLAYGROUND.TEST_TEMPERATURE') }}</span>
            <input
              v-model="temperatureOverrideEnabled"
              type="checkbox"
              :disabled="
                isLoadingSettings || settingsFailed || !supportsTemperature
              "
            />
          </label>
          <div class="flex items-center gap-3">
            <input
              v-model.number="testTemperature"
              type="range"
              min="0"
              max="1"
              step="0.1"
              class="min-w-0 flex-1 accent-n-brand disabled:cursor-not-allowed"
              :disabled="!temperatureOverrideEnabled || !supportsTemperature"
            />
            <span class="w-10 text-right text-xs tabular-nums text-n-slate-11">
              {{
                temperatureOverrideEnabled
                  ? formattedTemperature
                  : savedTemperature.toFixed(1)
              }}
            </span>
          </div>
          <p v-if="!supportsTemperature" class="m-0 text-xs text-n-slate-10">
            {{ t('CAPTAIN.PLAYGROUND.UNSUPPORTED_TEMPERATURE') }}
          </p>
        </div>
        <label class="flex min-w-0 flex-col gap-1 text-xs text-n-slate-11">
          {{ t('CAPTAIN.PLAYGROUND.TEST_REASONING_EFFORT') }}
          <Select
            v-model="thinkingEffort"
            :options="reasoningEffortOptions"
            :disabled="
              isLoadingSettings || settingsFailed || !supportsReasoning
            "
            class="w-full"
          />
          <span v-if="!supportsReasoning" class="text-xs text-n-slate-10">
            {{ t('CAPTAIN.PLAYGROUND.UNSUPPORTED_REASONING') }}
          </span>
        </label>
      </div>
    </section>

    <p class="text-center text-xs text-n-slate-11">
      {{ t('CAPTAIN.PLAYGROUND.CREDIT_NOTE') }}
    </p>
  </div>
</template>
