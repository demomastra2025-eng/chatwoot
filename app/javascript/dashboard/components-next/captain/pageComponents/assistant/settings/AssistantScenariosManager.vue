<script setup>
import { computed, h, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { picoSearch } from '@scmmishra/pico-search';
import { useAlert } from 'dashboard/composables';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { useMessageFormatter } from 'shared/composables/useMessageFormatter';

import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import SettingsHeader from 'dashboard/components-next/captain/pageComponents/settings/SettingsHeader.vue';
import SuggestedScenarios from 'dashboard/components-next/captain/assistant/SuggestedRules.vue';
import ScenariosCard from 'dashboard/components-next/captain/assistant/ScenariosCard.vue';
import BulkSelectBar from 'dashboard/components-next/captain/assistant/BulkSelectBar.vue';
import AddNewScenariosDialog from 'dashboard/components-next/captain/assistant/AddNewScenariosDialog.vue';

const props = defineProps({
  assistantId: {
    type: Number,
    required: true,
  },
});

const { t } = useI18n();
const store = useStore();
const { uiSettings, updateUISettings } = useUISettings();
const { formatMessage } = useMessageFormatter();

const uiFlags = useMapGetter('captainScenarios/getUIFlags');
const isFetching = computed(() => uiFlags.value.fetchingList);
const scenarios = useMapGetter('captainScenarios/getRecords');

const searchQuery = ref('');
const bulkSelectedIds = ref(new Set());
const hoveredCard = ref(null);

const LINK_INSTRUCTION_CLASS =
  '[&_a[href^="tool://"]]:text-n-iris-11 [&_a[href^="field://"]]:text-n-teal-11 [&_a:not([href^="tool://"]):not([href^="field://"])]:text-n-slate-12 [&_a]:pointer-events-none [&_a]:cursor-default';

const renderInstruction = instruction => () =>
  h('span', {
    class: `text-sm text-n-slate-12 py-4 prose prose-sm min-w-0 break-words ${LINK_INSTRUCTION_CLASS}`,
    innerHTML: instruction,
  });

const scenariosExample = [
  {
    id: 1,
    title: t(
      'CAPTAIN.ASSISTANTS.SCENARIOS.ADD.SUGGESTED.EXAMPLES.PROSPECTIVE_BUYER.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.SCENARIOS.ADD.SUGGESTED.EXAMPLES.PROSPECTIVE_BUYER.DESCRIPTION'
    ),
    instruction: t(
      'CAPTAIN.ASSISTANTS.SCENARIOS.ADD.SUGGESTED.EXAMPLES.PROSPECTIVE_BUYER.INSTRUCTION'
    ),
    tools: ['add_private_note', 'add_label_to_conversation', 'handoff'],
  },
];

const filteredScenarios = computed(() => {
  const query = searchQuery.value.trim();
  if (!query) return scenarios.value;
  return picoSearch(scenarios.value, query, [
    'title',
    'description',
    'instruction',
  ]);
});

const shouldShowSuggestedRules = computed(
  () => uiSettings.value?.show_scenarios_suggestions !== false
);

const closeSuggestedRules = () => {
  updateUISettings({ show_scenarios_suggestions: false });
};

const handleRuleSelect = id => {
  const selected = new Set(bulkSelectedIds.value);
  selected[selected.has(id) ? 'delete' : 'add'](id);
  bulkSelectedIds.value = selected;
};

const buildSelectedCountLabel = computed(() => {
  const count = scenarios.value.length || 0;
  const isAllSelected = bulkSelectedIds.value.size === count && count > 0;
  return isAllSelected
    ? t('CAPTAIN.ASSISTANTS.SCENARIOS.BULK_ACTION.UNSELECT_ALL', { count })
    : t('CAPTAIN.ASSISTANTS.SCENARIOS.BULK_ACTION.SELECT_ALL', { count });
});

const selectedCountLabel = computed(() =>
  t('CAPTAIN.ASSISTANTS.SCENARIOS.BULK_ACTION.SELECTED', {
    count: bulkSelectedIds.value.size,
  })
);

const handleRuleHover = (isHovered, id) => {
  hoveredCard.value = isHovered ? id : null;
};

const normalizeToolId = toolId => toolId?.replace(/\\(.)/g, '$1') || '';

const getToolsFromInstruction = instruction => [
  ...new Set(
    [...(instruction?.matchAll(/\(tool:\/\/([^)]+)\)/g) ?? [])].map(match =>
      normalizeToolId(match[1])
    )
  ),
];

