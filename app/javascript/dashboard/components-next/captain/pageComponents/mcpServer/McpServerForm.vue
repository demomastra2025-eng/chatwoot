<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { required, url } from '@vuelidate/validators';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';

import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';

const props = defineProps({
  mode: {
    type: String,
    default: 'create',
  },
  server: {
    type: Object,
    default: () => ({}),
  },
});

const emit = defineEmits(['submit', 'cancel']);

const { t } = useI18n();
const store = useStore();
const uiFlags = useMapGetter('captainMcpServers/getUIFlags');
const discoveredTools = ref([]);

const createInitialState = () => ({
  name: '',
  description: '',
  transport_type: 'streamable',
  request_timeout: 30,
  enabled: true,
  allowed_scopes: ['agent', 'assistant'],
  server_config_text: '{\n  "url": ""\n}',
  server_url: '',
});

const isAdvancedConfig = ref(false);

const state = reactive(createInitialState());

const simpleUrlConfig = serverUrl => ({
  url: serverUrl.trim(),
});

const stdioConfig = () => ({
  command: '',
  args: [],
  env: {},
});

const safeParseServerConfig = () => {
  try {
    return JSON.parse(state.server_config_text || '{}');
  } catch {
    return {};
  }
};

const isValidJsonConfig = value => {
  try {
    JSON.parse(value || '{}');
    return true;
  } catch {
    return false;
  }
};

const syncFromServer = server => {
  Object.assign(state, {
    ...createInitialState(),
    name: server.name || '',
    description: server.description || '',
    transport_type: server.transport_type || 'streamable',
    request_timeout: server.request_timeout || 30,
    enabled: server.enabled ?? true,
    allowed_scopes: server.allowed_scopes || ['agent', 'assistant'],
    server_config_text: JSON.stringify(server.server_config || {}, null, 2),
    server_url: server.server_config?.url || '',
  });
  isAdvancedConfig.value = !(
    Object.keys(server.server_config || {}).length <= 1 &&
    server.server_config?.url
  );
  discoveredTools.value = [];
};

watch(
  () => [props.mode, props.server],
  ([mode, server]) => {
    if (mode === 'edit' && server?.id) {
      syncFromServer(server);
    } else {
      Object.assign(state, createInitialState());
      isAdvancedConfig.value = false;
      discoveredTools.value = [];
    }
  },
  { immediate: true }
);

watch(
  () => state.transport_type,
  transportType => {
    if (transportType === 'stdio') {
      isAdvancedConfig.value = true;
      const currentConfig = safeParseServerConfig();
      if (!currentConfig.command) {
        state.server_config_text = JSON.stringify(stdioConfig(), null, 2);
      }
    }
  }
);

watch(isAdvancedConfig, advancedConfig => {
  if (advancedConfig) {
    const currentConfig = safeParseServerConfig();
    if (!currentConfig.url && state.server_url.trim()) {
      state.server_config_text = JSON.stringify(
        simpleUrlConfig(state.server_url),
        null,
        2
      );
    }
    return;
  }

  const currentConfig = safeParseServerConfig();
  state.server_url = currentConfig.url || state.server_url;
});

const rules = computed(() => {
  const baseRules = {
    name: { required },
    transport_type: { required },
  };
  if (isAdvancedConfig.value) {
    baseRules.server_config_text = { required, isValidJsonConfig };
  } else {
    baseRules.server_url = { required, url };
  }
  return baseRules;
});

const v$ = useVuelidate(rules, state);

const transportOptions = computed(() => [
  {
    value: 'streamable',
    label: t('CAPTAIN.MCP_SERVERS.FORM.TRANSPORT_TYPE.STREAMABLE'),
  },
  { value: 'sse', label: t('CAPTAIN.MCP_SERVERS.FORM.TRANSPORT_TYPE.SSE') },
  { value: 'stdio', label: t('CAPTAIN.MCP_SERVERS.FORM.TRANSPORT_TYPE.STDIO') },
]);

const isLoading = computed(() =>
  props.mode === 'edit'
    ? uiFlags.value.updatingItem
    : uiFlags.value.creatingItem
);

const isTesting = computed(() => uiFlags.value.testingServer);
const serverConfigPlaceholder = '{ "url": "https://example.com/mcp" }';

const parsedServerConfig = () => {
  if (!isAdvancedConfig.value) {
    return simpleUrlConfig(state.server_url);
  }
  try {
    return JSON.parse(state.server_config_text || '{}');
  } catch {
    throw new Error(t('CAPTAIN.MCP_SERVERS.FORM.SERVER_CONFIG.ERROR'));
  }
};

