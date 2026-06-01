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
      'captain.confirmation_safety',
      'captain.ai_voice_trace',
      'captain.voice_scenarios',
      'captain.event_contract_trace',
      'captain.knowledge_rag_trace',
      'captain.product_case_correctness',
      'captain.scenarios',
      'openrouter.contracts',
      'captain.red_team',
    ],
  },
  {
    id: 'safety',
    icon: 'i-lucide-shield-check',
    color: 'text-n-teal-11 bg-n-teal-3',
    packIds: [
      'llm.moderation',
      'captain.tool_safety',
      'captain.confirmation_safety',
      'captain.red_team',
    ],
  },
  {
    id: 'voice',
    icon: 'i-lucide-phone-call',
    color: 'text-n-violet-11 bg-n-violet-3',
    packIds: ['captain.ai_voice_trace', 'captain.voice_scenarios'],
  },
  {
    id: 'tools',
    icon: 'i-lucide-wrench',
    color: 'text-n-slate-11 bg-n-slate-3',
    packIds: [
      'captain.tool_safety',
      'captain.confirmation_safety',
      'captain.product_case_correctness',
      'captain.scenarios',
      'openrouter.contracts',
    ],
  },
  {
    id: 'simulation',
    icon: 'i-lucide-route',
    color: 'text-n-sky-11 bg-n-sky-3',
    packIds: ['captain.scenario_simulation'],
  },
  {
    id: 'redTeamLive',
    icon: 'i-lucide-shield-alert',
    color: 'text-n-ruby-11 bg-n-ruby-3',
    packIds: ['captain.scenario_red_team'],
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
const recentEvalRuns = ref([]);
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

const packGroups = computed(() => {
  const defaultPackIds = new Set(
    packs.value.filter(pack => pack.default_enabled).map(pack => pack.id)
  );
  const groups = [
    {
      id: 'fast',
      title: t('CAPTAIN.EVALUATIONS.PACK_GROUPS.FAST'),
      packs: packs.value.filter(
        pack => pack.deterministic && defaultPackIds.has(pack.id)
      ),
    },
    {
      id: 'live',
      title: t('CAPTAIN.EVALUATIONS.PACK_GROUPS.LIVE'),
      packs: packs.value.filter(pack => pack.live_model),
    },
    {
      id: 'other',
      title: t('CAPTAIN.EVALUATIONS.PACK_GROUPS.OTHER'),
      packs: packs.value.filter(
        pack => !pack.live_model && !defaultPackIds.has(pack.id)
      ),
    },
  ];

  return groups.filter(group => group.packs.length);
});

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

const releaseGateStatusLabel = gate =>
  gate?.status === 'pass'
    ? t('CAPTAIN.EVALUATIONS.RELEASE_GATE.PASS')
    : t('CAPTAIN.EVALUATIONS.RELEASE_GATE.FAIL');

const releaseGateCategoryCounts = gate => {
  const summary = gate?.summary || {};
  return [
    {
      key: 'SCHEMA_INVALID',
      count: summary.schema_invalid_count,
      label: t('CAPTAIN.EVALUATIONS.RELEASE_GATE.SCHEMA_INVALID', {
        count: summary.schema_invalid_count,
      }),
    },
    {
      key: 'TOOL_FAILURE',
      count: summary.tool_failure_count,
      label: t('CAPTAIN.EVALUATIONS.RELEASE_GATE.TOOL_FAILURE', {
        count: summary.tool_failure_count,
      }),
    },
    {
      key: 'NO_CONTENT',
      count: summary.no_content_count,
      label: t('CAPTAIN.EVALUATIONS.RELEASE_GATE.NO_CONTENT', {
        count: summary.no_content_count,
      }),
    },
    {
      key: 'ZERO_COMPLETION',
      count: summary.zero_completion_count,
      label: t('CAPTAIN.EVALUATIONS.RELEASE_GATE.ZERO_COMPLETION', {
        count: summary.zero_completion_count,
      }),
    },
    {
      key: 'CATALOG_STALE',
      count: summary.catalog_stale_count,
      label: t('CAPTAIN.EVALUATIONS.RELEASE_GATE.CATALOG_STALE', {
        count: summary.catalog_stale_count,
      }),
    },
    {
      key: 'CRITICAL_FAILURE',
      count: summary.critical_failure_count,
      label: t('CAPTAIN.EVALUATIONS.RELEASE_GATE.CRITICAL_FAILURE', {
        count: summary.critical_failure_count,
      }),
    },
  ].filter(category => Number(category.count || 0) > 0);
};

const formatPassRate = value => {
  const numericValue = Number(value || 0);
  if (!Number.isFinite(numericValue)) return '0%';

  return `${Math.round(numericValue * 100)}%`;
};

const resultPassRate = computed(
  () =>
    result.value?.pass_rate ??
    result.value?.release_gate?.summary?.pass_rate ??
    0
);

const suiteCases = suite => suite.case_summaries || suite.cases || [];

const resultFailedScenarios = computed(() => {
  if (result.value?.failed_scenarios?.length)
    return result.value.failed_scenarios;

  return (result.value?.suites || []).flatMap(suite =>
    suiteCases(suite)
      .filter(caseResult => caseResult.status && caseResult.status !== 'pass')
      .map(caseResult => ({ ...caseResult, suite_id: suite.suite_id }))
  );
});

const visibleFailedScenarios = computed(() =>
  resultFailedScenarios.value.slice(0, 5)
);

const failedScenarioFailures = scenario =>
  (scenario.failures || []).slice(0, 2);

const visibleSuiteCases = suite => suiteCases(suite).slice(0, 4);

const caseFailures = caseResult => (caseResult.failures || []).slice(0, 2);

const caseTags = caseResult => (caseResult.tags || []).slice(0, 4);

const caseTimeline = caseResult =>
  (caseResult.artifact?.timeline || []).slice(-4);

const caseUsage = caseResult => caseResult.artifact?.usage || null;

const hasCaseUsage = caseResult => {
  const usage = caseUsage(caseResult);
  return Boolean(
    usage?.estimated_cost ||
      usage?.token_totals?.total_tokens ||
      usage?.providers?.length ||
      usage?.models?.length
  );
};

const usageProviders = caseResult =>
  (caseUsage(caseResult)?.providers || []).join(', ');

const usageModels = caseResult =>
  (caseUsage(caseResult)?.models || []).join(', ');

const usageTokens = caseResult =>
  caseUsage(caseResult)?.token_totals?.total_tokens;

const usageCost = caseResult => caseUsage(caseResult)?.estimated_cost;

const timelineIcon = item => {
  if (item.type === 'tool') return 'i-lucide-wrench';
  if (item.type === 'judge') return 'i-lucide-scale';
  if (item.role === 'assistant') return 'i-lucide-bot';
  if (item.role === 'user') return 'i-lucide-user-round';

  return 'i-lucide-circle-dot';
};

const timelineLabel = item =>
  item.preview || item.tool_name || item.action || item.role || item.type;

const resultFromRun = run => run?.result || null;

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
    title: t('CAPTAIN.EVALUATIONS.SCENARIOS.SIMULATION.TITLE'),
    short: t('CAPTAIN.EVALUATIONS.SCENARIOS.SIMULATION.SHORT'),
    tooltip: t('CAPTAIN.EVALUATIONS.SCENARIOS.SIMULATION.TOOLTIP'),
  }),
  withCatalogState({
    ...SCENARIO_DEFINITIONS[5],
    title: t('CAPTAIN.EVALUATIONS.SCENARIOS.RED_TEAM_LIVE.TITLE'),
    short: t('CAPTAIN.EVALUATIONS.SCENARIOS.RED_TEAM_LIVE.SHORT'),
    tooltip: t('CAPTAIN.EVALUATIONS.SCENARIOS.RED_TEAM_LIVE.TOOLTIP'),
  }),
  withCatalogState({
    ...SCENARIO_DEFINITIONS[6],
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
    case 'captain.confirmation_safety':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.CONFIRMATION.LABEL');
    case 'captain.ai_voice_trace':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.AI_VOICE.LABEL');
    case 'captain.voice_scenarios':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.VOICE_SCENARIOS.LABEL');
    case 'captain.event_contract_trace':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.EVENT_CONTRACT.LABEL');
    case 'captain.knowledge_rag_trace':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.KNOWLEDGE_RAG.LABEL');
    case 'captain.product_case_correctness':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.PRODUCT_CASE.LABEL');
    case 'captain.scenarios':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.SCENARIOS.LABEL');
    case 'captain.scenario_simulation':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.SCENARIO_SIMULATION.LABEL');
    case 'captain.scenario_red_team':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.SCENARIO_RED_TEAM.LABEL');
    case 'openrouter.contracts':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.OPENROUTER_CONTRACTS.LABEL');
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
    case 'captain.confirmation_safety':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.CONFIRMATION.DESCRIPTION');
    case 'captain.ai_voice_trace':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.AI_VOICE.DESCRIPTION');
    case 'captain.voice_scenarios':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.VOICE_SCENARIOS.DESCRIPTION');
    case 'captain.event_contract_trace':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.EVENT_CONTRACT.DESCRIPTION');
    case 'captain.knowledge_rag_trace':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.KNOWLEDGE_RAG.DESCRIPTION');
    case 'captain.product_case_correctness':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.PRODUCT_CASE.DESCRIPTION');
    case 'captain.scenarios':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.SCENARIOS.DESCRIPTION');
    case 'captain.scenario_simulation':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.SCENARIO_SIMULATION.DESCRIPTION');
    case 'captain.scenario_red_team':
      return t('CAPTAIN.EVALUATIONS.PACK_COPY.SCENARIO_RED_TEAM.DESCRIPTION');
    case 'openrouter.contracts':
      return t(
        'CAPTAIN.EVALUATIONS.PACK_COPY.OPENROUTER_CONTRACTS.DESCRIPTION'
      );
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
    recentEvalRuns.value = response.data?.recent_eval_runs || [];
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
      recentEvalRuns.value = [
        response.data.run,
        ...recentEvalRuns.value.filter(run => run.id !== response.data.run.id),
      ].slice(0, 10);
      result.value = resultFromRun(response.data.run);
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
    result.value = resultFromRun(response.data?.run) || result.value;
    if (response.data?.run) {
      recentEvalRuns.value = recentEvalRuns.value.map(run =>
        run.id === response.data.run.id ? response.data.run : run
      );
    }
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

        <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-4 2xl:grid-cols-7">
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
          v-if="recentEvalRuns.length"
          data-testid="eval-run-history"
          class="rounded-2xl border border-n-weak bg-n-surface-2 p-5"
        >
          <h3 class="text-base font-semibold text-n-slate-12">
            {{ t('CAPTAIN.EVALUATIONS.RUN.HISTORY') }}
          </h3>
          <div class="mt-4 grid gap-2">
            <div
              v-for="run in recentEvalRuns"
              :key="run.id"
              data-testid="eval-run-history-item"
              class="rounded-xl border border-n-weak bg-n-alpha-1 p-3 text-sm"
            >
              <div class="flex flex-wrap items-center justify-between gap-2">
                <span class="font-medium text-n-slate-12">
                  {{
                    t('CAPTAIN.EVALUATIONS.RUN.LAST_RUN_WITH_ID', {
                      id: run.id,
                    })
                  }}
                </span>
                <span
                  class="rounded-full px-2 py-0.5 text-xs font-medium"
                  :class="statusTone(run.status)"
                >
                  {{ run.status }}
                </span>
              </div>
              <div
                v-if="run.result_summary"
                class="mt-2 flex flex-wrap items-center gap-2 text-xs text-n-slate-10"
              >
                <span>
                  {{
                    t('CAPTAIN.EVALUATIONS.RUN.HISTORY_SUITES', {
                      count: run.result_summary.suite_count || 0,
                    })
                  }}
                </span>
                <span>
                  {{
                    t('CAPTAIN.EVALUATIONS.RUN.HISTORY_PASSED', {
                      count: run.result_summary.passed_count || 0,
                    })
                  }}
                </span>
                <span>
                  {{
                    t('CAPTAIN.EVALUATIONS.RUN.HISTORY_FAILED', {
                      count: run.result_summary.failed_count || 0,
                    })
                  }}
                </span>
              </div>
              <p
                v-if="run.result_summary?.suite_ids?.length"
                class="mt-2 text-xs text-n-slate-10"
              >
                {{ run.result_summary.suite_ids.join(', ') }}
              </p>
            </div>
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
          <div class="mt-4 grid gap-3 md:grid-cols-4 xl:grid-cols-7">
            <div class="rounded-xl bg-n-alpha-1 p-3">
              <p class="text-xs text-n-slate-10">
                {{ t('CAPTAIN.EVALUATIONS.RESULTS.PASSED') }}
              </p>
              <p class="mt-1 text-lg font-semibold text-n-slate-12">
                {{ formatCount(result.passed_count, result.total_count) }}
              </p>
            </div>
            <div
              class="rounded-xl bg-n-alpha-1 p-3"
              data-testid="eval-pass-rate"
            >
              <p class="text-xs text-n-slate-10">
                {{ t('CAPTAIN.EVALUATIONS.RESULTS.PASS_RATE') }}
              </p>
              <p class="mt-1 text-lg font-semibold text-n-slate-12">
                {{ formatPassRate(resultPassRate) }}
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
            <div v-if="result.duration_ms" class="rounded-xl bg-n-alpha-1 p-3">
              <p class="text-xs text-n-slate-10">
                {{ t('CAPTAIN.EVALUATIONS.RESULTS.DURATION') }}
              </p>
              <p class="mt-1 text-lg font-semibold text-n-slate-12">
                {{
                  t('CAPTAIN.EVALUATIONS.RESULTS.DURATION_MS', {
                    ms: result.duration_ms,
                  })
                }}
              </p>
            </div>
            <div
              v-if="result.estimated_cost"
              class="rounded-xl bg-n-alpha-1 p-3"
            >
              <p class="text-xs text-n-slate-10">
                {{ t('CAPTAIN.EVALUATIONS.RESULTS.ESTIMATED_COST') }}
              </p>
              <p class="mt-1 text-lg font-semibold text-n-slate-12">
                {{
                  t('CAPTAIN.EVALUATIONS.RESULTS.COST', {
                    cost: result.estimated_cost,
                  })
                }}
              </p>
            </div>
          </div>
          <div
            v-if="result.release_gate"
            data-testid="eval-release-gate"
            class="mt-4 rounded-xl border border-n-weak bg-n-alpha-1 p-3 text-sm text-n-slate-11"
          >
            <div class="flex flex-wrap items-center justify-between gap-2">
              <div>
                <p class="font-medium text-n-slate-12">
                  {{ t('CAPTAIN.EVALUATIONS.RELEASE_GATE.TITLE') }}
                </p>
                <p
                  v-if="result.release_gate.required_pack_ids?.length"
                  class="mt-1 text-xs text-n-slate-10"
                >
                  {{
                    t('CAPTAIN.EVALUATIONS.RELEASE_GATE.REQUIRED_PACKS', {
                      count: result.release_gate.required_pack_ids.length,
                    })
                  }}
                </p>
              </div>
              <span
                class="rounded-full px-2 py-0.5 text-xs font-medium"
                :class="statusTone(result.release_gate.status)"
              >
                {{ releaseGateStatusLabel(result.release_gate) }}
              </span>
            </div>
            <div
              v-if="releaseGateCategoryCounts(result.release_gate).length"
              class="mt-3 flex flex-wrap gap-2"
            >
              <span
                v-for="category in releaseGateCategoryCounts(
                  result.release_gate
                )"
                :key="category.key"
                class="rounded-full bg-n-alpha-2 px-2 py-1 text-xs text-n-slate-11"
              >
                {{ category.label }}
              </span>
            </div>
            <ul
              v-if="result.release_gate.failures?.length"
              class="mt-3 list-disc space-y-1 pl-4 text-xs text-n-ruby-11"
            >
              <li
                v-for="failure in result.release_gate.failures"
                :key="failure"
              >
                {{ failure }}
              </li>
            </ul>
          </div>
          <div
            v-if="visibleFailedScenarios.length"
            data-testid="eval-failed-scenarios"
            class="mt-4 rounded-xl border border-n-ruby-5 bg-n-ruby-2 p-3 text-sm text-n-ruby-11"
          >
            <p class="font-medium text-n-ruby-12">
              {{ t('CAPTAIN.EVALUATIONS.RESULTS.FAILED_SCENARIOS') }}
            </p>
            <div class="mt-3 grid gap-2">
              <article
                v-for="scenario in visibleFailedScenarios"
                :key="`${scenario.suite_id}-${scenario.id}`"
                class="rounded-lg bg-n-alpha-1 p-3"
              >
                <div class="flex flex-wrap items-center justify-between gap-2">
                  <span class="font-medium text-n-ruby-12">
                    {{ scenario.id }}
                  </span>
                  <span class="text-xs text-n-ruby-10">
                    {{ scenario.suite_id }}
                    <template v-if="scenario.duration_ms">
                      {{ t('CAPTAIN.EVALUATIONS.RESULTS.SEPARATOR') }}
                      {{
                        t('CAPTAIN.EVALUATIONS.RESULTS.DURATION_MS', {
                          ms: scenario.duration_ms,
                        })
                      }}
                    </template>
                  </span>
                </div>
                <ul
                  v-if="failedScenarioFailures(scenario).length"
                  class="mt-2 list-disc space-y-1 pl-4 text-xs"
                >
                  <li
                    v-for="failure in failedScenarioFailures(scenario)"
                    :key="failure"
                  >
                    {{ failure }}
                  </li>
                </ul>
              </article>
            </div>
          </div>
          <div class="mt-4 grid gap-2">
            <div
              v-for="suite in result.suites"
              :key="suite.suite_id"
              class="rounded-xl border border-n-weak bg-n-alpha-1 p-3 text-sm"
            >
              <div class="flex items-center justify-between gap-3">
                <span class="min-w-0">
                  <span class="block font-medium text-n-slate-12">
                    {{ suite.suite_id }}
                  </span>
                  <span class="mt-1 block text-xs text-n-slate-10">
                    {{
                      t('CAPTAIN.EVALUATIONS.RESULTS.CASES_COUNT', {
                        count: suite.total_count || suiteCases(suite).length,
                      })
                    }}
                  </span>
                </span>
                <span class="flex shrink-0 items-center gap-2">
                  <span
                    v-if="suite.failed_count || suite.error_count"
                    class="text-xs text-n-ruby-11"
                  >
                    {{
                      t('CAPTAIN.EVALUATIONS.RESULTS.ISSUES_COUNT', {
                        count:
                          (suite.failed_count || 0) + (suite.error_count || 0),
                      })
                    }}
                  </span>
                  <span
                    class="rounded-full px-2 py-0.5 text-xs font-medium"
                    :class="statusTone(suite.status)"
                  >
                    {{ formatCount(suite.passed_count, suite.total_count) }}
                  </span>
                </span>
              </div>
              <div
                v-if="visibleSuiteCases(suite).length"
                class="mt-3 grid gap-2"
              >
                <article
                  v-for="caseResult in visibleSuiteCases(suite)"
                  :key="caseResult.id"
                  class="rounded-lg border border-n-weak bg-n-surface-2 p-3"
                >
                  <div class="flex flex-wrap items-start justify-between gap-2">
                    <div class="min-w-0">
                      <p class="break-words font-medium text-n-slate-12">
                        {{ caseResult.id }}
                      </p>
                      <p
                        v-if="caseResult.description"
                        class="mt-1 line-clamp-2 text-xs text-n-slate-10"
                      >
                        {{ caseResult.description }}
                      </p>
                    </div>
                    <span
                      class="rounded-full px-2 py-0.5 text-xs font-medium"
                      :class="statusTone(caseResult.status)"
                    >
                      {{ caseResult.status }}
                    </span>
                  </div>
                  <div
                    v-if="caseTags(caseResult).length || caseResult.duration_ms"
                    class="mt-2 flex flex-wrap items-center gap-2 text-xs text-n-slate-10"
                  >
                    <span
                      v-for="tag in caseTags(caseResult)"
                      :key="tag"
                      class="rounded-full bg-n-alpha-2 px-2 py-0.5"
                    >
                      {{ tag }}
                    </span>
                    <span v-if="caseResult.duration_ms">
                      {{
                        t('CAPTAIN.EVALUATIONS.RESULTS.DURATION_MS', {
                          ms: caseResult.duration_ms,
                        })
                      }}
                    </span>
                  </div>
                  <div
                    v-if="caseFailures(caseResult).length"
                    class="mt-2 grid gap-1"
                  >
                    <p
                      v-for="failure in caseFailures(caseResult)"
                      :key="failure"
                      class="rounded-lg border border-n-ruby-5 bg-n-ruby-2 px-2 py-1 text-xs text-n-ruby-11"
                    >
                      {{ failure }}
                    </p>
                  </div>
                  <div
                    v-if="hasCaseUsage(caseResult)"
                    class="mt-3 flex flex-wrap items-center gap-2 border-t border-n-weak pt-3 text-xs text-n-slate-10"
                  >
                    <span
                      v-if="usageProviders(caseResult)"
                      class="flex items-center gap-1 rounded-full bg-n-alpha-2 px-2 py-0.5"
                    >
                      <i class="i-lucide-router size-3" />
                      {{ usageProviders(caseResult) }}
                    </span>
                    <span
                      v-if="usageModels(caseResult)"
                      class="flex items-center gap-1 rounded-full bg-n-alpha-2 px-2 py-0.5"
                    >
                      <i class="i-lucide-cpu size-3" />
                      {{ usageModels(caseResult) }}
                    </span>
                    <span
                      v-if="usageTokens(caseResult)"
                      class="flex items-center gap-1 rounded-full bg-n-alpha-2 px-2 py-0.5"
                    >
                      <i class="i-lucide-coins size-3" />
                      {{
                        t('CAPTAIN.EVALUATIONS.RESULTS.TOKENS', {
                          count: usageTokens(caseResult),
                        })
                      }}
                    </span>
                    <span
                      v-if="usageCost(caseResult)"
                      class="flex items-center gap-1 rounded-full bg-n-alpha-2 px-2 py-0.5"
                    >
                      <i class="i-lucide-receipt-text size-3" />
                      {{
                        t('CAPTAIN.EVALUATIONS.RESULTS.COST', {
                          cost: usageCost(caseResult),
                        })
                      }}
                    </span>
                  </div>
                  <div
                    v-if="caseTimeline(caseResult).length"
                    class="mt-3 grid gap-1 border-t border-n-weak pt-3"
                  >
                    <div
                      v-for="item in caseTimeline(caseResult)"
                      :key="`${caseResult.id}-${item.index}`"
                      class="flex items-start gap-2 text-xs text-n-slate-10"
                    >
                      <i :class="timelineIcon(item)" class="mt-0.5 size-3.5" />
                      <span class="break-words">
                        {{ timelineLabel(item) }}
                      </span>
                    </div>
                  </div>
                </article>
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

          <div class="mt-4 grid gap-4">
            <section
              v-for="group in packGroups"
              :key="group.id"
              class="grid gap-2"
            >
              <h4 class="text-sm font-semibold text-n-slate-12">
                {{ group.title }}
              </h4>
              <div class="grid gap-3 md:grid-cols-2">
                <label
                  v-for="pack in group.packs"
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
                        <h5 class="text-sm font-semibold text-n-slate-12">
                          {{ packLabel(pack) }}
                        </h5>
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
            </section>
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
                <label
                  class="flex items-start gap-2 rounded-lg bg-n-alpha-1 p-3"
                >
                  <input
                    v-model="acknowledgeLlmCost"
                    data-testid="tribunal-acknowledge-cost"
                    type="checkbox"
                    class="mt-1"
                  />
                  <span>{{
                    t('CAPTAIN.EVALUATIONS.RUN.ACKNOWLEDGE_SHORT')
                  }}</span>
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
