<script setup>
import { onMounted, ref, watch } from 'vue';
import camelcaseKeys from 'camelcase-keys';
import { useI18n } from 'vue-i18n';

import ResourceServiceStatsAPI from 'dashboard/api/scheduling/resourceServiceStats';
import { useAlert } from 'dashboard/composables';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';

// The services of one specialist that the visit history carries (the MedElement API gives no such relation). A pair counts for the
// slot search and the visit length while it is on; the switch confirms it or disables it for good, the nightly run keeps that choice.

const props = defineProps({
  resourceId: { type: Number, required: true },
});

const { t } = useI18n();

const stats = ref([]);
const isLoading = ref(false);
const hasError = ref(false);
const pendingId = ref(null);

const loadStats = async () => {
  isLoading.value = true;
  hasError.value = false;
  try {
    const { data } = await ResourceServiceStatsAPI.get(props.resourceId);
    stats.value = camelcaseKeys(data?.payload || [], { deep: true });
  } catch {
    stats.value = [];
    hasError.value = true;
  } finally {
    isLoading.value = false;
  }
};

const toggleStat = async (stat, enabled) => {
  pendingId.value = stat.id;
  try {
    const { data } = await ResourceServiceStatsAPI.update(
      props.resourceId,
      stat.id,
      enabled ? 'confirmed' : 'disabled'
    );
    Object.assign(stat, camelcaseKeys(data?.payload || {}, { deep: true }));
  } catch {
    useAlert(t('SCHEDULING.RESOURCES.SERVICE_STATS_ERROR_SAVE'));
  } finally {
    pendingId.value = null;
  }
};

onMounted(loadStats);
watch(() => props.resourceId, loadStats);
</script>

<template>
  <section data-testid="resource-service-stats" class="flex flex-col gap-3">
    <div class="flex min-w-0 flex-col gap-1">
      <h3 class="mb-0 text-sm font-semibold text-n-slate-12">
        {{ t('SCHEDULING.RESOURCES.SERVICE_STATS_TITLE') }}
      </h3>
      <p class="mb-0 text-xs text-n-slate-11">
        {{ t('SCHEDULING.RESOURCES.SERVICE_STATS_DESCRIPTION') }}
      </p>
    </div>

    <div v-if="isLoading" class="flex justify-center py-3">
      <Spinner />
    </div>
    <p
      v-else-if="hasError"
      data-testid="service-stats-error"
      class="mb-0 text-sm text-n-ruby-11"
    >
      {{ t('SCHEDULING.RESOURCES.SERVICE_STATS_ERROR_LOAD') }}
    </p>
    <p
      v-else-if="!stats.length"
      data-testid="service-stats-empty"
      class="mb-0 text-sm text-n-slate-11"
    >
      {{ t('SCHEDULING.RESOURCES.SERVICE_STATS_EMPTY') }}
    </p>
    <ul v-else class="m-0 flex list-none flex-col gap-1.5 p-0">
      <li
        v-for="stat in stats"
        :key="stat.id"
        :data-testid="`service-stat-${stat.id}`"
        class="flex items-center justify-between gap-3 rounded-lg border border-n-weak px-3 py-2"
      >
        <div class="flex min-w-0 flex-col gap-0.5">
          <span
            class="truncate text-sm"
            :class="stat.counts ? 'text-n-slate-12' : 'text-n-slate-10'"
          >
            {{ stat.serviceName }}
          </span>
          <span class="text-xs text-n-slate-11">
            {{
              t('SCHEDULING.RESOURCES.SERVICE_STATS_NUMBERS', {
                count: stat.receptionsCount,
                minutes: stat.medianDurationMin ?? '—',
              })
            }}
          </span>
        </div>
        <div class="flex shrink-0 items-center gap-2">
          <span
            class="rounded-full bg-n-alpha-black2 px-2 py-0.5 text-[11px] font-medium text-n-slate-11"
            :data-testid="`service-stat-status-${stat.id}`"
          >
            {{
              t(
                `SCHEDULING.RESOURCES.SERVICE_STATS_STATUS.${stat.status.toUpperCase()}`
              )
            }}
          </span>
          <Switch
            :model-value="stat.counts"
            :disabled="pendingId === stat.id"
            :data-testid="`service-stat-switch-${stat.id}`"
            @update:model-value="toggleStat(stat, $event)"
          />
        </div>
      </li>
    </ul>
  </section>
</template>
