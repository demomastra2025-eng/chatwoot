<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';

const { t } = useI18n();

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
          class="rounded-xl border border-n-weak bg-n-alpha-2 p-6 flex flex-col gap-3"
        >
          <div class="flex items-center gap-2 text-n-brand">
            <i class="i-lucide-gavel size-5" />
            <span class="text-sm font-medium uppercase tracking-wide">
              {{ t('CAPTAIN.EVALUATIONS.BADGE') }}
            </span>
          </div>
          <h2 class="text-2xl font-semibold text-n-slate-12">
            {{ t('CAPTAIN.EVALUATIONS.HERO_TITLE') }}
          </h2>
          <p class="max-w-3xl text-sm leading-6 text-n-slate-11">
            {{ t('CAPTAIN.EVALUATIONS.HERO_DESCRIPTION') }}
          </p>
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
