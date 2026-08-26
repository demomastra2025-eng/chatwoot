<script setup>
import { computed, ref, watch, onMounted, onBeforeUnmount } from 'vue';
import { useI18n } from 'vue-i18n';

import CaptainAssistantAPI from 'dashboard/api/captain/assistant';
import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import { normalizePromptPreviewText } from 'dashboard/helper/captainPromptPreview';
import SettingsInfoDialog from './settings/SettingsInfoDialog.vue';

const props = defineProps({
  assistantId: {
    type: Number,
    default: null,
  },
  assistant: {
    type: Object,
    default: () => ({}),
  },
  showAssistantSection: {
    type: Boolean,
    default: true,
  },

  showScenariosSection: {
    type: Boolean,
    default: true,
  },
});

const { t } = useI18n();

const PROMPT_HEIGHT_STORAGE_PREFIX = 'captain:prompt-preview-height:';
const DEFAULT_PROMPT_HEIGHT = 360;
const MIN_PROMPT_HEIGHT = 192;
const MAX_PROMPT_HEIGHT = 1400;

const preview = ref(null);
const isLoading = ref(false);
const loadError = ref(false);
const promptHeights = ref({});
const resizingPrompt = ref(null);
const resizeStartY = ref(0);
const resizeStartHeight = ref(DEFAULT_PROMPT_HEIGHT);

const assistantPreview = computed(() =>
  props.showAssistantSection ? preview.value?.assistant : null
);

const scenarioPreviews = computed(() =>
  props.showScenariosSection ? preview.value?.scenarios || [] : []
);
const previewInfoPoints = computed(() => [
  t('CAPTAIN.ASSISTANTS.SETTINGS.PROMPT_INSPECTOR.INFO_POINTS.NO_LIVE_CONTEXT'),
  t('CAPTAIN.ASSISTANTS.SETTINGS.PROMPT_INSPECTOR.INFO_POINTS.RUNTIME_ACCESS'),
  t('CAPTAIN.ASSISTANTS.SETTINGS.PROMPT_INSPECTOR.INFO_POINTS.COMPILED_OUTPUT'),
]);
const hasAssistantUsedMetadata = computed(
  () =>
    assistantPreview.value?.used_tool_ids?.length ||
    assistantPreview.value?.used_field_ids?.length
);

const clampPromptHeight = height =>
  Math.min(
    Math.max(Number(height) || DEFAULT_PROMPT_HEIGHT, MIN_PROMPT_HEIGHT),
    MAX_PROMPT_HEIGHT
  );

const promptStorageKey = key =>
  `${PROMPT_HEIGHT_STORAGE_PREFIX}${props.assistantId || 'new'}:${key}`;

const readStoredPromptHeight = key => {
  try {
    return window.localStorage.getItem(promptStorageKey(key));
  } catch {
    return null;
  }
};

const writeStoredPromptHeight = (key, height) => {
  try {
    window.localStorage.setItem(promptStorageKey(key), String(height));
  } catch {
    // Storage can be unavailable in private/locked-down browser contexts.
  }
};

const removeStoredPromptHeight = key => {
  try {
    window.localStorage.removeItem(promptStorageKey(key));
  } catch {
    // Storage can be unavailable in private/locked-down browser contexts.
  }
};

const getPromptHeight = key => {
  if (!promptHeights.value[key]) {
    promptHeights.value[key] = clampPromptHeight(
      readStoredPromptHeight(key) || DEFAULT_PROMPT_HEIGHT
    );
  }
  return promptHeights.value[key];
};

const promptPreviewStyle = key => ({
  height: `${getPromptHeight(key)}px`,
});

const getClientY = event => event.touches?.[0]?.clientY || event.clientY;

const clearResizeStyles = () => {
  Object.assign(document.body.style, { cursor: '', userSelect: '' });
};

const startPromptResize = (event, key) => {
  resizingPrompt.value = key;
  resizeStartY.value = getClientY(event);
  resizeStartHeight.value = getPromptHeight(key);
  Object.assign(document.body.style, {
    cursor: 'row-resize',
    userSelect: 'none',
  });
};

