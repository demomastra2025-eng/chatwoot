<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import captainEvaluationsAPI from 'dashboard/api/captain/evaluations';

const { t } = useI18n();

const SCENARIO_DEFINITIONS = [
  {
    id: 'release',
    icon: 'i-lucide-rocket',
    color: 'text-n-blue-11 bg-n-blue-3',
    packIds: [
      'llm.moderation',
      'captain.tool_safety',
      'captain.ai_voice_trace',
      'captain.red_team',
    ],
  },
  {
    id: 'safety',
    icon: 'i-lucide-shield-check',
    color: 'text-n-teal-11 bg-n-teal-3',
    packIds: ['llm.moderation', 'captain.tool_safety', 'captain.red_team'],
  },
  {
    id: 'voice',
    icon: 'i-lucide-phone-call',
    color: 'text-n-violet-11 bg-n-violet-3',
    packIds: ['captain.ai_voice_trace'],
  },
  {
    id: 'tools',
    icon: 'i-lucide-wrench',
    color: 'text-n-slate-11 bg-n-slate-3',
    packIds: ['captain.tool_safety'],
  },
  {
    id: 'completion',
    icon: 'i-lucide-check-check',
    color: 'text-n-amber-11 bg-n-amber-3',
    packIds: ['captain.conversation_completion'],
  },
];

const packs = ref([]);
const selectedPackIds = ref([]);
const selectedScenarioId = ref('release');
const result = ref(null);
const evalRuns = ref({ llm_model_enabled: false });
const evalRun = ref(null);
const tribunal = ref({});
const budgetCents = ref('100');
const maxCases = ref('3');
const acknowledgeLlmCost = ref(false);
const datasetFiles = ref('');
const datasetFormat = ref('json');
const datasetStrict = ref(true);
const datasetAllowLiveAssertions = ref(false);
const datasetThreshold = ref('');
const datasetConcurrency = ref('1');
const datasetReport = ref('');
const redTeamPrompt = ref('');
const redTeamCategories = ref(['encoding', 'injection', 'jailbreak']);
const redTeamAttacks = ref([]);
const importInboxId = ref('');
const importDisplayId = ref('');
const importedFixtureYaml = ref('');
const isLoadingCatalog = ref(false);
const isRunning = ref(false);
const errorMessage = ref('');

const selectedPacks = computed(() =>
  packs.value.filter(pack => selectedPackIds.value.includes(pack.id))
);

const selectedContainsLlmModel = computed(() =>
  selectedPacks.value.some(pack => pack.live_model)
);

const requiresLlmCostControls = computed(
  () => selectedContainsLlmModel.value || datasetAllowLiveAssertions.value
);

const evalRunSummary = computed(() => evalRun.value?.result_summary || null);

const selectedPacksLabel = computed(() => {
  if (!selectedPacks.value.length) {
    return t('CAPTAIN.EVALUATIONS.SELECTION.EMPTY');
  }

  return t('CAPTAIN.EVALUATIONS.SELECTION.COUNT', {
    count: selectedPacks.value.length,
  });
});

const canRunEvals = computed(
  () =>
    selectedPackIds.value.length &&
    (!selectedContainsLlmModel.value ||
      (acknowledgeLlmCost.value && budgetCents.value && maxCases.value))
);

const canRunDatasetEvals = computed(
  () =>
    !datasetAllowLiveAssertions.value ||
    (acknowledgeLlmCost.value && budgetCents.value && maxCases.value)
);

const availableRedTeamCategories = computed(
  () =>
    tribunal.value?.red_team_categories || [
      'encoding',
      'injection',
      'jailbreak',
    ]
);

const canImportConversation = computed(
  () => importInboxId.value.trim() && importDisplayId.value.trim()
);

const resultStatusLabel = computed(() => {
  if (!result.value?.status) return '';

  return result.value.status === 'pass'
    ? t('CAPTAIN.EVALUATIONS.RESULT_STATUS.PASS')
    : t('CAPTAIN.EVALUATIONS.RESULT_STATUS.FAIL');
});

const resultStatusClass = computed(() =>
  result.value?.status === 'pass'
    ? 'bg-n-teal-3 text-n-teal-11'
    : 'bg-n-ruby-3 text-n-ruby-11'
);

const evalRunTitle = computed(() =>
  evalRun.value?.id
    ? t('CAPTAIN.EVALUATIONS.RUN.LAST_RUN_WITH_ID', { id: evalRun.value.id })
    : ''
);

const evalRunStatus = computed(() =>
  evalRun.value?.status
    ? t('CAPTAIN.EVALUATIONS.RUN.STATUS_WITH_VALUE', {
        status: evalRun.value.status,
      })
    : ''
);

const withCatalogState = scenario => {
  const availablePackIds = scenario.packIds.filter(packId =>
    packs.value.some(pack => pack.id === packId)
  );
  const hasLivePack = availablePackIds.some(
    packId => packs.value.find(pack => pack.id === packId)?.live_model
  );

  return {
    ...scenario,
    packIds: availablePackIds,
    hasLivePack,
  };
};