const getScenarioErrorMessage = (error, fallbackMessage) =>
  error?.message ||
  error?.response?.data?.message ||
  error?.response?.data?.error ||
  error?.response?.message ||
  fallbackMessage;

const updateScenario = async scenario => {
  try {
    await store.dispatch('captainScenarios/update', {
      id: scenario.id,
      assistantId: props.assistantId,
      ...scenario,
      tools: getToolsFromInstruction(scenario.instruction),
    });
    useAlert(t('CAPTAIN.ASSISTANTS.SCENARIOS.API.UPDATE.SUCCESS'));
  } catch (error) {
    useAlert(
      getScenarioErrorMessage(
        error,
        t('CAPTAIN.ASSISTANTS.SCENARIOS.API.UPDATE.ERROR')
      )
    );
  }
};

const deleteScenario = async id => {
  try {
    await store.dispatch('captainScenarios/delete', {
      id,
      assistantId: props.assistantId,
    });
    useAlert(t('CAPTAIN.ASSISTANTS.SCENARIOS.API.DELETE.SUCCESS'));
  } catch (error) {
    useAlert(
      getScenarioErrorMessage(
        error,
        t('CAPTAIN.ASSISTANTS.SCENARIOS.API.DELETE.ERROR')
      )
    );
  }
};

const bulkDeleteScenarios = async ids => {
  const idsArray = ids || Array.from(bulkSelectedIds.value);
  await Promise.all(
    idsArray.map(id =>
      store.dispatch('captainScenarios/delete', {
        id,
        assistantId: props.assistantId,
      })
    )
  );
  bulkSelectedIds.value = new Set();
  useAlert(t('CAPTAIN.ASSISTANTS.SCENARIOS.API.DELETE.SUCCESS'));
};

const addScenario = async scenario => {
  try {
    await store.dispatch('captainScenarios/create', {
      assistantId: props.assistantId,
      ...scenario,
      tools: getToolsFromInstruction(scenario.instruction),
    });
    useAlert(t('CAPTAIN.ASSISTANTS.SCENARIOS.API.ADD.SUCCESS'));
  } catch (error) {
    useAlert(
      getScenarioErrorMessage(
        error,
        t('CAPTAIN.ASSISTANTS.SCENARIOS.API.ADD.ERROR')
      )
    );
  }
};

const addAllExampleScenarios = async () => {
  try {
    await Promise.all(
      scenariosExample.map(scenario =>
        store.dispatch('captainScenarios/create', {
          assistantId: props.assistantId,
          ...scenario,
        })
      )
    );
    useAlert(t('CAPTAIN.ASSISTANTS.SCENARIOS.API.ADD.SUCCESS'));
  } catch (error) {
    useAlert(
      getScenarioErrorMessage(
        error,
        t('CAPTAIN.ASSISTANTS.SCENARIOS.API.ADD.ERROR')
      )
    );
  }
};

watch(
  () => props.assistantId,
  assistantId => {
    if (!assistantId) {
      return;
    }

    bulkSelectedIds.value = new Set();
    store.dispatch('captainScenarios/get', { assistantId });
  },
  { immediate: true }
);
</script>