const onPromptResizeMove = event => {
  if (!resizingPrompt.value) return;
  if (event.touches) event.preventDefault();

  const nextHeight = clampPromptHeight(
    resizeStartHeight.value + getClientY(event) - resizeStartY.value
  );
  promptHeights.value = {
    ...promptHeights.value,
    [resizingPrompt.value]: nextHeight,
  };
};

const onPromptResizeEnd = () => {
  if (!resizingPrompt.value) return;

  const key = resizingPrompt.value;
  writeStoredPromptHeight(key, getPromptHeight(key));
  resizingPrompt.value = null;
  clearResizeStyles();
};

const resetPromptHeight = key => {
  promptHeights.value = {
    ...promptHeights.value,
    [key]: DEFAULT_PROMPT_HEIGHT,
  };
  removeStoredPromptHeight(key);
};

const loadPreview = async () => {
  if (!props.assistantId) {
    preview.value = null;
    return;
  }

  isLoading.value = true;
  loadError.value = false;

  try {
    const { data } = await CaptainAssistantAPI.promptPreview(props.assistantId);
    preview.value = data;
  } catch (error) {
    preview.value = null;
    loadError.value = true;
  } finally {
    isLoading.value = false;
  }
};

watch(
  () => [props.assistantId, props.assistant?.updated_at],
  () => {
    promptHeights.value = {};
    loadPreview();
  },
  { immediate: true }
);

onMounted(() => {
  window.addEventListener('mousemove', onPromptResizeMove);
  window.addEventListener('mouseup', onPromptResizeEnd);
  window.addEventListener('touchmove', onPromptResizeMove, { passive: false });
  window.addEventListener('touchend', onPromptResizeEnd);
  window.addEventListener('touchcancel', onPromptResizeEnd);
});

onBeforeUnmount(() => {
  window.removeEventListener('mousemove', onPromptResizeMove);
  window.removeEventListener('mouseup', onPromptResizeEnd);
  window.removeEventListener('touchmove', onPromptResizeMove);
  window.removeEventListener('touchend', onPromptResizeEnd);
  window.removeEventListener('touchcancel', onPromptResizeEnd);
  clearResizeStyles();
});
</script>

