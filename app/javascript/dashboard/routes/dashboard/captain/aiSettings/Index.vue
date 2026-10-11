<script setup>
import {
  computed,
  nextTick,
  onBeforeUnmount,
  onMounted,
  ref,
  watch,
} from 'vue';
import { onBeforeRouteLeave, onBeforeRouteUpdate, useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { usePolicy } from 'dashboard/composables/usePolicy';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { useCaptainAiSettingsStore } from 'dashboard/store/captain/aiSettings';
import {
  buildAiSettingsPatch,
  mapAiSettingsErrors,
  readAiSettingsAvailability,
  toAiSettingsDraft,
  validateAiSettingsDraft,
} from 'dashboard/helper/captainAiSettings';
import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import CaptainPaywall from 'dashboard/components-next/captain/pageComponents/Paywall.vue';
import Banner from 'dashboard/components-next/banner/Banner.vue';
import UnderstandingSection from 'dashboard/components-next/captain/aiSettings/UnderstandingSection.vue';
import HandoffSection from 'dashboard/components-next/captain/aiSettings/HandoffSection.vue';
import KnowledgeSection from 'dashboard/components-next/captain/aiSettings/KnowledgeSection.vue';
import ResponseSpeedSection from 'dashboard/components-next/captain/aiSettings/ResponseSpeedSection.vue';
import SafetySection from 'dashboard/components-next/captain/aiSettings/SafetySection.vue';

// «ИИ-агенты › Настройки»: one settings object for all agents of the
// workspace, edited as a draft and saved with one button in the header.
const { t } = useI18n();
const route = useRoute();
const store = useCaptainAiSettingsStore();
const { shouldShowPaywall } = usePolicy();

const EMPTY_SERVER_ERRORS = Object.freeze({
  fields: {},
  rules: {},
  general: [],
});

const baseDraft = ref(null);
const draft = ref(null);
const availability = ref({ web_access_configured: true });
const showValidation = ref(false);
const serverErrors = ref(EMPTY_SERVER_ERRORS);
const isSaving = ref(false);

const showPaywall = computed(() => shouldShowPaywall(FEATURE_FLAGS.CAPTAIN));
const fetchFailed = computed(() => store.uiFlags.fetchError === true);
const isLoading = computed(
  () => !showPaywall.value && !draft.value && !fetchFailed.value
);

const patch = computed(() =>
  draft.value && baseDraft.value
    ? buildAiSettingsPatch(baseDraft.value, draft.value)
    : {}
);
const isDirty = computed(() => Object.keys(patch.value).length > 0);
const validation = computed(() =>
  draft.value ? validateAiSettingsDraft(draft.value) : null
);

const VALIDATION_MESSAGE_KEYS = {
  handoff_reasons: 'CAPTAIN.ASSISTANTS.OUTCOMES.VALIDATION',
  completion_reasons: 'CAPTAIN.ASSISTANTS.OUTCOMES.VALIDATION',
  handoff_message: 'CAPTAIN.AI_SETTINGS.HANDOFF.TEXT_REQUIRED',
  resolution_message: 'CAPTAIN.AI_SETTINGS.HANDOFF.TEXT_REQUIRED',
  collapse_window: 'CAPTAIN.AI_SETTINGS.SPEED.COLLAPSE_INVALID',
};

// Inline messages by field: live validation after a save attempt wins over
// the last server answer.
const fieldErrors = computed(() => {
  const result = { ...serverErrors.value.fields };
  if (!showValidation.value || !validation.value) return result;
  Object.keys(validation.value.errors).forEach(key => {
    if (VALIDATION_MESSAGE_KEYS[key]) {
      result[key] = t(VALIDATION_MESSAGE_KEYS[key]);
    }
  });
  return result;
});

const applySettings = settings => {
  const options = {
    otherLabel: t('CAPTAIN.ASSISTANTS.OUTCOMES.DEFAULTS.COMMON.OTHER'),
  };
  baseDraft.value = toAiSettingsDraft(settings, options);
  draft.value = toAiSettingsDraft(settings, options);
  availability.value = readAiSettingsAvailability(settings);
  showValidation.value = false;
};

const scrollToHash = async () => {
  const id = String(route.hash || '').replace(/^#/, '');
  if (!id) return;
  await nextTick();
  document.getElementById(id)?.scrollIntoView?.({ block: 'start' });
};

const load = async ({ force = false } = {}) => {
  if (showPaywall.value) return;
  const settings = await store.fetch({ force });
  if (!settings) return;
  applySettings(settings);
  scrollToHash();
};

const resetPage = () => {
  baseDraft.value = null;
  draft.value = null;
  serverErrors.value = EMPTY_SERVER_ERRORS;
  showValidation.value = false;
};

const save = async () => {
  if (!draft.value || isSaving.value) return;
  serverErrors.value = EMPTY_SERVER_ERRORS;
  if (!validation.value.valid) {
    showValidation.value = true;
    useAlert(t('CAPTAIN.AI_SETTINGS.VALIDATION_ERROR'));
    return;
  }
  const body = patch.value;
  if (!Object.keys(body).length) return;

  // Server rule errors point at positions in the list that was sent.
  const sentDraft = JSON.parse(JSON.stringify(draft.value));
  isSaving.value = true;
  try {
    const result = await store.save(body);
    if (result.ok) {
      applySettings(result.settings);
      useAlert(t('CAPTAIN.AI_SETTINGS.SAVED'));
      return;
    }
    serverErrors.value = mapAiSettingsErrors(result.errors, sentDraft);
    useAlert(t('CAPTAIN.AI_SETTINGS.SAVE_ERROR'));
  } finally {
    isSaving.value = false;
  }
};

const confirmDiscard = () =>
  !isDirty.value || window.confirm(t('CAPTAIN.AI_SETTINGS.LEAVE_CONFIRM'));

onBeforeRouteLeave(() => confirmDiscard());
onBeforeRouteUpdate((to, from) =>
  String(to.params?.accountId) === String(from.params?.accountId)
    ? true
    : confirmDiscard()
);

const handleBeforeUnload = e => {
  if (!isDirty.value) return;
  e.preventDefault();
  e.returnValue = '';
};

watch(
  () => route.params?.accountId,
  (accountId, previousAccountId) => {
    if (!previousAccountId || accountId === previousAccountId) return;
    resetPage();
    load();
  }
);
watch(() => route.hash, scrollToHash);

onMounted(() => {
  window.addEventListener('beforeunload', handleBeforeUnload);
});

// Start loading during setup so a stale fetch error of an earlier visit is
// cleared before the first render.
load();

onBeforeUnmount(() => {
  window.removeEventListener('beforeunload', handleBeforeUnload);
});
</script>

<template>
  <PageLayout
    :header-title="t('CAPTAIN.AI_SETTINGS.TITLE')"
    :button-label="t('CAPTAIN.AI_SETTINGS.SAVE')"
    button-icon=""
    :button-disabled="!isDirty || isSaving"
    :button-loading="isSaving"
    :button-policy="['administrator']"
    :feature-flag="FEATURE_FLAGS.CAPTAIN"
    :is-fetching="isLoading"
    :show-know-more="false"
    :show-pagination-footer="false"
    content-width="form"
    @click="save"
  >
    <template #paywall>
      <CaptainPaywall />
    </template>

    <template #body>
      <div
        v-if="!draft && fetchFailed"
        data-testid="ai-settings-load-error"
        class="flex flex-col gap-4 pb-8"
      >
        <Banner
          color="ruby"
          :action-label="t('CAPTAIN.AI_SETTINGS.RETRY')"
          @action="load({ force: true })"
        >
          {{ t('CAPTAIN.AI_SETTINGS.LOAD_ERROR') }}
        </Banner>
      </div>

      <div
        v-else-if="draft"
        data-testid="ai-settings-page"
        class="flex flex-col gap-6 pb-8"
      >
        <p class="mb-0 text-body-main text-n-slate-11">
          {{ t('CAPTAIN.AI_SETTINGS.DESCRIPTION') }}
        </p>

        <Banner
          v-if="serverErrors.general.length"
          color="ruby"
          data-testid="ai-settings-errors"
        >
          <div class="flex flex-col gap-1">
            <span>{{ t('CAPTAIN.AI_SETTINGS.SAVE_ERROR') }}</span>
            <ul class="m-0 flex list-disc flex-col gap-1 ps-4">
              <li v-for="(message, index) in serverErrors.general" :key="index">
                {{ message }}
              </li>
            </ul>
          </div>
        </Banner>

        <UnderstandingSection
          v-model="draft.understanding"
          :availability="availability"
          :errors="fieldErrors"
          :disabled="isSaving"
        />
        <HandoffSection
          v-model="draft.handoff"
          :errors="fieldErrors"
          :show-errors="showValidation"
          :disabled="isSaving"
        />
        <KnowledgeSection
          v-model="draft.faq"
          :errors="fieldErrors"
          :disabled="isSaving"
        />
        <ResponseSpeedSection
          v-model="draft.conversation"
          :errors="fieldErrors"
          :disabled="isSaving"
        />
        <SafetySection
          v-model="draft.safety"
          :errors="fieldErrors"
          :rule-errors="serverErrors.rules"
          :show-errors="showValidation"
          :disabled="isSaving"
        />
      </div>
    </template>
  </PageLayout>
</template>
