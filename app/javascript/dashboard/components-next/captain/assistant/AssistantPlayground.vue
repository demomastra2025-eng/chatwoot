<script setup>
import { computed, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import NextButton from 'dashboard/components-next/button/Button.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import MessageList from './MessageList.vue';
import PlaygroundScenarioEditor from './PlaygroundScenarioEditor.vue';
import CaptainAssistant from 'dashboard/api/captain/assistant';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';

const props = defineProps({
  assistantId: {
    type: Number,
    required: true,
  },
  accountId: {
    type: [String, Number],
    default: '',
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
const playgroundMode = ref('trial');
const playgroundSessions = ref({ trial: null, live: null });
const modeMessages = ref({ trial: [], live: [] });
const scenarioDraft = ref({});
const scenarioExpanded = ref(false);
const isLoadingSession = ref(false);
const sessionError = ref('');
const liveInboxId = ref('');
const externalDeliveryEnabled = ref(false);
const controlledTestNumber = ref('');
let sessionRequestSequence = 0;
let settingsRequestSequence = 0;
let assistantSessionSequence = 0;
let playgroundRequestSequence = 0;
const pendingPlaygroundRuns = { trial: null, live: null };

const availableModels = computed(() =>
  captainConfigStore.getModelsForFeature('assistant')
);
const assistantModelMetadata = computed(
  () => assistant.value?.playground_model
);
const assistantModel = computed(
  () =>
    assistantModelMetadata.value?.id ||
    assistant.value?.config?.model ||
    captainConfigStore.getSelectedModelForFeature('assistant') ||
    ''
);
const effectiveModel = computed(
  () => selectedModel.value || assistantModel.value
);
const effectiveModelMetadata = computed(() => {
  if (assistantModelMetadata.value?.id === effectiveModel.value) {
    return assistantModelMetadata.value;
  }

  return availableModels.value.find(model => model.id === effectiveModel.value);
});
const supportsTemperature = computed(
  () => effectiveModelMetadata.value?.supports_temperature === true
);
const supportedReasoningEfforts = computed(
  () => effectiveModelMetadata.value?.reasoning_efforts || []
);
const supportsReasoning = computed(
  () => supportedReasoningEfforts.value.length > 0
);
const selectableModels = computed(() => {
  const models = availableModels.value.filter(
    model => !model.current_only || model.id === assistantModel.value
  );
  const current = assistantModelMetadata.value;
  if (current?.id && !models.some(model => model.id === current.id)) {
    return [...models, { ...current, current_only: true }];
  }

  return models;
});
const modelOptions = computed(() => [
  {
    value: '',
    label: t('CAPTAIN.PLAYGROUND.USE_ASSISTANT_MODEL'),
  },
  ...selectableModels.value.map(model => ({
    value: model.id,
    label: model.current_only
      ? t('CAPTAIN.PLAYGROUND.CURRENT_MODEL', {
          model: model.display_name || model.id,
        })
      : model.display_name || model.id,
  })),
]);
const savedTemperature = computed(() => {
  const value = Number(assistant.value?.config?.temperature ?? 1);
  return Number.isFinite(value) ? value : 1;
});
const formattedTemperature = computed(() =>
  Number(testTemperature.value || 0).toFixed(1)
);
const activeSession = computed(() => playgroundSessions.value[playgroundMode.value]);
const liveAvailable = computed(() => playgroundSessions.value.trial?.live_available === true);
const liveInboxes = computed(() => playgroundSessions.value.trial?.inboxes || []);
const liveOptions = computed(() => ({
  inboxId: liveInboxId.value,
  deliveryEnabled: externalDeliveryEnabled.value,
  testNumber: controlledTestNumber.value,
}));
const messageDisabled = computed(() =>
  isLoading.value || isLoadingSession.value ||
  (assistant.value?.usage_mode !== 'internal_assistant' && !activeSession.value)
);

const acceptSession = payload => {
  if (!payload || payload.mode !== playgroundMode.value) return;
  playgroundSessions.value[payload.mode] = payload;
  scenarioDraft.value = JSON.parse(JSON.stringify(payload.scenario || {}));
  if (payload.mode === 'trial' && !liveInboxId.value && payload.inboxes?.length) {
    liveInboxId.value = String(payload.inboxes[0].id);
  }
};

const loadPlaygroundSession = async ({ reset = false, scenario } = {}) => {
  if (!assistant.value || assistant.value?.usage_mode === 'internal_assistant') return;
  const mode = playgroundMode.value;
  const assistantId = props.assistantId;
  const accountId = String(props.accountId);
  const sequence = ++sessionRequestSequence;
  isLoadingSession.value = true;
  sessionError.value = '';
  try {
    const { data } = await CaptainAssistant.playgroundSession({
      assistantId,
      mode,
      sessionId: playgroundSessions.value[mode]?.session_id,
      reset,
      ...(scenario ? { scenario } : {}),
      liveOptions: mode === 'live' ? liveOptions.value : {},
    });
    if (sequence !== sessionRequestSequence || mode !== playgroundMode.value || assistantId !== props.assistantId || accountId !== String(props.accountId)) return;
    acceptSession(data.playground);
    if (reset) {
      messages.value = [];
      modeMessages.value[mode] = [];
    } else if (!messages.value.length && data.playground?.message_history?.length) {
      messages.value = data.playground.message_history.map(message => ({
        sender: message.role,
        content: message.content,
        agentName: message.agent_name,
        timestamp: new Date().toISOString(),
      }));
    }
  } catch (error) {
    if (sequence === sessionRequestSequence && mode === playgroundMode.value && assistantId === props.assistantId && accountId === String(props.accountId)) {
      sessionError.value = error.response?.data?.message || t('CAPTAIN.PLAYGROUND.SESSION_ERROR');
    }
  } finally {
    if (sequence === sessionRequestSequence) isLoadingSession.value = false;
  }
};

const saveScenario = () => {
  const { contact, patient, deal, appointment } = scenarioDraft.value;
  return loadPlaygroundSession({
    scenario: playgroundMode.value === 'live' ? { contact } : { contact, patient, deal, appointment },
  });
};

const reasoningEffortOptions = computed(() => [
  { value: '', label: t('CAPTAIN.PLAYGROUND.USE_WORKSPACE_REASONING') },
  ...['none', 'low', 'medium', 'high']
    .filter(effort => supportedReasoningEfforts.value.includes(effort))
    .map(effort => ({
      value: effort,
      label: t(`CAPTAIN.PLAYGROUND.REASONING_${effort.toUpperCase()}`),
    })),
]);

const loadPlaygroundSettings = async (
  assistantId = props.assistantId,
  { force = false } = {}
) => {
  settingsRequestSequence += 1;
  const requestSequence = settingsRequestSequence;
  const requestAccountId = String(props.accountId);
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
      assistantId !== props.assistantId ||
      requestAccountId !== String(props.accountId)
    ) {
      return;
    }

    assistant.value = response.data;
    testTemperature.value = savedTemperature.value;
    settingsFailed.value = captainConfigStore.uiFlags.fetchError === true;
  } catch {
    if (
      requestSequence === settingsRequestSequence &&
      assistantId === props.assistantId &&
      requestAccountId === String(props.accountId)
    ) {
      settingsFailed.value = true;
    }
  } finally {
    if (
      requestSequence === settingsRequestSequence &&
      assistantId === props.assistantId &&
      requestAccountId === String(props.accountId)
    ) {
      isLoadingSettings.value = false;
    }
  }
};

watch(supportsTemperature, supported => {
  if (!supported) temperatureOverrideEnabled.value = false;
});
watch(supportedReasoningEfforts, efforts => {
  if (!efforts.includes(thinkingEffort.value)) thinkingEffort.value = '';
});

const formatMessagesForApi = () =>
  messages.value.map(message => ({
    role: message.sender,
    content: message.content,
    ...(message.sender === 'assistant' && message.agentName
      ? { agent_name: message.agentName }
      : {}),
  }));

const resetConversation = async () => {
  const mode = playgroundMode.value;
  const sessionSequence = assistantSessionSequence;
  const pending = pendingPlaygroundRuns[mode];
  playgroundRequestSequence += 1;
  messages.value = [];
  modeMessages.value[mode] = [];
  newMessage.value = '';
  isLoading.value = false;
  if (assistant.value?.usage_mode === 'internal_assistant') return;
  isLoadingSession.value = true;
  // The server serializes turns. Reset after the current turn releases its session lock.
  if (pending) await pending.catch(() => {});
  if (sessionSequence !== assistantSessionSequence || mode !== playgroundMode.value) return;
  await loadPlaygroundSession({ reset: true });
};

const resetAssistantSession = () => {
  assistantSessionSequence += 1;
  playgroundRequestSequence += 1;
  sessionRequestSequence += 1;
  messages.value = [];
  newMessage.value = '';
  playgroundMode.value = 'trial';
  playgroundSessions.value = { trial: null, live: null };
  modeMessages.value = { trial: [], live: [] };
  scenarioDraft.value = {};
  scenarioExpanded.value = false;
  liveInboxId.value = '';
  externalDeliveryEnabled.value = false;
  controlledTestNumber.value = '';
  sessionError.value = '';
  isLoadingSession.value = false;
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
  () => [String(props.accountId), props.assistantId],
  ([newAccountId, newId], [oldAccountId, oldId]) => {
    if (newId === oldId && newAccountId === oldAccountId) return;

    settingsRequestSequence += 1;
    resetAssistantSession();
    loadPlaygroundSettings(newId).then(() => loadPlaygroundSession());
  },
  { flush: 'sync' }
);

watch(playgroundMode, (mode, previous) => {
  playgroundRequestSequence += 1;
  sessionRequestSequence += 1;
  modeMessages.value[previous] = [...messages.value];
  messages.value = [...modeMessages.value[mode]];
  newMessage.value = '';
  isLoading.value = false;
  sessionError.value = '';
  scenarioDraft.value = JSON.parse(JSON.stringify(playgroundSessions.value[mode]?.scenario || {}));
  if (assistant.value) loadPlaygroundSession();
});

const sendMessage = async () => {
  if (!newMessage.value.trim() || messageDisabled.value) return;

  const currentMessage = newMessage.value;
  const requestAssistantId = props.assistantId;
  const requestAccountId = String(props.accountId);
  const sessionSequence = assistantSessionSequence;
  const requestMode = playgroundMode.value;
  playgroundRequestSequence += 1;
  const requestSequence = playgroundRequestSequence;
  const messageHistory = formatMessagesForApi();
  messages.value.push({
    content: currentMessage,
    sender: 'user',
    timestamp: new Date().toISOString(),
  });
  newMessage.value = '';

  let pendingRequest;
  try {
    isLoading.value = true;
    const request = CaptainAssistant.playground({
      assistantId: requestAssistantId,
      messageContent: currentMessage,
      messageHistory,
      ...(assistant.value?.usage_mode !== 'internal_assistant'
        ? {
            mode: requestMode,
            sessionId: activeSession.value?.session_id,
            ...(requestMode === 'live'
              ? { conversationId: activeSession.value?.conversation_id, liveOptions: liveOptions.value }
              : {}),
          }
        : {}),
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
    pendingRequest = request;
    pendingPlaygroundRuns[requestMode] = request;
    const { data } = await request;

    if (
      sessionSequence !== assistantSessionSequence ||
      requestAssistantId !== props.assistantId ||
      requestAccountId !== String(props.accountId) ||
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
    acceptSession(data.playground);
  } catch (error) {
    if (
      sessionSequence !== assistantSessionSequence ||
      requestAssistantId !== props.assistantId ||
      requestAccountId !== String(props.accountId) ||
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
    if (pendingPlaygroundRuns[requestMode] === pendingRequest) pendingPlaygroundRuns[requestMode] = null;
    if (
      sessionSequence === assistantSessionSequence &&
      requestAssistantId === props.assistantId &&
      requestAccountId === String(props.accountId) &&
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

onMounted(async () => {
  await loadPlaygroundSettings();
  await loadPlaygroundSession();
});
</script>

<template>
  <div
    class="flex h-full min-h-0 flex-col gap-4 overflow-y-auto"
    data-test="playground-layout"
  >
    <div class="flex shrink-0 items-start justify-between gap-4 px-1">
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
        :disabled="isLoadingSession"
        :aria-label="t('CAPTAIN.PLAYGROUND.RESET_TRIAL')"
        @click="resetConversation"
      />
    </div>

    <section
      v-if="assistant?.usage_mode !== 'internal_assistant'"
      class="shrink-0 rounded-xl border border-n-weak bg-n-solid-1 p-3"
      data-test="playground-scenario"
    >
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="flex gap-1 rounded-lg bg-n-alpha-1 p-1" role="group" :aria-label="t('CAPTAIN.PLAYGROUND.MODE')">
          <button v-for="mode in ['trial', 'live']" :key="mode" type="button"
            class="rounded-md px-3 py-1.5 text-xs font-medium"
            :class="playgroundMode === mode ? 'bg-n-solid-2 text-n-slate-12 shadow-sm' : 'text-n-slate-11'"
            :data-test="`playground-mode-${mode}`"
            :aria-pressed="playgroundMode === mode"
            :disabled="mode === 'live' && !liveAvailable"
            @click="playgroundMode = mode">
            {{ t(`CAPTAIN.PLAYGROUND.MODE_${mode.toUpperCase()}`) }}
          </button>
        </div>
        <button type="button" class="flex items-center gap-2 text-xs font-medium text-n-slate-11"
          data-test="playground-scenario-toggle" :aria-expanded="scenarioExpanded" @click="scenarioExpanded = !scenarioExpanded">
          {{ t('CAPTAIN.PLAYGROUND.SCENARIO_DATA') }}
          <span :class="scenarioExpanded ? 'i-lucide-chevron-up' : 'i-lucide-chevron-down'" />
        </button>
      </div>
      <p v-if="playgroundMode === 'live'" class="mb-0 mt-2 rounded-lg bg-n-amber-3 px-3 py-2 text-xs text-n-amber-11" role="status" data-test="playground-live-warning">
        {{ t('CAPTAIN.PLAYGROUND.LIVE_WARNING') }}
      </p>
      <p v-else class="mb-0 mt-2 text-xs text-n-slate-10">{{ t('CAPTAIN.PLAYGROUND.TRIAL_DESCRIPTION') }}</p>
      <div v-if="playgroundMode === 'live'" class="mt-3 flex flex-wrap items-center gap-3">
        <label class="flex min-w-0 flex-1 flex-col gap-1 text-xs text-n-slate-11">
          {{ t('CAPTAIN.PLAYGROUND.LIVE_INBOX') }}
          <select v-model="liveInboxId" class="mb-0 rounded-lg border border-n-weak bg-n-background text-sm text-n-slate-12"
            :disabled="isLoading || isLoadingSession || !!activeSession" data-test="playground-live-inbox">
            <option v-for="inbox in liveInboxes" :key="inbox.id" :value="String(inbox.id)">{{ inbox.name }}</option>
          </select>
        </label>
        <label class="flex items-center gap-2 text-xs text-n-slate-11">
          <input v-model="externalDeliveryEnabled" type="checkbox" :disabled="isLoading || isLoadingSession" data-test="playground-external-delivery" />
          {{ t('CAPTAIN.PLAYGROUND.EXTERNAL_DELIVERY') }}
        </label>
        <label v-if="externalDeliveryEnabled" class="flex min-w-0 flex-col gap-1 text-xs text-n-slate-11">
          {{ t('CAPTAIN.PLAYGROUND.CONTROLLED_NUMBER') }}
          <input v-model="controlledTestNumber" type="tel" class="mb-0 rounded-lg border border-n-weak bg-n-background text-sm text-n-slate-12" data-test="playground-controlled-number" />
        </label>
      </div>
      <p v-if="isLoadingSession" class="mb-0 mt-2 text-xs text-n-slate-11" role="status">{{ t('CAPTAIN_SETTINGS.LOADING') }}</p>
      <div v-if="sessionError" class="mt-2 flex flex-wrap items-center gap-3">
        <p class="mb-0 text-xs text-n-ruby-9" role="alert">{{ sessionError }}</p>
        <button type="button" class="text-xs font-medium text-n-brand hover:underline" data-test="playground-session-retry" @click="loadPlaygroundSession()">
          {{ t('DESIGN_SYSTEM.STATE.RETRY') }}
        </button>
      </div>
      <div v-if="scenarioExpanded && activeSession" class="mt-3">
        <p class="mb-3 text-xs text-n-slate-10">{{ t(playgroundMode === 'trial' ? 'CAPTAIN.PLAYGROUND.MOTHER_SON_PRESET' : 'CAPTAIN.PLAYGROUND.LIVE_CALLER_DESCRIPTION') }}</p>
        <PlaygroundScenarioEditor v-model="scenarioDraft" :mode="playgroundMode" :disabled="isLoading || isLoadingSession" />
        <div class="mt-3 flex flex-wrap items-center justify-between gap-3">
          <button type="button" class="text-xs font-medium text-n-brand hover:underline" :disabled="isLoading || isLoadingSession" data-test="playground-scenario-save" @click="saveScenario">
            {{ t('CAPTAIN.PLAYGROUND.SCENARIO_SAVE') }}
          </button>
          <button v-if="playgroundMode === 'trial'" type="button" class="text-xs text-n-slate-11 hover:underline" :disabled="isLoading || isLoadingSession" data-test="playground-trial-reset" @click="resetConversation">
            {{ t('CAPTAIN.PLAYGROUND.RESET_TRIAL') }}
          </button>
        </div>
      </div>
    </section>

    <div
      class="grid shrink-0 gap-4 lg:min-h-64 lg:flex-1 lg:grid-cols-[minmax(0,1fr)_minmax(0,20rem)]"
      data-test="playground-panels"
    >
      <div
        class="flex h-80 min-h-0 min-w-0 flex-col rounded-xl border border-n-weak bg-n-solid-1 py-5 lg:h-auto"
        data-test="playground-chat"
      >
        <MessageList :messages="messages" :is-loading="isLoading" />
        <div
          class="mx-5 mt-4 flex shrink-0 items-center rounded-xl bg-n-background p-3 outline outline-1 outline-n-weak"
        >
          <input
            v-model="newMessage"
            data-test="playground-message-input"
            class="mb-0 min-w-0 flex-1 border-none bg-transparent text-sm text-n-slate-12 placeholder:text-n-slate-10 focus:outline-none"
            :placeholder="t('CAPTAIN.PLAYGROUND.MESSAGE_PLACEHOLDER')"
            @keydown.enter.exact="handleEnterKey"
          />
          <NextButton
            ghost
            sm
            :disabled="!newMessage.trim() || messageDisabled"
            icon="i-lucide-send"
            @click="sendMessage"
          />
        </div>
      </div>

      <aside
        class="max-h-80 min-h-0 min-w-0 overflow-y-auto rounded-xl border border-n-weak bg-n-solid-1 p-4 lg:max-h-none"
        data-test="playground-trace"
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
      class="shrink-0 rounded-xl border border-n-weak bg-n-solid-1 p-4"
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

    <p class="shrink-0 text-center text-xs text-n-slate-11">
      {{ t('CAPTAIN.PLAYGROUND.CREDIT_NOTE') }}
    </p>
  </div>
</template>
