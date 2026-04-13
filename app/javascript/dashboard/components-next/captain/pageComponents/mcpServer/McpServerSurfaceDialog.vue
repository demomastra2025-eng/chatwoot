<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';

const props = defineProps({
  server: {
    type: Object,
    default: () => ({}),
  },
});

const emit = defineEmits(['oauthStarted', 'oauthUpdated', 'close']);

const { t } = useI18n();
const store = useStore();
const uiFlags = useMapGetter('captainMcpServers/getUIFlags');

const dialogRef = ref(null);
const surface = ref(null);
const activeTab = ref('tools');
const argumentText = ref('{}');
const selectedResult = ref(null);
const oauthStatusOverride = ref(null);

const tabs = computed(() => [
  {
    id: 'tools',
    label: t('CAPTAIN.MCP_SERVERS.SURFACE.TABS.TOOLS'),
    count: surface.value?.tools?.length || 0,
  },
  {
    id: 'resources',
    label: t('CAPTAIN.MCP_SERVERS.SURFACE.TABS.RESOURCES'),
    count: surface.value?.resources?.length || 0,
  },
  {
    id: 'resource_templates',
    label: t('CAPTAIN.MCP_SERVERS.SURFACE.TABS.RESOURCE_TEMPLATES'),
    count: surface.value?.resource_templates?.length || 0,
  },
  {
    id: 'prompts',
    label: t('CAPTAIN.MCP_SERVERS.SURFACE.TABS.PROMPTS'),
    count: surface.value?.prompts?.length || 0,
  },
  {
    id: 'tasks',
    label: t('CAPTAIN.MCP_SERVERS.SURFACE.TABS.TASKS'),
    count: surface.value?.tasks?.length || 0,
  },
]);

const isFetching = computed(() => uiFlags.value.fetchingSurface);
const isWorking = computed(
  () => uiFlags.value.performingSurfaceAction || uiFlags.value.performingOAuth
);
const canUseOAuth = computed(() =>
  ['streamable', 'sse'].includes(props.server.transport_type)
);
const oauthStatus = computed(
  () => oauthStatusOverride.value || props.server.oauth_status || {}
);
const oauthStatusLabel = computed(() => {
  if (!oauthStatus.value?.configured) {
    return t('CAPTAIN.MCP_SERVERS.OAUTH.AVAILABLE');
  }

  return oauthStatus.value.connected
    ? t('CAPTAIN.MCP_SERVERS.OAUTH.CONNECTED')
    : t('CAPTAIN.MCP_SERVERS.OAUTH.NOT_CONNECTED');
});
const oauthActionLabel = computed(() =>
  oauthStatus.value?.connected
    ? t('CAPTAIN.MCP_SERVERS.OAUTH.RECONNECT')
    : t('CAPTAIN.MCP_SERVERS.OAUTH.CONNECT')
);
const resultText = computed(() =>
  selectedResult.value ? JSON.stringify(selectedResult.value, null, 2) : ''
);
const resultMetadata = computed(() => {
  if (!selectedResult.value || typeof selectedResult.value !== 'object') {
    return [];
  }

  const metadataKeys = [
    'name',
    'uri',
    'mime_type',
    'task_id',
    'status',
    'progress',
    'content_loaded',
  ];

  return metadataKeys
    .filter(key => selectedResult.value[key] !== undefined)
    .map(key => ({
      key,
      label: key.replaceAll('_', ' '),
      value:
        typeof selectedResult.value[key] === 'object'
          ? JSON.stringify(selectedResult.value[key])
          : String(selectedResult.value[key]),
    }));
});
const resultPreviewBlocks = computed(() => {
  if (!selectedResult.value || typeof selectedResult.value !== 'object') {
    return [];
  }

  if (Array.isArray(selectedResult.value.messages)) {
    return selectedResult.value.messages.map((message, index) => ({
      key: `message-${index}`,
      title: message.role || `message ${index + 1}`,
      body:
        typeof message.content === 'string'
          ? message.content
          : JSON.stringify(message.content, null, 2),
    }));
  }

  if (Array.isArray(selectedResult.value.content)) {
    return selectedResult.value.content.map((contentItem, index) => ({
      key: `content-${index}`,
      title:
        contentItem.mime_type ||
        contentItem.type ||
        contentItem.uri ||
        `content ${index + 1}`,
      body:
        contentItem.text ||
        contentItem.data ||
        JSON.stringify(contentItem, null, 2),
    }));
  }

  return [];
});
const resultPrimaryPreview = computed(() => {
  if (!selectedResult.value) {
    return '';
  }

  if (typeof selectedResult.value === 'string') {
    return selectedResult.value;
  }

  if (Array.isArray(selectedResult.value)) {
    return JSON.stringify(selectedResult.value, null, 2);
  }

  if (
    selectedResult.value.content &&
    !Array.isArray(selectedResult.value.content) &&
    typeof selectedResult.value.content !== 'object'
  ) {
    return String(selectedResult.value.content);
  }

  if (
    selectedResult.value.result &&
    typeof selectedResult.value.result !== 'object'
  ) {
    return String(selectedResult.value.result);
  }

  return '';
});
const formatJson = value => JSON.stringify(value || {}, null, 2);