const payload = () => ({
  name: state.name,
  description: state.description,
  transport_type: state.transport_type,
  request_timeout: Number(state.request_timeout) || 30,
  enabled: state.enabled,
  allowed_scopes: state.allowed_scopes,
  server_config: parsedServerConfig(),
});

const onDiscover = async () => {
  const valid = await v$.value.$validate();
  if (!valid) {
    useAlert(t('CAPTAIN.MCP_SERVERS.FORM.VALIDATION_ERROR'));
    return;
  }

  try {
    const response = await store.dispatch('captainMcpServers/testServer', {
      mcpServer: payload(),
    });
    discoveredTools.value = response.tools || [];
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) ||
        t('CAPTAIN.MCP_SERVERS.TEST.ERROR_MESSAGE')
    );
  }
};

const onSubmit = async () => {
  const valid = await v$.value.$validate();
  if (!valid) return;

  emit('submit', payload());
};

watch(
  () => [
    state.name,
    state.transport_type,
    state.server_url,
    state.server_config_text,
    isAdvancedConfig.value,
  ],
  () => {
    discoveredTools.value = [];
  }
);
</script>

<template>
  <form class="flex flex-col gap-4" @submit.prevent="onSubmit">
    <div class="flex items-end gap-10">
      <Input
        v-model="state.name"
        class="flex-1"
        :label="t('CAPTAIN.MCP_SERVERS.FORM.NAME.LABEL')"
        :placeholder="t('CAPTAIN.MCP_SERVERS.FORM.NAME.PLACEHOLDER')"
        :message="
          v$.name.$error ? t('CAPTAIN.MCP_SERVERS.FORM.NAME.ERROR') : ''
        "
        :message-type="v$.name.$error ? 'error' : 'info'"
      />
      <div class="flex items-center gap-3 h-10 pb-0.5">
        <span class="text-heading-3 text-n-slate-12">
          {{ t('CAPTAIN.MCP_SERVERS.FORM.ENABLED.LABEL') }}
        </span>
        <Switch v-model="state.enabled" />
      </div>
    </div>
    <TextArea
      v-model="state.description"
      :label="t('CAPTAIN.MCP_SERVERS.FORM.DESCRIPTION.LABEL')"
      :placeholder="t('CAPTAIN.MCP_SERVERS.FORM.DESCRIPTION.PLACEHOLDER')"
    />
    <div class="grid grid-cols-2 gap-4">
      <div class="flex flex-col gap-1">
        <label class="mb-0.5 text-heading-3 text-n-slate-12">
          {{ t('CAPTAIN.MCP_SERVERS.FORM.TRANSPORT_TYPE.LABEL') }}
        </label>
        <ComboBox
          v-model="state.transport_type"
          input-like
          :options="transportOptions"
          :placeholder="
            t('CAPTAIN.MCP_SERVERS.FORM.TRANSPORT_TYPE.PLACEHOLDER')
          "
          :message="
            v$.transport_type.$error
              ? t('CAPTAIN.MCP_SERVERS.FORM.TRANSPORT_TYPE.ERROR')
              : ''
          "
          :has-error="v$.transport_type.$error"
        />
      </div>
      <Input
        v-model="state.request_timeout"
        type="number"
        :label="t('CAPTAIN.MCP_SERVERS.FORM.REQUEST_TIMEOUT.LABEL')"
        :placeholder="t('CAPTAIN.MCP_SERVERS.FORM.REQUEST_TIMEOUT.PLACEHOLDER')"
      />
    </div>

    <div class="flex flex-col gap-4 rounded-xl bg-n-alpha-2 p-4">
      <template v-if="isAdvancedConfig">
        <div class="flex flex-col gap-2">
          <div class="flex items-center justify-between">
            <div class="text-xs font-medium text-n-slate-11">
              {{ t('CAPTAIN.MCP_SERVERS.FORM.SERVER_CONFIG.LABEL') }}
            </div>
            <div class="flex items-center gap-2 text-sm text-n-slate-11">
              <Checkbox
                v-model="isAdvancedConfig"
                :disabled="state.transport_type === 'stdio'"
              />
              <span :class="{ 'opacity-50': state.transport_type === 'stdio' }">
                {{ t('CAPTAIN.MCP_SERVERS.FORM.SERVER_CONFIG.ADVANCED_JSON') }}
              </span>
            </div>
          </div>
          <TextArea
            v-model="state.server_config_text"
            rows="6"
            :placeholder="serverConfigPlaceholder"
            :message="
              v$.server_config_text?.$error
                ? t('CAPTAIN.MCP_SERVERS.FORM.SERVER_CONFIG.ERROR')
                : t('CAPTAIN.MCP_SERVERS.FORM.SERVER_CONFIG.HELP_TEXT')
            "
            :has-error="v$.server_config_text?.$error"
            :message-type="v$.server_config_text?.$error ? 'error' : 'info'"
          />
        </div>
      </template>

      <template v-else>
        <div class="flex flex-col gap-1.5 flex-1">
          <div class="flex items-center justify-between">
            <label class="text-xs font-medium text-n-slate-11">
              {{ t('CAPTAIN.MCP_SERVERS.FORM.SERVER_CONFIG.URL_LABEL') }}
            </label>
            <div
              class="flex items-center gap-2 text-sm text-n-slate-11 h-5 whitespace-nowrap"
            >
              <Checkbox
                v-model="isAdvancedConfig"
                :disabled="state.transport_type === 'stdio'"
              />
              <span :class="{ 'opacity-50': state.transport_type === 'stdio' }">
                {{ t('CAPTAIN.MCP_SERVERS.FORM.SERVER_CONFIG.ADVANCED_JSON') }}
              </span>
            </div>
          </div>
          <Input
            v-model="state.server_url"
            placeholder="https://example.com/mcp"
            :message="
              v$.server_url?.$error
                ? t('CAPTAIN.MCP_SERVERS.FORM.SERVER_CONFIG.URL_ERROR')
                : t('CAPTAIN.MCP_SERVERS.FORM.SERVER_CONFIG.HELP_TEXT')
            "
            :has-error="v$.server_url?.$error"
            :message-type="v$.server_url?.$error ? 'error' : 'info'"
          />
        </div>
      </template>
    </div>
    <div class="flex flex-col gap-2">
      <div class="text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN.MCP_SERVERS.FORM.ALLOWED_SCOPES.LABEL') }}
      </div>
      <div class="flex flex-wrap gap-4">
        <label class="flex items-center gap-2 text-sm text-n-slate-12">
          <Checkbox v-model:model-value="state.allowed_scopes" value="agent" />
          <span>{{ t('CAPTAIN.MCP_SERVERS.SCOPES.AGENT') }}</span>
        </label>
        <label class="flex items-center gap-2 text-sm text-n-slate-12">
          <Checkbox
            v-model:model-value="state.allowed_scopes"
            value="assistant"
          />
          <span>{{ t('CAPTAIN.MCP_SERVERS.SCOPES.ASSISTANT') }}</span>
        </label>
      </div>
    </div>
    <div class="flex items-center justify-between gap-2 mt-2">
      <Button
        type="button"
        variant="faded"
        color="blue"
        :label="t('CAPTAIN.MCP_SERVERS.TEST.ACTION')"
        :is-loading="isTesting"
        @click="onDiscover"
      />
      <div class="flex items-center gap-2">
        <Button
          type="button"
          variant="faded"
          color="slate"
          :label="t('CAPTAIN.FORM.CANCEL')"
          @click="emit('cancel')"
        />
        <Button
          type="submit"
          :label="
            props.mode === 'edit'
              ? t('CAPTAIN.FORM.EDIT')
              : t('CAPTAIN.FORM.CREATE')
          "
          :is-loading="isLoading"
        />
      </div>
    </div>
    <div
      v-if="discoveredTools.length"
      class="flex flex-col gap-3 rounded-xl bg-n-blue-1 border border-n-blue-2 p-4"
    >
      <div class="text-sm font-medium text-n-blue-12 flex items-center gap-2">
        <i class="i-lucide-check-circle-2 w-4 h-4" />
        {{
          t('CAPTAIN.MCP_SERVERS.TEST.RESULT_TITLE', {
            count: discoveredTools.length,
          })
        }}
      </div>
      <div class="grid grid-cols-1 gap-2">
        <div
          v-for="tool in discoveredTools"
          :key="tool.id"
          class="rounded-lg bg-white border border-n-blue-3 px-3 py-2 shadow-sm"
        >
          <div class="text-sm font-semibold text-n-slate-12">
            {{ tool.title }}
          </div>
          <div v-if="tool.description" class="text-xs text-n-slate-11 mt-0.5">
            {{ tool.description }}
          </div>
        </div>
      </div>
    </div>
  </form>
</template>
