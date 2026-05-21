<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import captainEvaluationsAPI from 'dashboard/api/captain/evaluations';

const { t } = useI18n();

const packs = ref([]);
const result = ref(null);
const liveEvals = ref({ enabled: false });
const liveRun = ref(null);
const liveBudgetCents = ref('100');
const liveMaxCases = ref('3');
const acknowledgeLiveCost = ref(false);
const importInboxId = ref('');
const importDisplayId = ref('');
const importedFixtureYaml = ref('');
const isLoadingCatalog = ref(false);
const isRunning = ref(false);
const errorMessage = ref('');

const evaluationPillars = computed(() => [
  {
    key: 'deterministic',
    icon: 'i-lucide-list-checks',
    title: t('CAPTAIN.EVALUATIONS.PILLARS.DETERMINISTIC.TITLE'),
    description: t('CAPTAIN.EVALUATIONS.PILLARS.DETERMINISTIC.DESCRIPTION'),
  },
  {
    key: 'judge',
    icon: 'i-lucide-scale',
    title: t('CAPTAIN.EVALUATIONS.PILLARS.JUDGE.TITLE'),
    description: t('CAPTAIN.EVALUATIONS.PILLARS.JUDGE.DESCRIPTION'),
  },
  {
    key: 'safety',
    icon: 'i-lucide-shield-check',
    title: t('CAPTAIN.EVALUATIONS.PILLARS.SAFETY.TITLE'),
    description: t('CAPTAIN.EVALUATIONS.PILLARS.SAFETY.DESCRIPTION'),
  },
]);

const evaluationTargets = computed(() => [
  t('CAPTAIN.EVALUATIONS.TARGETS.TOOL_RESULTS'),
  t('CAPTAIN.EVALUATIONS.TARGETS.RAG_CONTEXT'),
  t('CAPTAIN.EVALUATIONS.TARGETS.VOICE_TRANSCRIPTS'),
  t('CAPTAIN.EVALUATIONS.TARGETS.SAFETY'),
]);

const deterministicPacks = computed(() =>
  packs.value.filter(pack => pack.default_enabled && !pack.live_model)
);

const livePacks = computed(() => packs.value.filter(pack => pack.live_model));