<template>
  <div class="flex min-w-0 flex-col gap-4">
    <div
      v-if="isLoading"
      class="rounded-2xl border border-n-weak bg-n-solid-1 px-4 py-6 text-sm text-n-slate-11"
    >
      <div class="flex items-center gap-3">
        <Spinner />
        <span>
          {{ t('CAPTAIN.ASSISTANTS.SETTINGS.PROMPT_INSPECTOR.LOADING') }}
        </span>
      </div>
    </div>

    <div
      v-else-if="loadError"
      class="rounded-2xl border border-n-weak bg-n-solid-1 px-4 py-4 text-sm text-n-slate-11"
    >
      <div class="flex flex-col gap-3">
        <span>
          {{ t('CAPTAIN.ASSISTANTS.SETTINGS.PROMPT_INSPECTOR.ERROR') }}
        </span>
        <div>
          <Button
            size="sm"
            slate
            :label="t('CAPTAIN.ASSISTANTS.SETTINGS.PROMPT_INSPECTOR.REFRESH')"
            @click="loadPreview"
          />
        </div>
      </div>
    </div>

    <div
      v-else-if="!preview"
      class="rounded-2xl border border-n-weak bg-n-solid-1 px-4 py-4 text-sm text-n-slate-11"
    >
      {{ t('CAPTAIN.ASSISTANTS.SETTINGS.PROMPT_INSPECTOR.EMPTY') }}
    </div>

    <template v-else>
      <section
        v-if="assistantPreview"
        class="rounded-2xl border border-n-weak bg-n-solid-1"
      >
        <div class="flex flex-col gap-4 px-4 py-4 md:px-5">
          <div
            class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between"
          >
            <div class="flex min-w-0 items-center gap-2">
              <h4 class="text-sm font-medium text-n-slate-12">
                {{
                  t(
                    'CAPTAIN.ASSISTANTS.SETTINGS.PROMPT_INSPECTOR.ASSISTANT.TITLE'
                  )
                }}
              </h4>
              <SettingsInfoDialog
                :title="
                  t('CAPTAIN.ASSISTANTS.SETTINGS.PROMPT_INSPECTOR.INFO_TITLE')
                "
                :description="
                  t(
                    'CAPTAIN.ASSISTANTS.SETTINGS.PROMPT_INSPECTOR.INFO_DESCRIPTION'
                  )
                "
                :points="previewInfoPoints"
                align="left"
              />
            </div>
            <Button
              size="sm"
              slate
              :label="t('CAPTAIN.ASSISTANTS.SETTINGS.PROMPT_INSPECTOR.REFRESH')"
              @click="loadPreview"
            />
          </div>

          <div v-if="hasAssistantUsedMetadata" class="flex flex-col gap-3">
            <div
              v-if="assistantPreview.used_tool_ids?.length"
              class="flex flex-col gap-2"
            >
              <span class="text-sm font-medium tracking-wide text-n-slate-10">
                {{
                  t('CAPTAIN.ASSISTANTS.SETTINGS.PROMPT_INSPECTOR.USED_TOOLS')
                }}
              </span>
              <div class="overflow-x-auto pb-1">
                <div class="flex w-max min-w-full flex-nowrap gap-1.5">
                  <span
                    v-for="toolId in assistantPreview.used_tool_ids"
                    :key="toolId"
                    class="shrink-0 rounded-full bg-n-alpha-2 px-2.5 py-1 text-[11px] font-medium text-n-slate-11"
                  >
                    {{ toolId }}
                  </span>
                </div>
              </div>
            </div>

            <div
              v-if="assistantPreview.used_field_ids?.length"
              class="flex flex-col gap-2"
            >
              <span class="text-sm font-medium tracking-wide text-n-slate-10">
                {{
                  t(
                    'CAPTAIN.ASSISTANTS.SETTINGS.PROMPT_INSPECTOR.USED_ATTRIBUTES'
                  )
                }}
              </span>
              <div class="overflow-x-auto pb-1">
                <div class="flex w-max min-w-full flex-nowrap gap-1.5">
                  <span
                    v-for="fieldId in assistantPreview.used_field_ids"
                    :key="fieldId"
                    class="shrink-0 rounded-full bg-n-alpha-2 px-2.5 py-1 text-[11px] font-medium text-n-slate-11"
                  >
                    {{ fieldId }}
                  </span>
                </div>
              </div>
            </div>
          </div>

          <div class="flex flex-col gap-2">
            <span class="text-sm font-medium tracking-wide text-n-slate-10">
              {{
                t(
                  'CAPTAIN.ASSISTANTS.SETTINGS.PROMPT_INSPECTOR.COMPILED_PROMPT'
                )
              }}
            </span>
            <div
              class="flex min-h-[12rem] flex-col overflow-hidden rounded-xl border border-n-weak bg-n-alpha-2"
              :style="promptPreviewStyle('assistant')"
            >
              <pre
                class="min-h-0 flex-1 overflow-auto p-2.5 whitespace-pre-wrap break-words text-xs leading-5 text-n-slate-11"
              ><code>{{ normalizePromptPreviewText(assistantPreview.compiled_prompt) }}</code></pre>
              <div
                class="group flex h-5 shrink-0 cursor-row-resize select-none items-center justify-center border-t border-n-weak text-n-slate-9 hover:bg-n-alpha-2"
                :class="{
                  'bg-n-alpha-2 text-n-slate-11':
                    resizingPrompt === 'assistant',
                }"
                @mousedown="startPromptResize($event, 'assistant')"
                @touchstart.prevent="startPromptResize($event, 'assistant')"
                @dblclick="resetPromptHeight('assistant')"
              >
                <div class="h-0.5 w-10 rounded-full bg-current opacity-60" />
              </div>
            </div>
          </div>

          <div
            v-if="showScenariosSection"
            class="flex flex-col gap-4 border-t border-n-weak pt-6"
          >
            <div class="flex items-center justify-between gap-4">
              <h5 class="text-sm font-medium text-n-slate-12">
                {{
                  t(
                    'CAPTAIN.ASSISTANTS.SETTINGS.PROMPT_INSPECTOR.SCENARIOS.TITLE'
                  )
                }}
              </h5>
              <span
                class="rounded-full bg-n-alpha-2 px-2.5 py-1 text-[11px] font-medium text-n-slate-11"
              >
                {{ scenarioPreviews.length }}
              </span>
            </div>

            <div
              v-if="scenarioPreviews.length === 0"
              class="text-sm text-n-slate-11"
            >
              {{
                t(
                  'CAPTAIN.ASSISTANTS.SETTINGS.PROMPT_INSPECTOR.SCENARIOS.EMPTY'
                )
              }}
            </div>

            <div v-else class="flex flex-col gap-4">
              <details
                v-for="scenario in scenarioPreviews"
                :key="scenario.id"
                class="rounded-xl border border-n-weak"
              >
                <summary class="list-none cursor-pointer px-4 py-4">
                  <div class="flex items-start justify-between gap-4">
                    <div class="flex min-w-0 flex-col gap-1">
                      <span class="text-sm font-medium text-n-slate-12">
                        {{ scenario.title }}
                      </span>
                      <span class="text-sm text-n-slate-11">
                        {{ scenario.handoff_key }}
                      </span>
                    </div>
                  </div>
                </summary>

                <div
                  class="flex flex-col gap-4 border-t border-n-weak px-4 py-4"
                >
                  <div
                    v-if="scenario.used_tool_ids?.length"
                    class="flex flex-col gap-2"
                  >
                    <span
                      class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
                    >
                      {{
                        t(
                          'CAPTAIN.ASSISTANTS.SETTINGS.PROMPT_INSPECTOR.USED_TOOLS'
                        )
                      }}
                    </span>
                    <div class="overflow-x-auto pb-1">
                      <div class="flex w-max min-w-full flex-nowrap gap-2">
                        <span
                          v-for="toolId in scenario.used_tool_ids"
                          :key="toolId"
                          class="shrink-0 rounded-full bg-n-alpha-2 px-2.5 py-1 text-[11px] font-medium text-n-slate-11"
                        >
                          {{ toolId }}
                        </span>
                      </div>
                    </div>
                  </div>

                  <div
                    v-if="scenario.used_field_ids?.length"
                    class="flex flex-col gap-2"
                  >
                    <span
                      class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
                    >
                      {{
                        t(
                          'CAPTAIN.ASSISTANTS.SETTINGS.PROMPT_INSPECTOR.USED_ATTRIBUTES'
                        )
                      }}
                    </span>
                    <div class="overflow-x-auto pb-1">
                      <div class="flex w-max min-w-full flex-nowrap gap-2">
                        <span
                          v-for="fieldId in scenario.used_field_ids"
                          :key="fieldId"
                          class="shrink-0 rounded-full bg-n-alpha-2 px-2.5 py-1 text-[11px] font-medium text-n-slate-11"
                        >
                          {{ fieldId }}
                        </span>
                      </div>
                    </div>
                  </div>

                  <div class="flex flex-col gap-2">
                    <span
                      class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
                    >
                      {{
                        t(
                          'CAPTAIN.ASSISTANTS.SETTINGS.PROMPT_INSPECTOR.COMPILED_PROMPT'
                        )
                      }}
                    </span>
                    <div
                      class="flex min-h-[12rem] flex-col overflow-hidden rounded-xl border border-n-weak bg-n-alpha-2"
                      :style="promptPreviewStyle(`scenario-${scenario.id}`)"
                    >
                      <pre
                        class="min-h-0 flex-1 overflow-auto p-3 whitespace-pre-wrap break-words text-xs leading-5 text-n-slate-11"
                      ><code>{{ normalizePromptPreviewText(scenario.compiled_prompt) }}</code></pre>
                      <div
                        class="group flex h-5 shrink-0 cursor-row-resize select-none items-center justify-center border-t border-n-weak text-n-slate-9 hover:bg-n-alpha-2"
                        :class="{
                          'bg-n-alpha-2 text-n-slate-11':
                            resizingPrompt === `scenario-${scenario.id}`,
                        }"
                        @mousedown="
                          startPromptResize($event, `scenario-${scenario.id}`)
                        "
                        @touchstart.prevent="
                          startPromptResize($event, `scenario-${scenario.id}`)
                        "
                        @dblclick="resetPromptHeight(`scenario-${scenario.id}`)"
                      >
                        <div
                          class="h-0.5 w-10 rounded-full bg-current opacity-60"
                        />
                      </div>
                    </div>
                  </div>
                </div>
              </details>
            </div>
          </div>
        </div>
      </section>
    </template>
  </div>
</template>