const scenarioCards = computed(() => [
  withCatalogState({
    ...SCENARIO_DEFINITIONS[0],
    title: t('CAPTAIN.EVALUATIONS.SCENARIOS.RELEASE.TITLE'),
    short: t('CAPTAIN.EVALUATIONS.SCENARIOS.RELEASE.SHORT'),
    tooltip: t('CAPTAIN.EVALUATIONS.SCENARIOS.RELEASE.TOOLTIP'),
  }),
  withCatalogState({
    ...SCENARIO_DEFINITIONS[1],
    title: t('CAPTAIN.EVALUATIONS.SCENARIOS.SAFETY.TITLE'),
    short: t('CAPTAIN.EVALUATIONS.SCENARIOS.SAFETY.SHORT'),
    tooltip: t('CAPTAIN.EVALUATIONS.SCENARIOS.SAFETY.TOOLTIP'),
  }),
  withCatalogState({
    ...SCENARIO_DEFINITIONS[2],
    title: t('CAPTAIN.EVALUATIONS.SCENARIOS.VOICE.TITLE'),
    short: t('CAPTAIN.EVALUATIONS.SCENARIOS.VOICE.SHORT'),
    tooltip: t('CAPTAIN.EVALUATIONS.SCENARIOS.VOICE.TOOLTIP'),
  }),
  withCatalogState({
    ...SCENARIO_DEFINITIONS[3],
    title: t('CAPTAIN.EVALUATIONS.SCENARIOS.TOOLS.TITLE'),
    short: t('CAPTAIN.EVALUATIONS.SCENARIOS.TOOLS.SHORT'),
    tooltip: t('CAPTAIN.EVALUATIONS.SCENARIOS.TOOLS.TOOLTIP'),
  }),
  withCatalogState({
    ...SCENARIO_DEFINITIONS[4],
    title: t('CAPTAIN.EVALUATIONS.SCENARIOS.COMPLETION.TITLE'),
    short: t('CAPTAIN.EVALUATIONS.SCENARIOS.COMPLETION.SHORT'),
    tooltip: t('CAPTAIN.EVALUATIONS.SCENARIOS.COMPLETION.TOOLTIP'),
  }),
]);

const activeScenario = computed(() =>
  scenarioCards.value.find(scenario => scenario.id === selectedScenarioId.value)
);

const packLabel = pack => {
  switch (pack.id) {
    case 'llm.moderation':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.MODERATION.LABEL');
    case 'captain.tool_safety':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.TOOL_SAFETY.LABEL');
    case 'captain.ai_voice_trace':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.AI_VOICE.LABEL');
    case 'captain.red_team':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.RED_TEAM.LABEL');
    case 'captain.conversation_completion':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.COMPLETION.LABEL');
    default:
      return pack.label;
  }
};

const packDescription = pack => {
  switch (pack.id) {
    case 'llm.moderation':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.MODERATION.DESCRIPTION');
    case 'captain.tool_safety':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.TOOL_SAFETY.DESCRIPTION');
    case 'captain.ai_voice_trace':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.AI_VOICE.DESCRIPTION');
    case 'captain.red_team':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.RED_TEAM.DESCRIPTION');
    case 'captain.conversation_completion':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.COMPLETION.DESCRIPTION');
    default:
      return pack.description;
  }
};

const statusTone = status => {
  if (status === 'passed' || status === 'pass' || status === 'completed') {
    return 'bg-n-teal-3 text-n-teal-11';
  }
  if (status === 'failed' || status === 'fail' || status === 'error') {
    return 'bg-n-ruby-3 text-n-ruby-11';
  }

  return 'bg-n-amber-3 text-n-amber-11';
};

const syncDefaultPackSelection = () => {
  if (selectedPackIds.value.length) return;

  const releaseScenario = scenarioCards.value.find(
    scenario => scenario.id === selectedScenarioId.value
  );
  const packIds = releaseScenario?.packIds || [];

  selectedPackIds.value = packIds.length
    ? packIds
    : packs.value.filter(pack => pack.default_enabled).map(pack => pack.id);
};

const applyScenario = scenario => {
  selectedScenarioId.value = scenario.id;
  selectedPackIds.value = [...scenario.packIds];
  result.value = null;
};

const markCustomSelection = () => {
  selectedScenarioId.value = '';
};

const backendErrorMessage = (error, fallback) => {
  const backendError = error?.response?.data?.error;
  return backendError ? `${fallback}: ${backendError}` : fallback;
};

const fetchCatalog = async () => {
  isLoadingCatalog.value = true;
  errorMessage.value = '';

  try {
    const response = await captainEvaluationsAPI.get();
    packs.value = response.data?.packs || [];
    evalRuns.value = response.data?.eval_runs || { llm_model_enabled: false };
    tribunal.value = response.data?.tribunal || {};
    evalRun.value = response.data?.latest_eval_run || null;
    budgetCents.value = String(
      evalRuns.value.default_budget_cents || budgetCents.value
    );
    maxCases.value = String(evalRuns.value.default_max_cases || maxCases.value);
    syncDefaultPackSelection();
  } catch (error) {
    errorMessage.value = t('CAPTAIN.EVALUATIONS.ERRORS.CATALOG_FAILED');
  } finally {
    isLoadingCatalog.value = false;
  }
};

