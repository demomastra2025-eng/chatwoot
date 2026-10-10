<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import MessageList from './MessageList.vue';
import ModelSettings from './ModelSettings.vue';
import PlaygroundScenarioEditor from './PlaygroundScenarioEditor.vue';
import CaptainAssistant from 'dashboard/api/captain/assistant';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';

const props = defineProps({
  assistantId: { type: Number, required: true },
  accountId: { type: [String, Number], default: '' },
});
const { t } = useI18n();
const configStore = useCaptainConfigStore();
const assistant = ref(null);
const session = ref(null);
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
const metadata = computed(
  () =>
    models.value.find(model => model.id === effectiveModel.value) ||
    (assistant.value?.playground_model?.id === effectiveModel.value
      ? assistant.value.playground_model
      : {})
);
const modelOptions = computed(() => [
  { value: '', label: t('CAPTAIN.PLAYGROUND.USE_ASSISTANT_MODEL') },
  ...models.value
    .filter(model => !model.current_only || model.id === profileModel.value)
    .map(model => ({ value: model.id, label: model.display_name || model.id })),
]);
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
const acceptSession = (payload, { restoreHistory = false } = {}) => {
  if (!payload || payload.mode !== 'workspace') return;
  session.value = { ...session.value, ...payload };
  if (payload.scenario)
    scenarioDraft.value = JSON.parse(JSON.stringify(payload.scenario));
  realRead.value = payload.real_data_read === true;
  realWrite.value = realRead.value && payload.real_data_write === true;
  if (restoreHistory && payload.message_history) {
    messages.value = payload.message_history.map(item => ({
      sender: item.role,
      content: item.content,
      agentName: item.agent_name,
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
  newMessage.value = '';
  isLoading.value = false;
  await loadSession({ reset: true });
};
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
      agentName: data.agent_name,
      reasoning: data.reasoning,
      toolTrace: data.tool_trace || [],
    });
    acceptSession(data.playground);
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
  confirmAction,
});
</script>

<template>
  <div class="flex h-full min-h-0 flex-col gap-3" data-test="playground-layout">
    <div class="flex shrink-0 flex-wrap items-start justify-between gap-3">
      <ModelSettings
        v-model:model="selectedModel"
        v-model:temperature="temperature"
        v-model:effort="thinkingEffort"
        :models="modelOptions"
        :metadata="metadata"
        :disabled="isLoadingSettings"
        :default-label="t('CAPTAIN.PLAYGROUND.USE_PROFILE_SETTINGS')"
      />
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
    <section
      class="shrink-0 rounded-lg border border-n-weak p-3"
      data-test="playground-permissions"
    >
      <div class="flex flex-wrap items-center gap-4">
        <label class="flex items-center gap-2 text-sm text-n-slate-12">
          <input
            type="checkbox"
            :checked="realRead"
            :disabled="!session || isUpdatingPermissions"
            data-test="playground-real-read"
            @change="setPermissions($event.target.checked, false)"
          />
          {{ t('CAPTAIN.PLAYGROUND.REAL_READ') }}
        </label>
        <label
          v-if="realRead"
          class="flex items-center gap-2 text-sm text-n-slate-12"
        >
          <input
            type="checkbox"
            :checked="realWrite"
            :disabled="!session || isUpdatingPermissions"
            data-test="playground-real-write"
            @change="setPermissions(true, $event.target.checked)"
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
      class="shrink-0 rounded-lg border border-n-weak p-3"
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
    <p v-if="error" class="mb-0 shrink-0 text-sm text-n-ruby-11" role="alert">
      {{ error }}
    </p>
    <section
      v-if="previews.length"
      class="max-h-[min(38vh,24rem)] shrink-0 space-y-3 overflow-y-auto rounded-lg border border-n-amber-6 p-3"
      data-test="playground-action-previews"
    >
      <div v-for="approval in previews" :key="approval.id">
        <h4 class="mb-2 text-sm font-medium">{{ actionTitle(approval) }}</h4>
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
        <details class="rounded bg-n-alpha-1 p-2">
          <summary class="cursor-pointer text-xs text-n-slate-11">
            {{ t('CAPTAIN.PLAYGROUND.ACTION_DETAILS') }}
          </summary>
          <pre class="m-0 mt-2 max-h-40 overflow-auto text-xs">{{
            describe({ target: approval.target, arguments: approval.arguments })
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
    <MessageList
      :messages="messages"
      :is-loading="isLoading || isLoadingSession || isLoadingSettings"
    />
    <form
      class="flex shrink-0 items-end gap-2 rounded-xl border border-n-weak bg-n-solid-1 p-3"
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
  </div>
</template>