const canRunLiveEvals = computed(
  () =>
    liveEvals.value?.enabled &&
    livePacks.value.length &&
    acknowledgeLiveCost.value &&
    liveBudgetCents.value &&
    liveMaxCases.value
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

const liveRunTitle = computed(() =>
  liveRun.value?.id
    ? t('CAPTAIN.EVALUATIONS.LIVE.LAST_RUN_WITH_ID', { id: liveRun.value.id })
    : ''
);

const liveRunStatus = computed(() =>
  liveRun.value?.status
    ? t('CAPTAIN.EVALUATIONS.LIVE.STATUS_WITH_VALUE', {
        status: liveRun.value.status,
      })
    : ''
);

const fetchCatalog = async () => {
  isLoadingCatalog.value = true;
  errorMessage.value = '';

  try {
    const response = await captainEvaluationsAPI.get();
    packs.value = response.data?.packs || [];
    liveEvals.value = response.data?.live_evals || { enabled: false };
    liveRun.value = response.data?.latest_live_run || null;
  } catch (error) {
    errorMessage.value = t('CAPTAIN.EVALUATIONS.ERRORS.CATALOG_FAILED');
  } finally {
    isLoadingCatalog.value = false;
  }
};

const runDeterministicEvals = async () => {
  isRunning.value = true;
  errorMessage.value = '';

  try {
    const response = await captainEvaluationsAPI.run({
      pack_ids: deterministicPacks.value.map(pack => pack.id),
    });
    result.value = response.data?.result || null;
    packs.value = response.data?.packs || packs.value;
  } catch (error) {
    errorMessage.value = t('CAPTAIN.EVALUATIONS.ERRORS.RUN_FAILED');
  } finally {
    isRunning.value = false;
  }
};

const formatCount = (passedCount, totalCount) =>
  `${passedCount} / ${totalCount}`;

const runLiveEvals = async () => {
  isRunning.value = true;
  errorMessage.value = '';

  try {
    const response = await captainEvaluationsAPI.runLive({
      pack_ids: livePacks.value.map(pack => pack.id),
      acknowledge_live_cost: acknowledgeLiveCost.value,
      budget_cents: Number(liveBudgetCents.value),
      max_cases: Number(liveMaxCases.value),
    });
    liveRun.value = response.data?.run || null;
    liveEvals.value = response.data?.live_evals || liveEvals.value;
    packs.value = response.data?.packs || packs.value;
  } catch (error) {
    errorMessage.value = t('CAPTAIN.EVALUATIONS.ERRORS.LIVE_RUN_FAILED');
  } finally {
    isRunning.value = false;
  }
};

const refreshLiveRun = async () => {
  if (!liveRun.value?.id) return;
  isRunning.value = true;
  errorMessage.value = '';

  try {
    const response = await captainEvaluationsAPI.getLiveRun(liveRun.value.id);
    liveRun.value = response.data?.run || liveRun.value;
  } catch (error) {
    errorMessage.value = t('CAPTAIN.EVALUATIONS.ERRORS.LIVE_STATUS_FAILED');
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
    errorMessage.value = t('CAPTAIN.EVALUATIONS.ERRORS.IMPORT_FAILED');
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
      <section class="flex flex-col gap-6 pb-10">
        <div
          class="rounded-xl border border-n-weak bg-n-alpha-2 p-6 flex flex-col gap-4"
        >
          <div class="flex items-center gap-2 text-n-brand">
            <i class="i-lucide-gavel size-5" />
            <span class="text-sm font-medium uppercase tracking-wide">
              {{ t('CAPTAIN.EVALUATIONS.BADGE') }}
            </span>
          </div>
          <div
            class="flex flex-col gap-4 md:flex-row md:items-end md:justify-between"
          >
            <div class="flex flex-col gap-3">
              <h2 class="text-2xl font-semibold text-n-slate-12">
                {{ t('CAPTAIN.EVALUATIONS.HERO_TITLE') }}
              </h2>
              <p class="max-w-3xl text-sm leading-6 text-n-slate-11">
                {{ t('CAPTAIN.EVALUATIONS.HERO_DESCRIPTION') }}
              </p>
            </div>
            <Button
              :label="t('CAPTAIN.EVALUATIONS.RUN_DETERMINISTIC')"
              icon="i-lucide-play"
              :is-loading="isRunning"
              :disabled="
                isLoadingCatalog || isRunning || !deterministicPacks.length
              "
              @click="runDeterministicEvals"
            />
          </div>
        </div>

        <div
          v-if="errorMessage"
          class="rounded-xl border border-n-ruby-5 bg-n-ruby-2 p-4 text-sm text-n-ruby-11"
        >
          {{ errorMessage }}
        </div>

        <div class="grid gap-4 md:grid-cols-3">
          <article
            v-for="pillar in evaluationPillars"
            :key="pillar.key"
            class="rounded-xl border border-n-weak bg-n-surface-2 p-5 flex flex-col gap-3"
          >
            <div
              class="size-10 rounded-lg bg-n-brand/10 text-n-brand flex items-center justify-center"
            >
              <i :class="pillar.icon" class="size-5" />
            </div>
            <h3 class="text-base font-semibold text-n-slate-12">
              {{ pillar.title }}
            </h3>
            <p class="text-sm leading-6 text-n-slate-11">
              {{ pillar.description }}
            </p>
          </article>
        </div>

        <div class="rounded-xl border border-n-weak bg-n-surface-2 p-5">
          <h3 class="text-base font-semibold text-n-slate-12 mb-3">
            {{ t('CAPTAIN.EVALUATIONS.TARGETS_TITLE') }}
          </h3>
          <ul class="grid gap-3 md:grid-cols-2">
            <li
              v-for="target in evaluationTargets"
              :key="target"
              class="flex items-start gap-2 text-sm text-n-slate-11"
            >
              <i class="i-lucide-check-circle-2 size-4 text-n-teal-10 mt-0.5" />
              <span>{{ target }}</span>
            </li>
          </ul>
        </div>

        <div class="rounded-xl border border-n-weak bg-n-surface-2 p-5">
          <div class="flex items-center justify-between gap-3 mb-4">
            <h3 class="text-base font-semibold text-n-slate-12">
              {{ t('CAPTAIN.EVALUATIONS.PACKS.TITLE') }}
            </h3>
            <span v-if="isLoadingCatalog" class="text-sm text-n-slate-11">
              {{ t('CAPTAIN.EVALUATIONS.PACKS.LOADING') }}
            </span>
          </div>
          <div class="grid gap-3 md:grid-cols-2">
            <article
              v-for="pack in packs"
              :key="pack.id"
              class="rounded-lg border border-n-weak bg-n-alpha-1 p-4 flex flex-col gap-2"
            >
              <div class="flex items-start justify-between gap-3">
                <div>
                  <h4 class="text-sm font-semibold text-n-slate-12">
                    {{ pack.label }}
                  </h4>
                  <p class="mt-1 text-xs text-n-slate-10">
                    {{ pack.id }}
                  </p>
                </div>
                <span
                  class="shrink-0 rounded-full px-2 py-1 text-xs font-medium"
                  :class="
                    pack.live_model
                      ? 'bg-n-amber-3 text-n-amber-11'
                      : 'bg-n-teal-3 text-n-teal-11'
                  "
                >
                  {{
                    pack.live_model
                      ? t('CAPTAIN.EVALUATIONS.PACKS.LIVE_LOCKED')
                      : t('CAPTAIN.EVALUATIONS.PACKS.OFFLINE')
                  }}
                </span>
              </div>
              <p class="text-sm leading-6 text-n-slate-11">
                {{ pack.description }}
              </p>
            </article>
          </div>
        </div>

        <div class="rounded-xl border border-n-weak bg-n-surface-2 p-5">
          <div class="flex items-center justify-between gap-3 mb-4">
            <h3 class="text-base font-semibold text-n-slate-12">
              {{ t('CAPTAIN.EVALUATIONS.LIVE.TITLE') }}
            </h3>
            <span
              class="rounded-full px-2 py-1 text-xs font-medium"
              :class="
                liveEvals.enabled
                  ? 'bg-n-teal-3 text-n-teal-11'
                  : 'bg-n-amber-3 text-n-amber-11'
              "
            >
              {{
                liveEvals.enabled
                  ? t('CAPTAIN.EVALUATIONS.LIVE.ENABLED')
                  : t('CAPTAIN.EVALUATIONS.LIVE.DISABLED')
              }}
            </span>
          </div>
          <p class="text-sm leading-6 text-n-slate-11 mb-4">
            {{ t('CAPTAIN.EVALUATIONS.LIVE.DESCRIPTION') }}
          </p>
          <div class="grid gap-3 md:grid-cols-[1fr_1fr_auto] md:items-end">
            <label class="flex flex-col gap-1 text-sm text-n-slate-11">
              <span>{{ t('CAPTAIN.EVALUATIONS.LIVE.BUDGET_CENTS') }}</span>
              <input
                v-model="liveBudgetCents"
                class="rounded-lg border border-n-weak bg-n-alpha-1 px-3 py-2 text-n-slate-12 outline-none"
                type="number"
                min="1"
                :max="liveEvals.max_budget_cents"
              />
            </label>
            <label class="flex flex-col gap-1 text-sm text-n-slate-11">
              <span>{{ t('CAPTAIN.EVALUATIONS.LIVE.MAX_CASES') }}</span>
              <input
                v-model="liveMaxCases"
                class="rounded-lg border border-n-weak bg-n-alpha-1 px-3 py-2 text-n-slate-12 outline-none"
                type="number"
                min="1"
                :max="liveEvals.max_cases"
              />
            </label>
            <Button
              :label="t('CAPTAIN.EVALUATIONS.LIVE.BUTTON')"
              icon="i-lucide-scale"
              :is-loading="isRunning"
              :disabled="isRunning || !canRunLiveEvals"
              @click="runLiveEvals"
            />
          </div>
          <label class="mt-3 flex items-start gap-2 text-sm text-n-slate-11">
            <input v-model="acknowledgeLiveCost" type="checkbox" class="mt-1" />
            <span>{{ t('CAPTAIN.EVALUATIONS.LIVE.ACKNOWLEDGE') }}</span>
          </label>
          <div
            v-if="liveRun"
            class="mt-4 rounded-lg border border-n-weak bg-n-alpha-1 p-4 text-sm text-n-slate-11"
          >
            <div class="flex items-center justify-between gap-3">
              <div>
                <p class="font-medium text-n-slate-12">
                  {{ liveRunTitle }}
                </p>
                <p class="mt-1">
                  {{ liveRunStatus }}
                </p>
              </div>
              <Button
                :label="t('CAPTAIN.EVALUATIONS.LIVE.REFRESH')"
                icon="i-lucide-refresh-cw"
                :is-loading="isRunning"
                @click="refreshLiveRun"
              />
            </div>
            <pre
              v-if="liveRun.result"
              class="mt-3 overflow-x-auto rounded-lg bg-n-slate-3 p-3 text-xs text-n-slate-12"
            ><code>{{ JSON.stringify(liveRun.result, null, 2) }}</code></pre>
          </div>
        </div>

        <div class="rounded-xl border border-n-weak bg-n-surface-2 p-5">
          <h3 class="text-base font-semibold text-n-slate-12 mb-3">
            {{ t('CAPTAIN.EVALUATIONS.IMPORT.TITLE') }}
          </h3>
          <p class="text-sm leading-6 text-n-slate-11 mb-4">
            {{ t('CAPTAIN.EVALUATIONS.IMPORT.DESCRIPTION') }}
          </p>
          <div class="grid gap-3 md:grid-cols-[1fr_1fr_auto] md:items-end">
            <label class="flex flex-col gap-1 text-sm text-n-slate-11">
              <span>{{ t('CAPTAIN.EVALUATIONS.IMPORT.INBOX_ID') }}</span>
              <input
                v-model="importInboxId"
                class="rounded-lg border border-n-weak bg-n-alpha-1 px-3 py-2 text-n-slate-12 outline-none"
                type="text"
              />
            </label>
            <label class="flex flex-col gap-1 text-sm text-n-slate-11">
              <span>{{ t('CAPTAIN.EVALUATIONS.IMPORT.DISPLAY_ID') }}</span>
              <input
                v-model="importDisplayId"
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
          </div>
          <pre
            v-if="importedFixtureYaml"
            class="mt-4 overflow-x-auto rounded-lg bg-n-slate-3 p-4 text-xs text-n-slate-12"
          ><code>{{ importedFixtureYaml }}</code></pre>
        </div>

        <div
          v-if="result"
          class="rounded-xl border border-n-weak bg-n-surface-2 p-5 flex flex-col gap-4"
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
          <div class="grid gap-3 md:grid-cols-4">
            <div class="rounded-lg bg-n-alpha-1 p-3">
              <p class="text-xs text-n-slate-10">
                {{ t('CAPTAIN.EVALUATIONS.RESULTS.PASSED') }}
              </p>
              <p class="mt-1 text-lg font-semibold text-n-slate-12">
                {{ formatCount(result.passed_count, result.total_count) }}
              </p>
            </div>
            <div class="rounded-lg bg-n-alpha-1 p-3">
              <p class="text-xs text-n-slate-10">
                {{ t('CAPTAIN.EVALUATIONS.RESULTS.SUITES') }}
              </p>
              <p class="mt-1 text-lg font-semibold text-n-slate-12">
                {{ result.suite_count }}
              </p>
            </div>
            <div class="rounded-lg bg-n-alpha-1 p-3">
              <p class="text-xs text-n-slate-10">
                {{ t('CAPTAIN.EVALUATIONS.RESULTS.FAILED') }}
              </p>
              <p class="mt-1 text-lg font-semibold text-n-slate-12">
                {{ result.failed_count }}
              </p>
            </div>
            <div class="rounded-lg bg-n-alpha-1 p-3">
              <p class="text-xs text-n-slate-10">
                {{ t('CAPTAIN.EVALUATIONS.RESULTS.ERRORS') }}
              </p>
              <p class="mt-1 text-lg font-semibold text-n-slate-12">
                {{ result.error_count }}
              </p>
            </div>
          </div>
          <div class="flex flex-col gap-2">
            <div
              v-for="suite in result.suites"
              :key="suite.suite_id"
              class="rounded-lg border border-n-weak p-3 flex items-center justify-between gap-3 text-sm"
            >
              <span class="font-medium text-n-slate-12">{{
                suite.suite_id
              }}</span>
              <span class="text-n-slate-11">
                {{ formatCount(suite.passed_count, suite.total_count) }}
              </span>
            </div>
          </div>
        </div>

        <div class="rounded-xl border border-n-weak bg-n-amber-2 p-5">
          <h3 class="text-base font-semibold text-n-slate-12 mb-2">
            {{ t('CAPTAIN.EVALUATIONS.STATUS_TITLE') }}
          </h3>
          <p class="text-sm leading-6 text-n-slate-11">
            {{ t('CAPTAIN.EVALUATIONS.STATUS_DESCRIPTION') }}
          </p>
        </div>
      </section>
    </template>
  </PageLayout>
</template>
