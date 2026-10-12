<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import ToggleSwitch from 'dashboard/components-next/switch/Switch.vue';
import MessageList from './MessageList.vue';
import ModelSettings from './ModelSettings.vue';
import PlaygroundScenarioEditor from './PlaygroundScenarioEditor.vue';
import CaptainAssistant from 'dashboard/api/captain/assistant';
import { useMapGetter } from 'dashboard/composables/store';
import { agentChannelSummary } from 'dashboard/helper/captainChannelMatrix';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';

const props = defineProps({
  assistantId: { type: Number, required: true },
  accountId: { type: [String, Number], default: '' },
});
const { t } = useI18n();
const configStore = useCaptainConfigStore();
const inboxes = useMapGetter('inboxes/getInboxes');
const assistant = ref(null);
// The channel whose grid decides which agents the tested agent can hand over
// to. Empty: the agent works alone (no handoffs, no council).
const selectedInboxId = ref(null);
const session = ref(null);
const agentTasks = ref([]);
const messages = ref([]);
const newMessage = ref('');
const scenarioDraft = ref({});
const scenarioExpanded = ref(false);
const selectedModel = ref('');
const temperature = ref(null);
const thinkingEffort = ref('');
const realRead = ref(false);
const realWrite = ref(false);
const isLoading = ref(false);
const isLoadingSession = ref(false);
const isLoadingSettings = ref(false);
const isUpdatingPermissions = ref(false);
const permissionsUnresolved = ref(false);
const error = ref('');
let identity = 0;
let turnSequence = 0;
let sessionSequence = 0;
let permissionEpoch = 0;
let pendingTurn = null;

const models = computed(() => configStore.getModelsForFeature('assistant'));
const profileModel = computed(
  () =>
    assistant.value?.playground_model?.id ||
    assistant.value?.config?.model ||
    configStore.getSelectedModelForFeature('assistant') ||
    ''
);
const effectiveModel = computed(
  () => selectedModel.value || profileModel.value
);
const selectedModelValue = computed({
  get: () => effectiveModel.value,
  set: value => {
    selectedModel.value = value === profileModel.value ? '' : value;
  },
});
const metadata = computed(
  () =>
    models.value.find(model => model.id === effectiveModel.value) ||
    (assistant.value?.playground_model?.id === effectiveModel.value
      ? assistant.value.playground_model
      : {})
);
const modelOptions = computed(() => {
  const options = models.value
    .filter(model => !model.current_only || model.id === profileModel.value)
    .map(model => ({
      value: model.id,
      label:
        model.id === profileModel.value
          ? `${model.display_name || model.id} (${t('CAPTAIN.PLAYGROUND.PROFILE_MODEL')})`
          : model.display_name || model.id,
    }));
  if (
    profileModel.value &&
    !options.some(option => option.value === profileModel.value)
  ) {
    options.unshift({
      value: profileModel.value,
      label: `${profileModel.value} (${t('CAPTAIN.PLAYGROUND.PROFILE_MODEL')})`,
    });
  }
  return options;
});
// Only the text channels where this agent works: it is part of their grid.
const channels = computed(() =>
  assistant.value
    ? agentChannelSummary({
        assistant: assistant.value,
        inboxes: inboxes.value || [],
      }).channels
    : []
);
const channelOptions = computed(() => [
  { value: '', label: t('CAPTAIN.PLAYGROUND.CHANNEL_NONE') },
  ...channels.value.map(channel => ({
    value: String(channel.inboxId),
    label: channel.name || `#${channel.inboxId}`,
  })),
]);
const channelDisabled = computed(
  () =>
    isLoading.value ||
    isLoadingSession.value ||
    isLoadingSettings.value ||
    isUpdatingPermissions.value ||
    !session.value
);
const messageDisabled = computed(
  () =>
    isLoading.value ||
    isLoadingSession.value ||
    isLoadingSettings.value ||
    isUpdatingPermissions.value ||
    permissionsUnresolved.value ||
    !session.value ||
    assistant.value?.usage_mode === 'internal_assistant'
);
const previews = computed(() =>
  realRead.value && realWrite.value ? session.value?.action_previews || [] : []
);
const describe = value => JSON.stringify(value, null, 2);
const actionTitle = approval => {
  const key = `CAPTAIN.PLAYGROUND.ACTIONS.${approval.tool.toUpperCase()}`;
  const label = t(key);
  return label === key
    ? approval.title || approval.tool.replaceAll('_', ' ')
    : label;
};
const targetName = record => {
  const patient = record.clinical_identity;
  return patient?.iin
    ? [patient.first_name, patient.last_name, patient.middle_name]
        .filter(Boolean)
        .join(' ')
    : record.name || `#${record.id}`;
};
const fieldLabel = key => {
  const field = scenarioDraft.value.custom_fields?.find(
    item => item.key === key
  );
  if (field) return field.label;
  const translation = `CAPTAIN.PLAYGROUND.CHANGES.${key.toUpperCase()}`;
  const label = t(translation);
  return label === translation ? key.replaceAll('_', ' ') : label;
};
const displayValue = (key, value, approval) => {
  if (value === null) return t('CAPTAIN.PLAYGROUND.FIELD_EMPTY');
  if (key.endsWith('_id') && approval.target?.[key])
    return targetName(approval.target[key]);
  return Array.isArray(value)
    ? value.join(', ')
    : String(value).replace('T', ' ');
};
const actionChanges = approval =>
  Object.entries(approval.arguments || {}).flatMap(([key, value]) => {
    if (
      key === 'patient' ||
      key === 'appointment_access_token' ||
      key === 'patient_confirmed'
    )
      return [];
    const entries =
      key === 'custom_attributes'
        ? Object.entries(value || {})
        : [[key, value]];
    return entries.map(([field, after]) => ({
      field,
      after: displayValue(field, after, approval),
      before: Object.values(approval.target || {})
        .map(record => record.appointment?.[field] ?? record[field])
        .find(item => item !== undefined),
    }));
  });
