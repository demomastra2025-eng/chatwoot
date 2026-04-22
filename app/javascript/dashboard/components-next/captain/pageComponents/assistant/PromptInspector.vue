<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import CaptainAssistantAPI from 'dashboard/api/captain/assistant';
import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
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
  showCopilotSection: {
    type: Boolean,
    default: true,
  },
  showScenariosSection: {
    type: Boolean,
    default: true,
  },
});

const { t } = useI18n();

const preview = ref(null);
const isLoading = ref(false);
const loadError = ref(false);

const assistantPreview = computed(() =>
  props.showAssistantSection ? preview.value?.assistant : null
);
const copilotPreview = computed(() =>
  props.showCopilotSection ? preview.value?.copilot : null
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
const hasCopilotUsedMetadata = computed(
  () =>
    copilotPreview.value?.used_tool_ids?.length ||
    copilotPreview.value?.used_field_ids?.length
);

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
    loadPreview();
  },
  { immediate: true }
);
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
            <pre
              class="max-h-[19rem] overflow-auto rounded-xl border border-n-weak bg-n-alpha-2 p-2.5 whitespace-pre-wrap break-words text-xs leading-5 text-n-slate-11"
            ><code>{{ assistantPreview.compiled_prompt }}</code></pre>
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
                    <pre
                      class="max-h-80 overflow-auto rounded-xl border border-n-weak bg-n-alpha-2 p-3 whitespace-pre-wrap break-words text-xs leading-5 text-n-slate-11"
                    ><code>{{ scenario.compiled_prompt }}</code></pre>
                  </div>
                </div>
              </details>
            </div>
          </div>
        </div>
      </section>

      <section
        v-if="copilotPreview"
        class="rounded-2xl border border-n-weak bg-n-solid-1"
      >
        <div class="flex flex-col gap-6 px-5 py-5 md:px-6">
          <div
            class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between"
          >
            <div class="flex min-w-0 items-center gap-2">
              <h4 class="text-sm font-medium text-n-slate-12">
                {{
                  t(
                    'CAPTAIN.ASSISTANTS.SETTINGS.PROMPT_INSPECTOR.COPILOT.TITLE'
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
              v-if="!assistantPreview"
              size="sm"
              slate
              :label="t('CAPTAIN.ASSISTANTS.SETTINGS.PROMPT_INSPECTOR.REFRESH')"
              @click="loadPreview"
            />
          </div>

          <div v-if="hasCopilotUsedMetadata" class="flex flex-col gap-3">
            <div
              v-if="copilotPreview.used_tool_ids?.length"
              class="flex flex-col gap-2"
            >
              <span
                class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
              >
                {{
                  t('CAPTAIN.ASSISTANTS.SETTINGS.PROMPT_INSPECTOR.USED_TOOLS')
                }}
              </span>
              <div class="overflow-x-auto pb-1">
                <div class="flex w-max min-w-full flex-nowrap gap-2">
                  <span
                    v-for="toolId in copilotPreview.used_tool_ids"
                    :key="toolId"
                    class="shrink-0 rounded-full bg-n-alpha-2 px-2.5 py-1 text-[11px] font-medium text-n-slate-11"
                  >
                    {{ toolId }}
                  </span>
                </div>
              </div>
            </div>

            <div
              v-if="copilotPreview.used_field_ids?.length"
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
                    v-for="fieldId in copilotPreview.used_field_ids"
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
            <span
              class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
            >
              {{
                t(
                  'CAPTAIN.ASSISTANTS.SETTINGS.PROMPT_INSPECTOR.COMPILED_PROMPT'
                )
              }}
            </span>
            <pre
              class="max-h-96 overflow-auto rounded-xl border border-n-weak bg-n-alpha-2 p-3 whitespace-pre-wrap break-words text-xs leading-5 text-n-slate-11"
            ><code>{{ copilotPreview.compiled_prompt }}</code></pre>
          </div>
        </div>
      </section>
    </template>
  </div>
</template>