const runEvals = async () => {
  isRunning.value = true;
  errorMessage.value = '';

  try {
    const response = await captainEvaluationsAPI.run({
      pack_ids: selectedPackIds.value,
      acknowledge_llm_cost: acknowledgeLlmCost.value,
      budget_cents: Number(budgetCents.value),
      max_cases: Number(maxCases.value),
    });
    packs.value = response.data?.packs || packs.value;
    evalRuns.value = response.data?.eval_runs || evalRuns.value;

    if (response.data?.run) {
      evalRun.value = response.data.run;
      result.value = null;
    } else {
      result.value = response.data?.result || null;
    }
  } catch (error) {
    errorMessage.value = backendErrorMessage(
      error,
      t('CAPTAIN.EVALUATIONS.ERRORS.RUN_FAILED')
    );
  } finally {
    isRunning.value = false;
  }
};

const formatCount = (passedCount, totalCount) =>
  `${passedCount || 0} / ${totalCount || 0}`;

const runDatasetEvals = async () => {
  isRunning.value = true;
  errorMessage.value = '';
  datasetReport.value = '';

  try {
    const requestedFiles = datasetFiles.value
      .split(',')
      .map(file => file.trim())
      .filter(Boolean);
    const response = await captainEvaluationsAPI.runDataset({
      files: requestedFiles,
      format: datasetFormat.value,
      strict: datasetStrict.value,
      allow_live_assertions: datasetAllowLiveAssertions.value,
      acknowledge_llm_cost: acknowledgeLlmCost.value,
      budget_cents: Number(budgetCents.value),
      max_cases: Number(maxCases.value),
      threshold: datasetThreshold.value || undefined,
      concurrency: Number(datasetConcurrency.value || 1),
    });
    datasetReport.value = response.data?.report || '';
  } catch (error) {
    errorMessage.value = backendErrorMessage(
      error,
      t('CAPTAIN.EVALUATIONS.ERRORS.DATASET_FAILED')
    );
  } finally {
    isRunning.value = false;
  }
};

const generateRedTeam = async () => {
  isRunning.value = true;
  errorMessage.value = '';
  redTeamAttacks.value = [];

  try {
    const response = await captainEvaluationsAPI.generateRedTeam({
      prompt: redTeamPrompt.value,
      categories: redTeamCategories.value,
    });
    redTeamAttacks.value = response.data?.attacks || [];
  } catch (error) {
    errorMessage.value = backendErrorMessage(
      error,
      t('CAPTAIN.EVALUATIONS.ERRORS.RED_TEAM_FAILED')
    );
  } finally {
    isRunning.value = false;
  }
};

const refreshEvalRun = async () => {
  if (!evalRun.value?.id) return;
  isRunning.value = true;
  errorMessage.value = '';

  try {
    const response = await captainEvaluationsAPI.getRun(evalRun.value.id);
    evalRun.value = response.data?.run || evalRun.value;
  } catch (error) {
    errorMessage.value = backendErrorMessage(
      error,
      t('CAPTAIN.EVALUATIONS.ERRORS.RUN_STATUS_FAILED')
    );
  } finally {
    isRunning.value = false;
  }
};

const importConversation = async () => {
  isRunning.value = true;
  errorMessage.value = '';
  importedFixtureYaml.value = '';

  try {
    const response = await captainEvaluationsAPI.importConversation({
      inbox_id: importInboxId.value.trim(),
      display_id: importDisplayId.value.trim(),
    });
    importedFixtureYaml.value = response.data?.yaml || '';
  } catch (error) {
    errorMessage.value = backendErrorMessage(
      error,
      t('CAPTAIN.EVALUATIONS.ERRORS.IMPORT_FAILED')
    );
  } finally {
    isRunning.value = false;
  }
};

onMounted(fetchCatalog);
</script>