const showError = failure => {
  error.value =
    failure.response?.data?.message || t('CAPTAIN.PLAYGROUND.SESSION_ERROR');
};
const failedActionText = result => {
  if (typeof result === 'string') {
    try {
      return failedActionText(JSON.parse(result));
    } catch {
      return result || t('CAPTAIN.PLAYGROUND.ACTION_FAILED');
    }
  }
  const detail = result?.error || result?.message;
  return typeof detail === 'string' && detail
    ? detail
    : t('CAPTAIN.PLAYGROUND.ACTION_FAILED');
};
const displayAgentName = record =>
  record.agent_display_name ||
  (Number(record.agent_id) === Number(assistant.value?.id)
    ? assistant.value?.name
    : '') ||
  record.agent_name;
const acceptSession = (payload, { restoreHistory = false } = {}) => {
  if (!payload || payload.mode !== 'workspace') return;
  session.value = { ...session.value, ...payload };
  if (Array.isArray(payload.agent_tasks))
    agentTasks.value = payload.agent_tasks;
  if (payload.scenario)
    scenarioDraft.value = JSON.parse(JSON.stringify(payload.scenario));
  realRead.value = payload.real_data_read === true;
  realWrite.value = realRead.value && payload.real_data_write === true;
  if (restoreHistory && payload.message_history) {
    messages.value = payload.message_history.map(item => ({
      sender: item.role,
      content: item.content,
      agentId: item.agent_id,
      agentName: displayAgentName(item),
      agentTasks: item.agent_tasks || [],
      toolTrace: item.tool_trace,
    }));
  }
};
const loadSession = async ({
  reset = false,
  scenario,
  restoreHistory = false,
} = {}) => {
  const current = identity;
  const epoch = permissionEpoch;
  sessionSequence += 1;
  const request = sessionSequence;
  isLoadingSession.value = true;
  error.value = '';
  try {
    const { data } = await CaptainAssistant.playgroundSession({
      assistantId: props.assistantId,
      sessionId: session.value?.session_id,
      reset,
      scenario,
      inboxId: selectedInboxId.value || undefined,
    });
    if (
      current === identity &&
      request === sessionSequence &&
      epoch === permissionEpoch
    )
      acceptSession(data.playground, { restoreHistory });
  } catch (failure) {
    if (
      current === identity &&
      request === sessionSequence &&
      epoch === permissionEpoch
    )
      showError(failure);
  } finally {
    if (current === identity && request === sessionSequence)
      isLoadingSession.value = false;
  }
};
const setPermissions = async (read, write = false) => {
  if (!session.value || isUpdatingPermissions.value) return false;
  const current = identity;
  permissionEpoch += 1;
  const epoch = permissionEpoch;
  realRead.value = read;
  realWrite.value = read && write;
  // Hide pending actions immediately while the server revokes their generation.
  if (!realWrite.value) session.value.action_previews = [];
  isUpdatingPermissions.value = true;
  error.value = '';
  try {
    const { data } = await CaptainAssistant.playgroundPermissions({
      assistantId: props.assistantId,
      sessionId: session.value.session_id,
      read: realRead.value,
      write: realWrite.value,
    });
    if (current === identity && epoch === permissionEpoch) {
      acceptSession(data.playground);
      permissionsUnresolved.value = false;
      return true;
    }
  } catch (failure) {
    if (current === identity) {
      realRead.value = false;
      realWrite.value = false;
      session.value.action_previews = [];
      permissionsUnresolved.value = true;
      showError(failure);
    }
  } finally {
    if (current === identity) isUpdatingPermissions.value = false;
  }
  return false;
};
const saveScenario = () => {
  return loadSession({ scenario: scenarioDraft.value });
};
const resetConversation = async () => {
  const current = identity;
  turnSequence += 1;
  realRead.value = false;
  realWrite.value = false;
  if (session.value) {
    session.value.action_previews = [];
    if (!(await setPermissions(false, false))) return;
  }
  if (current !== identity) return;
  isLoadingSession.value = true;
  if (pendingTurn) await pendingTurn.catch(() => {});
  if (current !== identity) return;
  messages.value = [];
  agentTasks.value = [];
  newMessage.value = '';
  isLoading.value = false;
  await loadSession({ reset: true });
};
// Another channel is another grid, so the chat starts again from the tested
// agent: the server drops the agent session of the old channel, the visible
// history is cleared with it.
const changeChannel = async value => {
  const next = Number(value) || null;
  if (next === selectedInboxId.value) return;
  selectedInboxId.value = next;
  await resetConversation();
};
const channelValue = computed({
  get: () => (selectedInboxId.value ? String(selectedInboxId.value) : ''),
  set: value => {
    changeChannel(value);
  },
});
const sendMessage = async () => {
  if (!newMessage.value.trim() || messageDisabled.value) return;
  const current = identity;
  const epoch = permissionEpoch;
  turnSequence += 1;
  const request = turnSequence;
  const content = newMessage.value;
  messages.value.push({ sender: 'user', content });
  newMessage.value = '';
  isLoading.value = true;
  error.value = '';
  const flight = CaptainAssistant.playground({
    assistantId: props.assistantId,
    sessionId: session.value.session_id,
    messageContent: content,
    inboxId: selectedInboxId.value || undefined,
    testOptions: {
      model: selectedModel.value,
      temperature:
        metadata.value?.supports_temperature === true
          ? temperature.value
          : null,
      thinkingEffort: metadata.value?.reasoning_efforts?.includes(
        thinkingEffort.value
      )
        ? thinkingEffort.value
        : '',
    },
  });
  pendingTurn = flight;
  try {
    const { data } = await flight;
    if (
      current !== identity ||
      request !== turnSequence ||
      epoch !== permissionEpoch
    )
      return;
    const replyContent =
      data.error_class ||
      data.error_message ||
      data.response === 'conversation_handoff_due_to_provider_error'
        ? t('CAPTAIN.PLAYGROUND.PROVIDER_ERROR')
        : data.response || t('CAPTAIN.COPILOT.EMPTY_MESSAGE');
    messages.value.push({
      sender: 'assistant',
      content: replyContent,
      agentId: data.agent_id,
      agentName: displayAgentName(data),
      agentTasks: data.agent_tasks || [],
      reasoning: data.reasoning,
      toolTrace: data.tool_trace || [],
    });
    acceptSession(data.playground);
    if (Array.isArray(data.agent_tasks)) agentTasks.value = data.agent_tasks;
  } catch (failure) {
    if (
      current === identity &&
      request === turnSequence &&
      epoch === permissionEpoch
    )
      showError(failure);
  } finally {
    if (pendingTurn === flight) pendingTurn = null;
    if (current === identity && request === turnSequence)
      isLoading.value = false;
  }
};
const completedActionText = result => {
  let value = result;
  if (typeof value === 'string') {
    try {
      value = JSON.parse(value);
    } catch {
      value = {};
    }
  }
  value = value?.data || value || {};
  const receipt = value.provider_command_receipt;
  if (receipt?.command?.status === 'failed')
    return t('CAPTAIN.PLAYGROUND.ACTION_FAILED');
  if (
    (receipt && receipt.command?.status !== 'succeeded') ||
    (value.provider_confirmation_required === true &&
      value.provider_confirmed !== true) ||
    [
      'pending_provider_confirmation',
      'awaiting_confirmation',
      'provider_status_unknown',
    ].includes(value.status)
  )
    return t('CAPTAIN.PLAYGROUND.ACTION_PENDING');
  return t('CAPTAIN.PLAYGROUND.ACTION_COMPLETED');
};
const confirmAction = async approval => {
  if (messageDisabled.value || !realWrite.value) return;
  const current = identity;
  const epoch = permissionEpoch;
  turnSequence += 1;
  const request = turnSequence;
  isLoading.value = true;
  error.value = '';
  const flight = CaptainAssistant.confirmPlaygroundAction({
    assistantId: props.assistantId,
    sessionId: session.value.session_id,
    approval,
    inboxId: selectedInboxId.value || undefined,
  });
  pendingTurn = flight;
  try {
    const { data } = await flight;
    if (
      current !== identity ||
      request !== turnSequence ||
      epoch !== permissionEpoch
    )
      return;
    acceptSession(data.playground);
    messages.value.push({
      sender: 'assistant',
      content:
        data.success === false
          ? failedActionText(data.result)
          : completedActionText(data.result),
    });
  } catch (failure) {
    if (
      current === identity &&
      request === turnSequence &&
      epoch === permissionEpoch
    ) {
      showError(failure);
      await loadSession();
    }
  } finally {
    if (pendingTurn === flight) pendingTurn = null;
    if (current === identity && request === turnSequence)
      isLoading.value = false;
  }
};
const enter = event => {
  if (event.isComposing || event.shiftKey) return;
  event.preventDefault();
  sendMessage();
};
watch(
  () => [String(props.accountId), props.assistantId],
  async () => {
    identity += 1;
    const current = identity;
    turnSequence += 1;
    sessionSequence += 1;
    permissionEpoch += 1;
    assistant.value = null;
    session.value = null;
    selectedInboxId.value = null;
    agentTasks.value = [];
    messages.value = [];
    newMessage.value = '';
    scenarioDraft.value = {};
    selectedModel.value = '';
    temperature.value = null;
    thinkingEffort.value = '';
    realRead.value = false;
    realWrite.value = false;
    error.value = '';
    isLoading.value = false;
    isLoadingSession.value = false;
    isUpdatingPermissions.value = false;
    permissionsUnresolved.value = false;
    isLoadingSettings.value = true;
    try {
      const [, response] = await Promise.all([
        configStore.fetch({ clientMetadataOnly: true }),
        CaptainAssistant.show(props.assistantId),
      ]);
      if (current !== identity) return;
      assistant.value = response.data;
      if (configStore.uiFlags.fetchError) throw new Error('metadata');
      await loadSession({ restoreHistory: true });
    } catch (failure) {
      if (current === identity) showError(failure);
    } finally {
      if (current === identity) isLoadingSettings.value = false;
    }
  },
  { immediate: true, flush: 'sync' }
);

