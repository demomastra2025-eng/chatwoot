<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useAdmin } from 'dashboard/composables/useAdmin';
import { useStoreGetters } from 'dashboard/composables/store';
import MetaAdsSettingsAPI from 'dashboard/api/metaAdsSettings';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import {
  isSystemMetaAdsLabel,
  labelDisplayTitleWithoutMarker,
  labelMarkerColor,
  labelMarkerEmoji,
  labelMarkerType,
  sortLabelsByDisplayTitle,
} from 'dashboard/helper/labels';

const emit = defineEmits(['updated']);

const { t } = useI18n();
const { isAdmin } = useAdmin();
const getters = useStoreGetters();

const isLoading = ref(true);
const hasLoadError = ref(false);
const isSaving = ref(false);
const autoTagEnabled = ref(true);
const sourceRules = ref([]);
const recentSources = ref([]);
const showRules = ref(false);
const newSourceId = ref('');
const newLabelId = ref('');

const allLabels = computed(() => getters['labels/getLabels'].value || []);

const selectableLabels = computed(() =>
  sortLabelsByDisplayTitle(
    allLabels.value.filter(label => !isSystemMetaAdsLabel(label))
  )
);

const recentSourcesById = computed(() => {
  const map = new Map();
  recentSources.value.forEach(item => {
    if (item?.source_id) {
      map.set(String(item.source_id), item);
    }
  });
  return map;
});

const rulesCount = computed(() => sourceRules.value.length);
const systemTagTitle = 'Meta Ads';
const formatReferralCount = count => `(${count})`;

const applyPayload = data => {
  if (!data) return;
  autoTagEnabled.value = Boolean(data.auto_tag_enabled);
  sourceRules.value = Array.isArray(data.source_rules) ? data.source_rules : [];
  recentSources.value = Array.isArray(data.recent_sources)
    ? data.recent_sources
    : [];
};

const fetchSettings = async () => {
  isLoading.value = true;
  hasLoadError.value = false;
  try {
    const { data } = await MetaAdsSettingsAPI.get();
    applyPayload(data);
  } catch {
    hasLoadError.value = true;
    useAlert(t('LABEL_MGMT.META_ADS.ERROR_MESSAGE'));
  } finally {
    isLoading.value = false;
  }
};

const handleToggleAutoTag = async nextValue => {
  if (!isAdmin.value || isLoading.value || hasLoadError.value || isSaving.value)
    return;
  const previous = autoTagEnabled.value;
  const resolvedNext =
    typeof nextValue === 'boolean' && nextValue !== previous
      ? nextValue
      : !previous;
  autoTagEnabled.value = resolvedNext;
  isSaving.value = true;
  try {
    const { data } = await MetaAdsSettingsAPI.updateSettings({
      auto_tag_enabled: resolvedNext,
    });
    applyPayload(data);
    emit('updated');
    useAlert(t('LABEL_MGMT.META_ADS.SAVED_MESSAGE'));
  } catch {
    autoTagEnabled.value = previous;
    useAlert(t('LABEL_MGMT.META_ADS.ERROR_MESSAGE'));
  } finally {
    isSaving.value = false;
  }
};

const persistRules = async nextRulesPayload => {
  if (!isAdmin.value || isLoading.value || hasLoadError.value || isSaving.value)
    return false;
  isSaving.value = true;
  try {
    const { data } = await MetaAdsSettingsAPI.updateSettings({
      source_rules: nextRulesPayload,
    });
    applyPayload(data);
    useAlert(t('LABEL_MGMT.META_ADS.SAVED_MESSAGE'));
    return true;
  } catch {
    useAlert(t('LABEL_MGMT.META_ADS.ERROR_MESSAGE'));
    return false;
  } finally {
    isSaving.value = false;
  }
};

const handleAddRule = async () => {
  const sourceId = newSourceId.value.trim();
  const labelId = Number(newLabelId.value);
  if (!sourceId || !labelId) return;

  const nextMap = new Map();
  sourceRules.value.forEach(rule => {
    nextMap.set(rule.source_id, [...(rule.label_ids || [])]);
  });
  const currentIds = nextMap.get(sourceId) || [];
  if (!currentIds.includes(labelId)) {
    nextMap.set(sourceId, [...currentIds, labelId]);
  }

  const payload = Array.from(nextMap.entries()).map(([src, ids]) => ({
    source_id: src,
    label_ids: ids,
  }));

  const ok = await persistRules(payload);
  if (ok) {
    newSourceId.value = '';
    newLabelId.value = '';
  }
};