<template>
  <PageLayout
    :header-title="t('CAPTAIN.EVALUATIONS.TITLE')"
    :show-assistant-switcher="false"
    :show-pagination-footer="false"
    :show-know-more="false"
  >
    <template #body>
      <section class="flex flex-col gap-5 pb-10">
        <div
          class="rounded-2xl border border-n-weak bg-n-surface-2 p-5 shadow-sm"
        >
          <div
            class="flex flex-col gap-4 md:flex-row md:items-center md:justify-between"
          >
            <div class="min-w-0">
              <div class="flex items-center gap-2 text-n-brand">
                <i class="i-lucide-sparkles size-4" />
                <span class="text-xs font-semibold uppercase tracking-wide">
                  {{ t('CAPTAIN.EVALUATIONS.BADGE') }}
                </span>
              </div>
              <h2 class="mt-2 text-2xl font-semibold text-n-slate-12">
                {{ t('CAPTAIN.EVALUATIONS.HERO_TITLE') }}
              </h2>
              <div class="mt-3 flex flex-wrap items-center gap-2 text-sm">
                <span
                  class="rounded-full bg-n-alpha-2 px-3 py-1 text-n-slate-11"
                >
                  {{ selectedPacksLabel }}
                </span>
                <span
                  v-if="selectedContainsLlmModel"
                  class="rounded-full bg-n-amber-3 px-3 py-1 text-n-amber-11"
                >
                  {{ t('CAPTAIN.EVALUATIONS.SELECTION.LLM_COST') }}
                </span>
                <span
                  v-else
                  class="rounded-full bg-n-teal-3 px-3 py-1 text-n-teal-11"
                >
                  {{ t('CAPTAIN.EVALUATIONS.SELECTION.FREE') }}
                </span>
              </div>
            </div>
            <Button
              :label="t('CAPTAIN.EVALUATIONS.RUN_EVALS')"
              icon="i-lucide-play"
              :is-loading="isRunning"
              :disabled="isLoadingCatalog || isRunning || !canRunEvals"
              @click="runEvals"
            />
          </div>
        </div>

        <div
          v-if="errorMessage"
          class="rounded-xl border border-n-ruby-5 bg-n-ruby-2 p-4 text-sm text-n-ruby-11"
        >
          {{ errorMessage }}
        </div>

        <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-5">
          <button
            v-for="scenario in scenarioCards"
            :key="scenario.id"
            type="button"
            class="group flex min-h-[152px] flex-col justify-between rounded-2xl border p-4 text-left transition hover:-translate-y-0.5 hover:shadow-md focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-n-brand"
            :class="
              selectedScenarioId === scenario.id
                ? 'border-n-brand bg-n-brand/5 shadow-sm'
                : 'border-n-weak bg-n-surface-2 hover:border-n-slate-7'
            "
            :disabled="!scenario.packIds.length"
            :data-testid="`eval-scenario-${scenario.id}`"
            @click="applyScenario(scenario)"
          >
            <span class="flex items-start justify-between gap-3">
              <span
                class="flex size-10 items-center justify-center rounded-xl"
                :class="scenario.color"
              >
                <i :class="scenario.icon" class="size-5" />
              </span>
              <span class="flex items-center gap-2">
                <span
                  v-if="scenario.hasLivePack"
                  class="rounded-full bg-n-amber-3 px-2 py-0.5 text-xs font-medium text-n-amber-11"
                >
                  {{ t('CAPTAIN.EVALUATIONS.SELECTION.LLM') }}
                </span>
                <span
                  v-tooltip.top="scenario.tooltip"
                  class="rounded-full p-1 text-n-slate-10 hover:bg-n-alpha-2 hover:text-n-slate-12"
                >
                  <i class="i-lucide-info size-4" />
                </span>
              </span>
            </span>
            <span>
              <span class="block text-sm font-semibold text-n-slate-12">
                {{ scenario.title }}
              </span>
              <span class="mt-1 block text-sm text-n-slate-11">
                {{ scenario.short }}
              </span>
            </span>
          </button>
        </div>

        <div class="rounded-2xl border border-n-weak bg-n-surface-2 p-4 md:p-5">
          <div
            class="flex flex-col gap-4 md:flex-row md:items-center md:justify-between"
          >
            <div class="min-w-0">
              <h3 class="text-base font-semibold text-n-slate-12">
                {{
                  activeScenario?.title ||
                  t('CAPTAIN.EVALUATIONS.SELECTION.CUSTOM_TITLE')
                }}
              </h3>
              <p class="mt-1 text-sm text-n-slate-11">
                {{
                  activeScenario?.short ||
                  t('CAPTAIN.EVALUATIONS.SELECTION.CUSTOM_DESCRIPTION')
                }}
              </p>
            </div>
            <div class="flex flex-wrap items-center gap-2">
              <span
                class="rounded-full px-3 py-1 text-xs font-medium"
                :class="
                  evalRuns.llm_model_enabled
                    ? 'bg-n-teal-3 text-n-teal-11'
                    : 'bg-n-amber-3 text-n-amber-11'
                "
              >
                {{
                  evalRuns.llm_model_enabled
                    ? t('CAPTAIN.EVALUATIONS.RUN.LLM_ENABLED')
                    : t('CAPTAIN.EVALUATIONS.RUN.LLM_DISABLED')
                }}
              </span>
              <Button
                :label="t('CAPTAIN.EVALUATIONS.RUN_EVALS')"
                icon="i-lucide-play"
                :is-loading="isRunning"
                :disabled="isRunning || !canRunEvals"
                @click="runEvals"
              />
            </div>
          </div>

          <div
            v-if="requiresLlmCostControls"
            class="mt-4 grid gap-3 rounded-xl border border-n-amber-5 bg-n-amber-2 p-4 md:grid-cols-[1fr_1fr_auto] md:items-end"
          >
            <label class="flex flex-col gap-1 text-sm text-n-slate-11">
              <span class="flex items-center gap-1">
                {{ t('CAPTAIN.EVALUATIONS.RUN.BUDGET_CENTS') }}
                <i
                  v-tooltip.top="t('CAPTAIN.EVALUATIONS.RUN.BUDGET_TOOLTIP')"
                  class="i-lucide-info size-3.5 text-n-slate-10"
                />
              </span>
              <input
                v-model="budgetCents"
                data-testid="eval-budget-cents"
                class="rounded-lg border border-n-weak bg-n-alpha-1 px-3 py-2 text-n-slate-12 outline-none"
                type="number"
                min="1"
                :max="evalRuns.max_budget_cents"
              />
            </label>
            <label class="flex flex-col gap-1 text-sm text-n-slate-11">
              <span>{{ t('CAPTAIN.EVALUATIONS.RUN.MAX_CASES') }}</span>
              <input
                v-model="maxCases"
                data-testid="eval-max-cases"
                class="rounded-lg border border-n-weak bg-n-alpha-1 px-3 py-2 text-n-slate-12 outline-none"
                type="number"
                min="1"
                :max="evalRuns.max_cases"
              />
            </label>
            <label
              class="flex items-start gap-2 rounded-lg bg-n-alpha-1 p-3 text-sm text-n-slate-11"
            >
              <input
                v-model="acknowledgeLlmCost"
                data-testid="eval-acknowledge-cost"
                type="checkbox"
                class="mt-1"
              />
              <span>{{ t('CAPTAIN.EVALUATIONS.RUN.ACKNOWLEDGE_SHORT') }}</span>
            </label>
          </div>

          <div
            v-if="evalRun"
            class="mt-4 rounded-xl border border-n-weak bg-n-alpha-1 p-4 text-sm text-n-slate-11"
          >
            <div class="flex items-center justify-between gap-3">
              <div>
                <p class="font-medium text-n-slate-12">
                  {{ evalRunTitle }}
                </p>
                <p class="mt-1">
                  {{ evalRunStatus }}
                </p>
              </div>
              <Button
                :label="t('CAPTAIN.EVALUATIONS.RUN.REFRESH')"
                icon="i-lucide-refresh-cw"
                :is-loading="isRunning"
                @click="refreshEvalRun"
              />
            </div>
            <div
              v-if="evalRunSummary"
              data-testid="eval-run-summary"
              class="mt-3 grid gap-2 sm:grid-cols-3"
            >
              <div class="rounded-lg bg-n-alpha-2 p-3">
                <p class="text-xs text-n-slate-10">
                  {{ t('CAPTAIN.EVALUATIONS.RESULTS.SUITES') }}
                </p>
                <p class="mt-1 font-semibold text-n-slate-12">
                  {{ evalRunSummary.suite_count || 0 }}
                </p>
              </div>
              <div class="rounded-lg bg-n-alpha-2 p-3">
                <p class="text-xs text-n-slate-10">
                  {{ t('CAPTAIN.EVALUATIONS.RESULTS.PASSED') }}
                </p>
                <p class="mt-1 font-semibold text-n-slate-12">
                  {{ evalRunSummary.passed_count || 0 }}
                </p>
              </div>
              <div class="rounded-lg bg-n-alpha-2 p-3">
                <p class="text-xs text-n-slate-10">
                  {{ t('CAPTAIN.EVALUATIONS.RESULTS.FAILED') }}
                </p>
                <p class="mt-1 font-semibold text-n-slate-12">
                  {{ evalRunSummary.failed_count || 0 }}
                </p>
              </div>
            </div>
            <p
              v-if="evalRunSummary?.suite_ids?.length"
              class="mt-2 text-xs text-n-slate-10"
            >
              {{ evalRunSummary.suite_ids.join(', ') }}
            </p>
          </div>
        </div>

        <div
          v-if="result"
          class="rounded-2xl border border-n-weak bg-n-surface-2 p-5"
        >
          <div
            class="flex flex-col gap-2 md:flex-row md:items-center md:justify-between"
          >
            <h3 class="text-base font-semibold text-n-slate-12">
              {{ t('CAPTAIN.EVALUATIONS.RESULT_TITLE') }}
            </h3>
            <span
              class="w-fit rounded-full px-3 py-1 text-sm font-medium"
              :class="resultStatusClass"
            >
              {{ resultStatusLabel }}
            </span>
          </div>
          <div class="mt-4 grid gap-3 md:grid-cols-4">
            <div class="rounded-xl bg-n-alpha-1 p-3">
              <p class="text-xs text-n-slate-10">
                {{ t('CAPTAIN.EVALUATIONS.RESULTS.PASSED') }}
              </p>
              <p class="mt-1 text-lg font-semibold text-n-slate-12">
                {{ formatCount(result.passed_count, result.total_count) }}
              </p>
            </div>
            <div class="rounded-xl bg-n-alpha-1 p-3">
              <p class="text-xs text-n-slate-10">
                {{ t('CAPTAIN.EVALUATIONS.RESULTS.SUITES') }}
              </p>
              <p class="mt-1 text-lg font-semibold text-n-slate-12">
                {{ result.suite_count }}
              </p>
            </div>
            <div class="rounded-xl bg-n-alpha-1 p-3">
              <p class="text-xs text-n-slate-10">
                {{ t('CAPTAIN.EVALUATIONS.RESULTS.FAILED') }}
              </p>
              <p class="mt-1 text-lg font-semibold text-n-slate-12">
                {{ result.failed_count }}
              </p>
            </div>
            <div class="rounded-xl bg-n-alpha-1 p-3">
              <p class="text-xs text-n-slate-10">
                {{ t('CAPTAIN.EVALUATIONS.RESULTS.ERRORS') }}
              </p>
              <p class="mt-1 text-lg font-semibold text-n-slate-12">
                {{ result.error_count }}
              </p>
            </div>
          </div>
          <div class="mt-4 grid gap-2">
            <div
              v-for="suite in result.suites"
              :key="suite.suite_id"
              class="rounded-xl border border-n-weak p-3 text-sm"
            >
              <div class="flex items-center justify-between gap-3">
                <span class="font-medium text-n-slate-12">
                  {{ suite.suite_id }}
                </span>
                <span
                  class="rounded-full px-2 py-0.5 text-xs font-medium"
                  :class="statusTone(suite.status)"
                >
                  {{ formatCount(suite.passed_count, suite.total_count) }}
                </span>
              </div>
            </div>
          </div>
        </div>

        <details
          class="group rounded-2xl border border-n-weak bg-n-surface-2 p-4 md:p-5"
        >
          <summary
            class="flex cursor-pointer list-none items-center justify-between gap-3 text-sm font-semibold text-n-slate-12"
          >
            <span class="flex items-center gap-2">
              <i class="i-lucide-sliders-horizontal size-4 text-n-slate-10" />
              {{ t('CAPTAIN.EVALUATIONS.ADVANCED.TITLE') }}
            </span>
            <i
              class="i-lucide-chevron-down size-4 text-n-slate-10 transition group-open:rotate-180"
            />
          </summary>

          <div class="mt-4 grid gap-3 md:grid-cols-2">
            <label
              v-for="pack in packs"
              :key="pack.id"
              class="rounded-xl border border-n-weak bg-n-alpha-1 p-4"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="flex items-start gap-3">
                  <input
                    v-model="selectedPackIds"
                    data-testid="eval-pack-checkbox"
                    type="checkbox"
                    :value="pack.id"
                    class="mt-1"
                    @change="markCustomSelection"
                  />
                  <div>
                    <h4 class="text-sm font-semibold text-n-slate-12">
                      {{ packLabel(pack) }}
                    </h4>
                    <p class="mt-1 text-xs text-n-slate-10">
                      {{ pack.id }}
                    </p>
                  </div>
                </div>
                <span
                  class="shrink-0 rounded-full px-2 py-1 text-xs font-medium"
                  :class="
                    pack.deterministic
                      ? 'bg-n-teal-3 text-n-teal-11'
                      : 'bg-n-amber-3 text-n-amber-11'
                  "
                >
                  {{
                    pack.deterministic
                      ? t('CAPTAIN.EVALUATIONS.PACKS.DETERMINISTIC')
                      : t('CAPTAIN.EVALUATIONS.PACKS.LLM_MODEL')
                  }}
                </span>
              </div>
              <p class="mt-3 text-sm leading-6 text-n-slate-11">
                {{ packDescription(pack) }}
              </p>
            </label>
          </div>
        </details>

        <div class="grid gap-4 lg:grid-cols-3">
          <details
            class="group rounded-2xl border border-n-weak bg-n-surface-2 p-4 md:p-5"
          >
            <summary
              class="flex cursor-pointer list-none items-center justify-between gap-3 text-sm font-semibold text-n-slate-12"
            >
              <span class="flex items-center gap-2">
                <i class="i-lucide-shield-alert size-4 text-n-ruby-10" />
                {{ t('CAPTAIN.EVALUATIONS.RED_TEAM.TITLE') }}
              </span>
              <i
                class="i-lucide-chevron-down size-4 text-n-slate-10 transition group-open:rotate-180"
              />
            </summary>
            <div class="mt-4 flex flex-col gap-3">
              <label class="flex flex-col gap-1 text-sm text-n-slate-11">
                <span class="flex items-center gap-1">
                  {{ t('CAPTAIN.EVALUATIONS.RED_TEAM.PROMPT') }}
                  <i
                    v-tooltip.top="
                      t('CAPTAIN.EVALUATIONS.RED_TEAM.DESCRIPTION')
                    "
                    class="i-lucide-info size-3.5 text-n-slate-10"
                  />
                </span>
                <input
                  v-model="redTeamPrompt"
                  data-testid="red-team-prompt"
                  class="rounded-lg border border-n-weak bg-n-alpha-1 px-3 py-2 text-n-slate-12 outline-none"
                  type="text"
                />
              </label>
              <Button
                :label="t('CAPTAIN.EVALUATIONS.RED_TEAM.BUTTON')"
                icon="i-lucide-shield-alert"
                :is-loading="isRunning"
                :disabled="isRunning || !redTeamPrompt.trim()"
                @click="generateRedTeam"
              />
              <div class="flex flex-wrap gap-2">
                <label
                  v-for="category in availableRedTeamCategories"
                  :key="category"
                  class="flex items-center gap-2 rounded-full bg-n-alpha-1 px-3 py-1 text-xs text-n-slate-11"
                >
                  <input
                    v-model="redTeamCategories"
                    data-testid="red-team-category"
                    type="checkbox"
                    :value="category"
                  />
                  <span>{{ category }}</span>
                </label>
              </div>
              <div v-if="redTeamAttacks.length" class="grid gap-2">
                <article
                  v-for="attack in redTeamAttacks"
                  :key="attack.type"
                  class="rounded-lg border border-n-weak bg-n-alpha-1 p-3"
                >
                  <p class="text-sm font-medium text-n-slate-12">
                    {{ attack.type }}
                  </p>
                  <p class="mt-1 whitespace-pre-wrap text-xs text-n-slate-11">
                    {{ attack.prompt }}
                  </p>
                </article>
              </div>
            </div>
          </details>

          <details
            class="group rounded-2xl border border-n-weak bg-n-surface-2 p-4 md:p-5"
          >
            <summary
              class="flex cursor-pointer list-none items-center justify-between gap-3 text-sm font-semibold text-n-slate-12"
            >
              <span class="flex items-center gap-2">
                <i class="i-lucide-file-check-2 size-4 text-n-brand" />
                {{ t('CAPTAIN.EVALUATIONS.TRIBUNAL.TITLE') }}
              </span>
              <i
                class="i-lucide-chevron-down size-4 text-n-slate-10 transition group-open:rotate-180"
              />
            </summary>
            <div class="mt-4 grid gap-3">
              <label class="flex flex-col gap-1 text-sm text-n-slate-11">
                <span class="flex items-center gap-1">
                  {{ t('CAPTAIN.EVALUATIONS.TRIBUNAL.FILES') }}
                  <i
                    v-tooltip.top="
                      t('CAPTAIN.EVALUATIONS.TRIBUNAL.DESCRIPTION')
                    "
                    class="i-lucide-info size-3.5 text-n-slate-10"
                  />
                </span>
                <input
                  v-model="datasetFiles"
                  data-testid="tribunal-dataset-files"
                  class="rounded-lg border border-n-weak bg-n-alpha-1 px-3 py-2 text-n-slate-12 outline-none"
                  type="text"
                  :placeholder="
                    t('CAPTAIN.EVALUATIONS.TRIBUNAL.FILES_PLACEHOLDER')
                  "
                />
              </label>
              <div class="grid gap-3 sm:grid-cols-2">
                <label class="flex flex-col gap-1 text-sm text-n-slate-11">
                  <span>{{ t('CAPTAIN.EVALUATIONS.TRIBUNAL.FORMAT') }}</span>
                  <select
                    v-model="datasetFormat"
                    data-testid="tribunal-dataset-format"
                    class="rounded-lg border border-n-weak bg-n-alpha-1 px-3 py-2 text-n-slate-12 outline-none"
                  >
                    <option
                      v-for="format in tribunal.report_formats || ['json']"
                      :key="format"
                      :value="format"
                    >
                      {{ format }}
                    </option>
                  </select>
                </label>
                <label class="flex flex-col gap-1 text-sm text-n-slate-11">
                  <span>{{
                    t('CAPTAIN.EVALUATIONS.TRIBUNAL.CONCURRENCY')
                  }}</span>
                  <input
                    v-model="datasetConcurrency"
                    data-testid="tribunal-dataset-concurrency"
                    class="rounded-lg border border-n-weak bg-n-alpha-1 px-3 py-2 text-n-slate-12 outline-none"
                    type="number"
                    min="1"
                    :max="tribunal.max_concurrency || 1"
                  />
                </label>
                <label class="flex flex-col gap-1 text-sm text-n-slate-11">
                  <span>{{ t('CAPTAIN.EVALUATIONS.TRIBUNAL.THRESHOLD') }}</span>
                  <input
                    v-model="datasetThreshold"
                    data-testid="tribunal-dataset-threshold"
                    class="rounded-lg border border-n-weak bg-n-alpha-1 px-3 py-2 text-n-slate-12 outline-none"
                    type="number"
                    min="0"
                    max="1"
                    step="0.01"
                  />
                </label>
                <label
                  class="flex items-center gap-2 rounded-lg bg-n-alpha-1 p-3 text-sm text-n-slate-11"
                >
                  <input
                    v-model="datasetStrict"
                    data-testid="tribunal-dataset-strict"
                    type="checkbox"
                  />
                  <span>{{ t('CAPTAIN.EVALUATIONS.TRIBUNAL.STRICT') }}</span>
                </label>
              </div>
              <label
                class="flex items-center gap-2 rounded-lg bg-n-amber-2 p-3 text-sm text-n-slate-11"
              >
                <input
                  v-model="datasetAllowLiveAssertions"
                  data-testid="tribunal-dataset-live-assertions"
                  type="checkbox"
                />
                <span>{{
                  t('CAPTAIN.EVALUATIONS.TRIBUNAL.ALLOW_LIVE_ASSERTIONS')
                }}</span>
              </label>
              <div
                v-if="datasetAllowLiveAssertions"
                class="grid gap-3 rounded-lg border border-n-amber-5 bg-n-amber-2 p-3 text-sm text-n-slate-11"
              >
                <label class="flex flex-col gap-1">
                  <span>{{ t('CAPTAIN.EVALUATIONS.RUN.BUDGET_CENTS') }}</span>
                  <input
                    v-model="budgetCents"
                    data-testid="tribunal-budget-cents"
                    class="rounded-lg border border-n-weak bg-n-alpha-1 px-3 py-2 text-n-slate-12 outline-none"
                    type="number"
                    min="1"
                    :max="evalRuns.max_budget_cents"
                  />
                </label>
                <label class="flex flex-col gap-1">
                  <span>{{ t('CAPTAIN.EVALUATIONS.RUN.MAX_CASES') }}</span>
                  <input
                    v-model="maxCases"
                    data-testid="tribunal-max-cases"
                    class="rounded-lg border border-n-weak bg-n-alpha-1 px-3 py-2 text-n-slate-12 outline-none"
                    type="number"
                    min="1"
                    :max="evalRuns.max_cases"
                  />
                </label>
                <label class="flex items-start gap-2 rounded-lg bg-n-alpha-1 p-3">
                  <input
                    v-model="acknowledgeLlmCost"
                    data-testid="tribunal-acknowledge-cost"
                    type="checkbox"
                    class="mt-1"
                  />
                  <span>{{ t('CAPTAIN.EVALUATIONS.RUN.ACKNOWLEDGE_SHORT') }}</span>
                </label>
              </div>
              <Button
                :label="t('CAPTAIN.EVALUATIONS.TRIBUNAL.DATASET_BUTTON')"
                icon="i-lucide-file-play"
                :is-loading="isRunning"
                :disabled="isRunning || !canRunDatasetEvals"
                @click="runDatasetEvals"
              />
              <pre
                v-if="datasetReport"
                class="overflow-x-auto rounded-lg bg-n-slate-3 p-4 text-xs text-n-slate-12"
              ><code>{{ datasetReport }}</code></pre>
            </div>
          </details>

          <details
            class="group rounded-2xl border border-n-weak bg-n-surface-2 p-4 md:p-5"
          >
            <summary
              class="flex cursor-pointer list-none items-center justify-between gap-3 text-sm font-semibold text-n-slate-12"
            >
              <span class="flex items-center gap-2">
                <i class="i-lucide-download size-4 text-n-teal-10" />
                {{ t('CAPTAIN.EVALUATIONS.IMPORT.TITLE') }}
              </span>
              <i
                class="i-lucide-chevron-down size-4 text-n-slate-10 transition group-open:rotate-180"
              />
            </summary>
            <div class="mt-4 grid gap-3">
              <label class="flex flex-col gap-1 text-sm text-n-slate-11">
                <span class="flex items-center gap-1">
                  {{ t('CAPTAIN.EVALUATIONS.IMPORT.INBOX_ID') }}
                  <i
                    v-tooltip.top="t('CAPTAIN.EVALUATIONS.IMPORT.DESCRIPTION')"
                    class="i-lucide-info size-3.5 text-n-slate-10"
                  />
                </span>
                <input
                  v-model="importInboxId"
                  data-testid="import-inbox-id"
                  class="rounded-lg border border-n-weak bg-n-alpha-1 px-3 py-2 text-n-slate-12 outline-none"
                  type="text"
                />
              </label>
              <label class="flex flex-col gap-1 text-sm text-n-slate-11">
                <span>{{ t('CAPTAIN.EVALUATIONS.IMPORT.DISPLAY_ID') }}</span>
                <input
                  v-model="importDisplayId"
                  data-testid="import-display-id"
                  class="rounded-lg border border-n-weak bg-n-alpha-1 px-3 py-2 text-n-slate-12 outline-none"
                  type="text"
                />
              </label>
              <Button
                :label="t('CAPTAIN.EVALUATIONS.IMPORT.BUTTON')"
                icon="i-lucide-download"
                :is-loading="isRunning"
                :disabled="isRunning || !canImportConversation"
                @click="importConversation"
              />
              <pre
                v-if="importedFixtureYaml"
                class="overflow-x-auto rounded-lg bg-n-slate-3 p-4 text-xs text-n-slate-12"
              ><code>{{ importedFixtureYaml }}</code></pre>
            </div>
          </details>
        </div>
      </section>
    </template>
  </PageLayout>
</template>