<template>
  <div class="flex flex-col gap-4">
    <SettingsHeader
      :heading="$t('CAPTAIN.ASSISTANTS.SCENARIOS.TITLE')"
      :description="$t('CAPTAIN.ASSISTANTS.SCENARIOS.DESCRIPTION')"
    />

    <div v-if="shouldShowSuggestedRules" class="flex flex-col gap-4">
      <SuggestedScenarios
        :title="$t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.SUGGESTED.TITLE')"
        :items="scenariosExample"
        @close="closeSuggestedRules"
        @add="addAllExampleScenarios"
      >
        <template #default="{ item }">
          <div class="flex items-center gap-3 justify-between">
            <span class="text-sm text-n-slate-12">
              {{ item.title }}
            </span>
            <Button
              :label="
                $t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.SUGGESTED.ADD_SINGLE')
              "
              ghost
              xs
              slate
              class="!text-sm !text-n-slate-11 flex-shrink-0"
              @click="addScenario(item)"
            />
          </div>
          <div class="flex flex-col">
            <span class="text-sm text-n-slate-11 mt-2">
              {{ item.description }}
            </span>
            <component
              :is="renderInstruction(formatMessage(item.instruction, false))"
            />
            <span class="text-sm text-n-slate-11 font-medium mb-1">
              {{ t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.SUGGESTED.TOOLS_USED') }}
              {{ item.tools?.map(tool => `@${tool}`).join(', ') }}
            </span>
          </div>
        </template>
      </SuggestedScenarios>
    </div>

    <div class="flex flex-col gap-4">
      <div
        class="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between"
      >
        <BulkSelectBar
          v-model="bulkSelectedIds"
          :all-items="scenarios"
          :select-all-label="buildSelectedCountLabel"
          :selected-count-label="selectedCountLabel"
          :delete-label="
            $t('CAPTAIN.ASSISTANTS.SCENARIOS.BULK_ACTION.BULK_DELETE_BUTTON')
          "
          @bulk-delete="bulkDeleteScenarios"
        >
          <template #default-actions>
            <AddNewScenariosDialog
              :assistant-id="assistantId"
              @add="addScenario"
            />
          </template>
        </BulkSelectBar>
        <div
          v-if="scenarios.length && bulkSelectedIds.size === 0"
          class="max-w-[22.5rem] w-full min-w-0"
        >
          <Input
            v-model="searchQuery"
            :placeholder="
              t('CAPTAIN.ASSISTANTS.SCENARIOS.LIST.SEARCH_PLACEHOLDER')
            "
          />
        </div>
      </div>

      <div v-if="isFetching" class="text-sm text-n-slate-11">
        {{ t('CAPTAIN.ASSISTANTS.SCENARIOS.LOADING_MESSAGE') }}
      </div>
      <div v-else-if="scenarios.length === 0" class="mt-1 mb-2">
        <span class="text-n-slate-11 text-sm">
          {{ t('CAPTAIN.ASSISTANTS.SCENARIOS.EMPTY_MESSAGE') }}
        </span>
      </div>
      <div v-else-if="filteredScenarios.length === 0" class="mt-1 mb-2">
        <span class="text-n-slate-11 text-sm">
          {{ t('CAPTAIN.ASSISTANTS.SCENARIOS.SEARCH_EMPTY_MESSAGE') }}
        </span>
      </div>
      <div v-else class="grid grid-cols-1 gap-4 md:grid-cols-2">
        <ScenariosCard
          v-for="scenario in filteredScenarios"
          :id="scenario.id"
          :key="scenario.id"
          :title="scenario.title"
          :description="scenario.description"
          :instruction="scenario.instruction"
          :tools="scenario.tools"
          :assistant-id="assistantId"
          :is-selected="bulkSelectedIds.has(scenario.id)"
          :selectable="hoveredCard === scenario.id || bulkSelectedIds.size > 0"
          @select="handleRuleSelect"
          @delete="deleteScenario(scenario.id)"
          @update="updateScenario"
          @hover="isHovered => handleRuleHover(isHovered, scenario.id)"
        />
      </div>
    </div>
  </div>
</template>