const handleRemoveRuleLabel = async (sourceId, labelIdToRemove = null) => {
  const payload = sourceRules.value
    .map(rule => {
      if (rule.source_id !== sourceId) {
        return { source_id: rule.source_id, label_ids: rule.label_ids };
      }
      if (labelIdToRemove === null) return null;
      const remaining = (rule.label_ids || []).filter(
        id => id !== labelIdToRemove
      );
      return remaining.length
        ? { source_id: rule.source_id, label_ids: remaining }
        : null;
    })
    .filter(Boolean);

  await persistRules(payload);
};

const pickRecentSource = sourceId => {
  newSourceId.value = String(sourceId || '');
};

onMounted(fetchSettings);
</script>

<template>
  <section
    data-testid="meta-ads-autotag-settings"
    class="mb-4 rounded-xl bg-n-solid-2 px-4 py-3.5 outline outline-1 outline-n-container"
  >
    <div class="flex flex-wrap items-center justify-between gap-3">
      <div class="flex min-w-0 flex-1 items-start gap-3">
        <div
          class="mt-0.5 flex size-8 shrink-0 items-center justify-center rounded-lg border border-n-blue-4 bg-n-blue-3 text-n-blue-11 dark:border-n-blue-6 dark:bg-n-blue-4/30"
        >
          <span class="i-lucide-megaphone size-4" aria-hidden="true" />
        </div>
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-2">
            <h3 class="text-sm font-medium text-n-slate-12">
              {{ $t('LABEL_MGMT.META_ADS.TITLE') }}
            </h3>
            <span
              data-testid="meta-ads-system-pill-preview"
              class="inline-flex h-5 items-center gap-1 rounded-full border border-n-blue-4 bg-n-blue-3 px-2 text-xs font-medium text-n-blue-11 dark:border-n-blue-6 dark:bg-n-blue-4/30"
            >
              <span class="i-lucide-megaphone size-3" aria-hidden="true" />
              <span>{{ systemTagTitle }}</span>
            </span>
          </div>
          <p class="mt-0.5 text-xs text-n-slate-11">
            {{ $t('LABEL_MGMT.META_ADS.DESCRIPTION') }}
          </p>
        </div>
      </div>

      <div class="flex shrink-0 items-center gap-3">
        <button
          type="button"
          data-testid="meta-ads-rules-expand-btn"
          class="inline-flex h-8 items-center gap-1.5 rounded-lg px-2.5 text-xs font-medium text-n-slate-11 transition-colors hover:bg-n-alpha-2 hover:text-n-slate-12"
          @click="showRules = !showRules"
        >
          <span>
            {{
              $t('LABEL_MGMT.META_ADS.RULES_BUTTON', {
                count: rulesCount,
              })
            }}
          </span>
          <span
            class="i-lucide-chevron-down size-3.5 transition-transform duration-150"
            :class="showRules ? 'rotate-180' : ''"
            aria-hidden="true"
          />
        </button>

        <Switch
          data-testid="meta-ads-autotag-toggle"
          :model-value="autoTagEnabled"
          :disabled="!isAdmin || isLoading || hasLoadError || isSaving"
          @change="handleToggleAutoTag"
        />
      </div>
    </div>

    <div
      v-if="showRules"
      data-testid="meta-ads-source-rules"
      class="mt-3.5 border-t border-n-weak pt-3.5"
    >
      <p class="text-xs text-n-slate-11">
        {{ $t('LABEL_MGMT.META_ADS.RULES_HINT') }}
      </p>

      <div v-if="sourceRules.length" class="mt-2.5 flex flex-col gap-1.5">
        <div
          v-for="rule in sourceRules"
          :key="rule.source_id"
          data-testid="meta-ads-rule-row"
          class="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-n-alpha-1 px-3 py-2 outline outline-1 outline-n-weak"
        >
          <div class="flex min-w-0 flex-wrap items-center gap-2">
            <code
              class="rounded bg-n-alpha-2 px-1.5 py-0.5 font-mono text-xs text-n-slate-12 tabular-nums"
            >
              {{ rule.source_id }}
            </code>
            <span
              v-if="recentSourcesById.get(rule.source_id)?.headline"
              class="truncate text-xs text-n-slate-11"
            >
              {{ recentSourcesById.get(rule.source_id).headline }}
            </span>
            <span
              class="i-lucide-arrow-right size-3.5 shrink-0 text-n-slate-10"
              aria-hidden="true"
            />
            <div class="flex flex-wrap items-center gap-1.5">
              <span
                v-for="lbl in rule.labels"
                :key="lbl.id"
                class="inline-flex h-6 items-center gap-1.5 rounded-md bg-n-alpha-2 px-2 text-xs font-medium text-n-slate-12"
              >
                <span
                  v-if="labelMarkerType(lbl) === 'emoji'"
                  class="text-xs leading-none"
                >
                  {{ labelMarkerEmoji(lbl) }}
                </span>
                <span
                  v-else
                  class="size-2 rounded-sm"
                  :style="{ backgroundColor: labelMarkerColor(lbl) }"
                />
                <span>{{ labelDisplayTitleWithoutMarker(lbl) }}</span>
                <button
                  v-if="isAdmin && rule.labels.length > 1"
                  type="button"
                  class="ml-0.5 text-n-slate-10 hover:text-n-ruby-11"
                  :disabled="isSaving"
                  @click="handleRemoveRuleLabel(rule.source_id, lbl.id)"
                >
                  <span class="i-lucide-x size-3" aria-hidden="true" />
                </button>
              </span>
            </div>
          </div>

          <Button
            v-if="isAdmin"
            data-testid="meta-ads-rule-remove-btn"
            icon="i-woot-bin"
            slate
            xs
            faded
            class="hover:enabled:text-n-ruby-11"
            :disabled="isSaving"
            @click="handleRemoveRuleLabel(rule.source_id)"
          />
        </div>
      </div>

      <p
        v-else
        data-testid="meta-ads-rules-empty"
        class="mt-2 text-xs text-n-slate-10"
      >
        {{ $t('LABEL_MGMT.META_ADS.RULES_EMPTY') }}
      </p>

      <div
        v-if="isAdmin && recentSources.length"
        class="mt-3 flex flex-wrap items-center gap-1.5"
      >
        <span class="text-xs text-n-slate-11">
          {{ $t('LABEL_MGMT.META_ADS.RECENT_ADS') }}
        </span>
        <button
          v-for="src in recentSources.slice(0, 8)"
          :key="src.source_id"
          type="button"
          data-testid="meta-ads-recent-source-chip"
          class="inline-flex h-6 max-w-xs items-center gap-1.5 rounded-full border border-n-weak bg-n-alpha-1 px-2.5 text-xs text-n-slate-12 transition-colors hover:border-n-blue-6 hover:bg-n-blue-3/40"
          @click="pickRecentSource(src.source_id)"
        >
          <span v-if="src.headline" class="truncate font-medium">
            {{ src.headline }}
          </span>
          <span class="font-mono text-n-slate-11 tabular-nums">
            {{ src.source_id }}
          </span>
          <span class="text-n-slate-10 tabular-nums">
            {{ formatReferralCount(src.referrals_count) }}
          </span>
        </button>
      </div>

      <form
        v-if="isAdmin"
        class="mt-3 flex flex-wrap items-center gap-2"
        @submit.prevent="handleAddRule"
      >
        <input
          v-model="newSourceId"
          type="text"
          data-testid="meta-ads-rule-source-input"
          :placeholder="$t('LABEL_MGMT.META_ADS.SOURCE_ID_PLACEHOLDER')"
          class="h-8 w-56 rounded-lg bg-n-alpha-black2 px-2.5 text-xs text-n-slate-12 placeholder:text-n-slate-10 outline outline-1 outline-n-weak focus:outline-n-brand"
        />
        <select
          v-model="newLabelId"
          data-testid="meta-ads-rule-label-select"
          class="h-8 min-w-[11rem] rounded-lg bg-n-alpha-black2 px-2.5 text-xs text-n-slate-12 outline outline-1 outline-n-weak focus:outline-n-brand"
        >
          <option value="">
            {{ $t('LABEL_MGMT.META_ADS.SELECT_LABEL_PLACEHOLDER') }}
          </option>
          <option v-for="lbl in selectableLabels" :key="lbl.id" :value="lbl.id">
            {{ labelDisplayTitleWithoutMarker(lbl) }}
          </option>
        </select>
        <Button
          type="submit"
          size="sm"
          data-testid="meta-ads-rule-add-btn"
          :label="$t('LABEL_MGMT.META_ADS.ADD_RULE')"
          :disabled="
            !newSourceId.trim() || !newLabelId || hasLoadError || isSaving
          "
          :is-loading="isSaving"
        />
      </form>
    </div>
  </section>
</template>