defineExpose({
  loadSession,
  sendMessage,
  setPermissions,
  resetConversation,
  changeChannel,
  confirmAction,
});
</script>

<template>
  <!-- Block rules: the chat column is the one framed block; the side panel
       stays unframed (a border-l on desktop) with border-t sections. -->
  <div
    class="grid h-full min-h-0 gap-4 lg:grid-cols-[minmax(0,1fr)_20rem] lg:grid-rows-[minmax(0,1fr)]"
    data-test="playground-layout"
  >
    <aside
      class="flex min-h-0 flex-col gap-4 lg:col-start-2 lg:row-start-1 lg:overflow-y-auto lg:border-l lg:border-n-weak lg:pl-4"
      data-test="playground-settings"
    >
      <div class="flex shrink-0 flex-wrap items-center justify-between gap-3">
        <h3 class="mb-0 text-heading-3 text-n-slate-12">
          {{ t('CAPTAIN.AGENT_TABS.CHECK.SIDE_TITLE') }}
        </h3>
        <Button
          icon="i-lucide-rotate-ccw"
          variant="ghost"
          color="slate"
          size="sm"
          :label="t('CAPTAIN.PLAYGROUND.RESET_SESSION')"
          :disabled="isLoadingSession || isUpdatingPermissions"
          data-test="playground-reset"
          @click="resetConversation"
        />
      </div>
      <label
        v-if="channels.length"
        class="flex min-w-0 shrink-0 flex-col gap-1 text-xs text-n-slate-11"
        data-test="playground-channel"
      >
        {{ t('CAPTAIN.PLAYGROUND.CHANNEL') }}
        <Select
          v-model="channelValue"
          class="w-full min-w-0"
          :options="channelOptions"
          :disabled="channelDisabled"
          data-test="playground-channel-select"
        />
        <span class="text-n-slate-10" data-test="playground-channel-hint">
          {{
            selectedInboxId
              ? t('CAPTAIN.PLAYGROUND.CHANNEL_GRID_HINT')
              : t('CAPTAIN.PLAYGROUND.CHANNEL_NONE_HINT')
          }}
        </span>
      </label>
      <ModelSettings
        v-model:model="selectedModelValue"
        v-model:temperature="temperature"
        v-model:effort="thinkingEffort"
        :models="modelOptions"
        :metadata="metadata"
        :disabled="isLoadingSettings"
        :default-label="t('CAPTAIN.PLAYGROUND.USE_PROFILE_SETTINGS')"
        stacked
        class="w-full shrink-0"
      />
      <section
        class="shrink-0 border-t border-n-weak pt-3"
        data-test="playground-permissions"
      >
        <div class="flex flex-wrap items-center gap-4">
          <label class="flex items-center gap-2 text-sm text-n-slate-12">
            <ToggleSwitch
              :model-value="realRead"
              :disabled="!session || isUpdatingPermissions"
              :aria-label="t('CAPTAIN.PLAYGROUND.REAL_READ')"
              data-test="playground-real-read"
              @change="setPermissions($event, false)"
            />
            {{ t('CAPTAIN.PLAYGROUND.REAL_READ') }}
          </label>
          <label
            v-if="realRead"
            class="flex items-center gap-2 text-sm text-n-slate-12"
          >
            <ToggleSwitch
              :model-value="realWrite"
              :disabled="!session || isUpdatingPermissions"
              :aria-label="t('CAPTAIN.PLAYGROUND.REAL_WRITE')"
              data-test="playground-real-write"
              @change="setPermissions(true, $event)"
            />
            {{ t('CAPTAIN.PLAYGROUND.REAL_WRITE') }}
          </label>
        </div>
        <p
          v-if="realWrite"
          class="mb-0 mt-2 text-xs font-medium text-n-amber-11"
          role="status"
          data-test="playground-write-warning"
        >
          {{ t('CAPTAIN.PLAYGROUND.WRITE_WARNING') }}
        </p>
        <p v-else class="mb-0 mt-2 text-xs text-n-slate-11">
          {{ t('CAPTAIN.PLAYGROUND.SYNTHETIC_NOTICE') }}
        </p>
        <div
          v-if="permissionsUnresolved"
          class="mt-2 flex flex-wrap items-center gap-2"
          role="alert"
        >
          <span class="text-xs text-n-ruby-11">{{
            t('CAPTAIN.PLAYGROUND.REVOCATION_UNCONFIRMED')
          }}</span>
          <Button
            size="sm"
            color="slate"
            variant="outline"
            :label="t('CAPTAIN.PLAYGROUND.REVOKE_RETRY')"
            :disabled="isUpdatingPermissions"
            data-test="playground-revoke-retry"
            @click="setPermissions(false, false)"
          />
        </div>
      </section>
      <section
        class="shrink-0 border-t border-n-weak pt-3"
        data-test="playground-scenario"
      >
        <Button
          variant="ghost"
          color="slate"
          size="sm"
          icon="i-lucide-users"
          :label="t('CAPTAIN.PLAYGROUND.SCENARIO_EDITOR')"
          :aria-expanded="scenarioExpanded"
          data-test="playground-scenario-toggle"
          @click="scenarioExpanded = !scenarioExpanded"
        />
        <div
          v-if="scenarioExpanded && session"
          class="mt-3 max-h-[min(42vh,28rem)] space-y-3 overflow-y-auto overscroll-contain pr-1"
        >
          <PlaygroundScenarioEditor
            v-model="scenarioDraft"
            :disabled="isLoading || isLoadingSession"
          />
          <Button
            :label="t('CAPTAIN.PLAYGROUND.SCENARIO_APPLY')"
            size="sm"
            :disabled="isLoading || isLoadingSession"
            data-test="playground-scenario-save"
            @click="saveScenario"
          />
        </div>
      </section>
      <section
        v-if="agentTasks.length"
        class="shrink-0 border-t border-n-weak pt-3"
        data-test="playground-agent-tasks"
      >
        <h4 class="mb-2 text-sm font-medium text-n-slate-12">
          {{ t('CAPTAIN.PLAYGROUND.AGENT_TASKS') }}
        </h4>
        <ul class="m-0 list-none space-y-3 p-0">
          <li v-for="task in agentTasks" :key="task.id" class="text-sm">
            <span class="block text-n-slate-12">{{ task.title }}</span>
            <span class="text-xs text-n-slate-11">
              {{
                t(`CAPTAIN.PLAYGROUND.TASK_STATUS.${task.status.toUpperCase()}`)
              }}
            </span>
          </li>
        </ul>
      </section>
    </aside>
    <section
      class="flex h-[70vh] min-h-[24rem] flex-col overflow-hidden rounded-xl outline outline-1 -outline-offset-1 outline-n-weak lg:col-start-1 lg:row-start-1 lg:h-auto lg:min-h-0"
      data-test="playground-chat"
    >
      <p
        v-if="error"
        class="mb-0 shrink-0 border-b border-n-weak px-4 py-2 text-sm text-n-ruby-11"
        role="alert"
      >
        {{ error }}
      </p>
      <MessageList
        :messages="messages"
        :is-loading="isLoading || isLoadingSession || isLoadingSettings"
        class="pt-4"
      />
      <section
        v-if="previews.length"
        class="max-h-[min(38vh,24rem)] shrink-0 divide-y divide-n-weak overflow-y-auto border-t border-n-weak bg-n-alpha-1 px-4"
        data-test="playground-action-previews"
      >
        <div v-for="approval in previews" :key="approval.id" class="py-3">
          <h4 class="mb-2 flex items-center gap-1.5 text-sm text-n-amber-11">
            <span
              class="i-lucide-triangle-alert size-4 shrink-0"
              aria-hidden="true"
            />
            {{ actionTitle(approval) }}
          </h4>
          <p
            v-for="(record, key) in approval.target"
            :key="key"
            class="mb-1 break-words text-sm"
          >
            {{ targetName(record) }}
            <span class="text-xs text-n-slate-11">#{{ record.id }}</span>
            <template v-if="record.clinical_identity?.iin">
              <span class="ml-2 text-xs">
                {{ t('CAPTAIN.PLAYGROUND.SCENARIO_IIN') }}:
                {{ record.clinical_identity.iin }}
              </span>
            </template>
            <template v-if="record.appointment">
              <span class="block text-xs text-n-slate-11">
                {{ record.appointment.starts_at.replace('T', ' ') }} —
                {{ record.appointment.ends_at.replace('T', ' ') }}
              </span>
            </template>
          </p>
          <dl class="my-2 space-y-1 text-xs">
            <div
              v-for="change in actionChanges(approval)"
              :key="change.field"
              class="flex flex-wrap gap-x-2"
            >
              <dt class="text-n-slate-11">{{ fieldLabel(change.field) }}:</dt>
              <dd class="m-0 break-words">
                <template v-if="change.before !== undefined">
                  <span class="text-n-slate-11">
                    {{ displayValue(change.field, change.before, approval) }}
                    {{ '→' }}
                  </span>
                </template>
                {{ change.after }}
              </dd>
            </div>
          </dl>
          <details>
            <summary class="cursor-pointer text-xs text-n-slate-11">
              {{ t('CAPTAIN.PLAYGROUND.ACTION_DETAILS') }}
            </summary>
            <pre class="m-0 mt-2 max-h-40 overflow-auto text-xs">{{
              describe({
                target: approval.target,
                arguments: approval.arguments,
              })
            }}</pre>
          </details>
          <Button
            class="mt-2"
            size="sm"
            :label="t('CAPTAIN.PLAYGROUND.CONFIRM_ACTION')"
            :disabled="messageDisabled"
            data-test="playground-confirm-action"
            @click="confirmAction(approval)"
          />
        </div>
      </section>
      <form
        class="flex shrink-0 items-end gap-2 border-t border-n-weak p-3"
        data-test="playground-composer"
        @submit.prevent="sendMessage"
      >
        <textarea
          v-model="newMessage"
          rows="2"
          class="mb-0 min-w-0 flex-1 resize-none border-0 bg-transparent text-sm"
          :placeholder="t('CAPTAIN.PLAYGROUND.PLACEHOLDER')"
          :disabled="messageDisabled"
          data-test="playground-message-input"
          @keydown.enter="enter"
        />
        <Button
          type="submit"
          icon="i-lucide-send"
          size="sm"
          :label="t('CAPTAIN.PLAYGROUND.SEND')"
          :disabled="messageDisabled || !newMessage.trim()"
          data-test="playground-send"
        />
      </form>
    </section>
  </div>
</template>