const parseArguments = () => {
  try {
    return JSON.parse(argumentText.value || '{}');
  } catch {
    throw new Error(t('CAPTAIN.MCP_SERVERS.SURFACE.ARGUMENTS_ERROR'));
  }
};

const loadSurface = async () => {
  if (!props.server.id) return;

  selectedResult.value = null;
  try {
    surface.value = await store.dispatch('captainMcpServers/getSurface', {
      id: props.server.id,
    });
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) ||
        t('CAPTAIN.MCP_SERVERS.SURFACE.ERROR_MESSAGE')
    );
  }
};

const open = async () => {
  oauthStatusOverride.value = null;
  dialogRef.value.open();
  await loadSurface();
};

const close = () => {
  surface.value = null;
  selectedResult.value = null;
  emit('close');
};

const startOAuth = async () => {
  try {
    const response = await store.dispatch('captainMcpServers/startOAuth', {
      id: props.server.id,
      returnUrl: `${window.location.pathname}${window.location.search}`,
    });
    oauthStatusOverride.value = response.oauth_status;
    emit('oauthStarted');
    useAlert(t('CAPTAIN.MCP_SERVERS.OAUTH.STARTED'));
    window.location.assign(response.authorization_url);
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) || t('CAPTAIN.MCP_SERVERS.OAUTH.ERROR')
    );
  }
};

const disconnectOAuth = async () => {
  try {
    const response = await store.dispatch('captainMcpServers/disconnectOAuth', {
      id: props.server.id,
    });
    oauthStatusOverride.value = response.oauth_status;
    emit('oauthUpdated');
    useAlert(t('CAPTAIN.MCP_SERVERS.OAUTH.DISCONNECTED_SUCCESS'));
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) || t('CAPTAIN.MCP_SERVERS.OAUTH.ERROR')
    );
  }
};

const readResource = async resource => {
  try {
    selectedResult.value = await store.dispatch(
      'captainMcpServers/readResource',
      {
        id: props.server.id,
        uri: resource.uri,
      }
    );
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) ||
        t('CAPTAIN.MCP_SERVERS.SURFACE.ACTION_ERROR')
    );
  }
};

const fetchTemplate = async template => {
  try {
    selectedResult.value = await store.dispatch(
      'captainMcpServers/fetchResourceTemplate',
      {
        id: props.server.id,
        name: template.name,
        arguments: parseArguments(),
      }
    );
  } catch (error) {
    useAlert(
      error.message ||
        parseAPIErrorResponse(error) ||
        t('CAPTAIN.MCP_SERVERS.SURFACE.ACTION_ERROR')
    );
  }
};

const fetchPrompt = async prompt => {
  try {
    selectedResult.value = await store.dispatch(
      'captainMcpServers/fetchPrompt',
      {
        id: props.server.id,
        name: prompt.name,
        arguments: parseArguments(),
      }
    );
  } catch (error) {
    useAlert(
      error.message ||
        parseAPIErrorResponse(error) ||
        t('CAPTAIN.MCP_SERVERS.SURFACE.ACTION_ERROR')
    );
  }
};

const refreshTask = async task => {
  try {
    selectedResult.value = await store.dispatch('captainMcpServers/taskGet', {
      id: props.server.id,
      taskId: task.task_id,
    });
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) ||
        t('CAPTAIN.MCP_SERVERS.SURFACE.ACTION_ERROR')
    );
  }
};

const getTaskResult = async task => {
  try {
    selectedResult.value = await store.dispatch(
      'captainMcpServers/taskResult',
      {
        id: props.server.id,
        taskId: task.task_id,
      }
    );
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) ||
        t('CAPTAIN.MCP_SERVERS.SURFACE.ACTION_ERROR')
    );
  }
};

const cancelTask = async task => {
  try {
    selectedResult.value = await store.dispatch(
      'captainMcpServers/taskCancel',
      {
        id: props.server.id,
        taskId: task.task_id,
      }
    );
    await loadSurface();
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) ||
        t('CAPTAIN.MCP_SERVERS.SURFACE.ACTION_ERROR')
    );
  }
};

defineExpose({ open });
</script>

<template>
  <Dialog
    ref="dialogRef"
    width="3xl"
    position="top"
    :render-on-open-only="false"
    :title="t('CAPTAIN.MCP_SERVERS.SURFACE.TITLE', { name: server.name })"
    :description="t('CAPTAIN.MCP_SERVERS.SURFACE.DESCRIPTION')"
    :show-cancel-button="false"
    :show-confirm-button="false"
    overflow-y-auto
    @close="close"
  >
    <div class="flex flex-col gap-5">
      <div
        class="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-n-weak bg-n-alpha-2 p-4"
      >
        <div class="flex min-w-0 flex-col gap-1">
          <div class="flex items-center gap-2">
            <span class="text-sm font-medium text-n-slate-12">
              {{ server.transport_type }}
            </span>
            <span class="text-sm text-n-slate-11">
              {{ oauthStatusLabel }}
            </span>
          </div>
          <span class="text-sm text-n-slate-11">
            {{ t('CAPTAIN.MCP_SERVERS.SURFACE.SCOPE_HINT') }}
          </span>
        </div>
        <div class="flex items-center gap-2">
          <Button
            v-if="canUseOAuth"
            color="slate"
            size="sm"
            :label="oauthActionLabel"
            :is-loading="uiFlags.performingOAuth"
            @click="startOAuth"
          />
          <Button
            v-if="canUseOAuth && oauthStatus.connected"
            color="ruby"
            size="sm"
            :label="t('CAPTAIN.MCP_SERVERS.OAUTH.DISCONNECT')"
            :is-loading="uiFlags.performingOAuth"
            @click="disconnectOAuth"
          />
          <Button
            color="slate"
            size="sm"
            :label="t('CAPTAIN.MCP_SERVERS.SURFACE.REFRESH')"
            :is-loading="isFetching"
            @click="loadSurface"
          />
        </div>
      </div>

      <div class="flex flex-wrap gap-2">
        <button
          v-for="tab in tabs"
          :key="tab.id"
          type="button"
          class="rounded-full px-3 py-1.5 text-sm font-medium transition-colors"
          :class="
            activeTab === tab.id
              ? 'bg-n-slate-12 text-n-solid-1'
              : 'bg-n-alpha-2 text-n-slate-11 hover:bg-n-alpha-3'
          "
          @click="activeTab = tab.id"
        >
          {{ tab.label }}
          <span class="opacity-70">{{ tab.count }}</span>
        </button>
      </div>

      <div
        v-if="isFetching"
        class="rounded-xl bg-n-alpha-2 p-6 text-sm text-n-slate-11"
      >
        {{ t('CAPTAIN.MCP_SERVERS.SURFACE.LOADING') }}
      </div>

      <div v-else class="grid gap-4 md:grid-cols-[minmax(0,1fr)_18rem]">
        <div class="flex min-w-0 flex-col gap-3">
          <template v-if="activeTab === 'tools'">
            <div
              v-for="tool in surface?.tools || []"
              :key="tool.id"
              class="rounded-xl border border-n-weak bg-n-solid-1 p-4"
            >
              <div class="font-medium text-n-slate-12">{{ tool.title }}</div>
              <div class="mt-1 text-sm text-n-slate-11">
                {{ tool.description }}
              </div>
              <pre
                class="mt-3 overflow-auto rounded-lg bg-n-alpha-2 p-3 text-xs text-n-slate-11"
                >{{ formatJson(tool.input_schema) }}
              </pre>
            </div>
          </template>

          <template v-if="activeTab === 'resources'">
            <div
              v-for="resource in surface?.resources || []"
              :key="resource.uri"
              class="rounded-xl border border-n-weak bg-n-solid-1 p-4"
            >
              <div class="font-medium text-n-slate-12">{{ resource.name }}</div>
              <div class="mt-1 break-all text-xs text-n-slate-10">
                {{ resource.uri }}
              </div>
              <div class="mt-1 text-sm text-n-slate-11">
                {{ resource.description }}
              </div>
              <Button
                class="mt-3"
                size="sm"
                color="slate"
                :label="t('CAPTAIN.MCP_SERVERS.SURFACE.READ_RESOURCE')"
                :is-loading="isWorking"
                @click="readResource(resource)"
              />
            </div>
          </template>

          <template v-if="activeTab === 'resource_templates'">
            <TextArea
              v-model="argumentText"
              rows="4"
              :label="t('CAPTAIN.MCP_SERVERS.SURFACE.ARGUMENTS_LABEL')"
              :message="t('CAPTAIN.MCP_SERVERS.SURFACE.ARGUMENTS_HELP')"
            />
            <div
              v-for="template in surface?.resource_templates || []"
              :key="template.name"
              class="rounded-xl border border-n-weak bg-n-solid-1 p-4"
            >
              <div class="font-medium text-n-slate-12">{{ template.name }}</div>
              <div class="mt-1 break-all text-xs text-n-slate-10">
                {{ template.uri_template }}
              </div>
              <div class="mt-1 text-sm text-n-slate-11">
                {{ template.description }}
              </div>
              <Button
                class="mt-3"
                size="sm"
                color="slate"
                :label="t('CAPTAIN.MCP_SERVERS.SURFACE.FETCH_TEMPLATE')"
                :is-loading="isWorking"
                @click="fetchTemplate(template)"
              />
            </div>
          </template>

          <template v-if="activeTab === 'prompts'">
            <TextArea
              v-model="argumentText"
              rows="4"
              :label="t('CAPTAIN.MCP_SERVERS.SURFACE.ARGUMENTS_LABEL')"
              :message="t('CAPTAIN.MCP_SERVERS.SURFACE.ARGUMENTS_HELP')"
            />
            <div
              v-for="prompt in surface?.prompts || []"
              :key="prompt.name"
              class="rounded-xl border border-n-weak bg-n-solid-1 p-4"
            >
              <div class="font-medium text-n-slate-12">{{ prompt.name }}</div>
              <div class="mt-1 text-sm text-n-slate-11">
                {{ prompt.description }}
              </div>
              <div class="mt-2 flex flex-wrap gap-1">
                <span
                  v-for="argument in prompt.arguments"
                  :key="argument.name"
                  class="rounded-full bg-n-alpha-2 px-2 py-0.5 text-xs text-n-slate-11"
                >
                  {{ argument.name }}
                </span>
              </div>
              <Button
                class="mt-3"
                size="sm"
                color="slate"
                :label="t('CAPTAIN.MCP_SERVERS.SURFACE.FETCH_PROMPT')"
                :is-loading="isWorking"
                @click="fetchPrompt(prompt)"
              />
            </div>
          </template>

          <template v-if="activeTab === 'tasks'">
            <div
              v-for="task in surface?.tasks || []"
              :key="task.task_id"
              class="rounded-xl border border-n-weak bg-n-solid-1 p-4"
            >
              <div class="font-medium text-n-slate-12">{{ task.task_id }}</div>
              <div class="mt-1 text-sm text-n-slate-11">{{ task.status }}</div>
              <div class="mt-3 flex flex-wrap gap-2">
                <Button
                  size="sm"
                  color="slate"
                  :label="t('CAPTAIN.MCP_SERVERS.SURFACE.REFRESH_TASK')"
                  :is-loading="isWorking"
                  @click="refreshTask(task)"
                />
                <Button
                  size="sm"
                  color="slate"
                  :label="t('CAPTAIN.MCP_SERVERS.SURFACE.TASK_RESULT')"
                  :is-loading="isWorking"
                  @click="getTaskResult(task)"
                />
                <Button
                  size="sm"
                  color="ruby"
                  :label="t('CAPTAIN.MCP_SERVERS.SURFACE.CANCEL_TASK')"
                  :is-loading="isWorking"
                  @click="cancelTask(task)"
                />
              </div>
            </div>
          </template>
        </div>

        <aside class="min-w-0 rounded-xl border border-n-weak bg-n-alpha-2 p-4">
          <div class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.MCP_SERVERS.SURFACE.RESULT_TITLE') }}
          </div>
          <div v-if="resultMetadata.length" class="mt-3 flex flex-wrap gap-2">
            <span
              v-for="item in resultMetadata"
              :key="item.key"
              class="rounded-full bg-n-solid-1 px-2.5 py-1 text-xs text-n-slate-11"
            >
              {{ `${item.label}: ${item.value}` }}
            </span>
          </div>
          <div
            v-if="resultPreviewBlocks.length"
            class="mt-3 flex max-h-80 flex-col gap-3 overflow-auto"
          >
            <div
              v-for="block in resultPreviewBlocks"
              :key="block.key"
              class="rounded-xl border border-n-weak bg-n-solid-1 p-3"
            >
              <div
                class="text-xs font-medium uppercase tracking-[0.08em] text-n-slate-10"
              >
                {{ block.title }}
              </div>
              <pre
                class="mt-2 whitespace-pre-wrap break-words text-xs text-n-slate-11"
              >
                {{ block.body }}
              </pre>
            </div>
          </div>
          <pre
            v-else-if="resultPrimaryPreview"
            class="mt-3 max-h-56 overflow-auto whitespace-pre-wrap break-words rounded-xl border border-n-weak bg-n-solid-1 p-3 text-xs text-n-slate-11"
          >
            {{ resultPrimaryPreview }}
          </pre>
          <pre
            class="mt-3 max-h-80 overflow-auto whitespace-pre-wrap break-words rounded-xl border border-n-weak bg-n-solid-1 p-3 text-xs text-n-slate-11"
            >{{ resultText || t('CAPTAIN.MCP_SERVERS.SURFACE.RESULT_EMPTY') }}
          </pre>
        </aside>
      </div>
    </div>
    <template #footer />
  </Dialog>
</template>
