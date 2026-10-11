<script setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { onBeforeRouteLeave, onBeforeRouteUpdate, useRoute } from 'vue-router';

import { useAlert } from 'dashboard/composables';
import { useMapGetter } from 'dashboard/composables/store';
import { usePolicy } from 'dashboard/composables/usePolicy';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { useCaptainChannelMatrixStore } from 'dashboard/store/captain/channelMatrix';
import {
  buildChannelMatrixPatch,
  channelsMissingMain,
  isEmptyMatrixPatch,
  matrixErrorsByInbox,
  setDraftAiEnabled,
  setDraftAutoReplyMode,
  setDraftDefaultMain,
  setDraftMain,
  setDraftMembership,
  setDraftScope,
  toMatrixDraft,
} from 'dashboard/helper/captainChannelMatrix';

import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import CaptainPaywall from 'dashboard/components-next/captain/pageComponents/Paywall.vue';
import Banner from 'dashboard/components-next/banner/Banner.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import ChannelMatrixTable from 'dashboard/components-next/captain/channels/ChannelMatrixTable.vue';
import ChannelMatrixCard from 'dashboard/components-next/captain/channels/ChannelMatrixCard.vue';

// «Каналы»: text channels × AI agents. Everything is edited in a local draft
// and saved with one atomic PATCH; a 422 keeps the draft and shows the
// server errors per channel row (and general ones in a banner).

const { t } = useI18n();
const route = useRoute();
const { checkPermissions } = usePolicy();
const matrixStore = useCaptainChannelMatrixStore();
const inboxes = useMapGetter('inboxes/getInboxes');

const baseDraft = ref(toMatrixDraft(null));
const draft = ref(toMatrixDraft(null));
const saveErrors = ref([]);
const isLoading = ref(false);
const hasLoaded = ref(false);

const isAdmin = computed(() => checkPermissions(['administrator']));
const uiFlags = computed(() => matrixStore.getUIFlags);
const isSaving = computed(() => Boolean(uiFlags.value.isSaving));
const hasFetchError = computed(() => Boolean(uiFlags.value.fetchError));

const pendingPatch = computed(() =>
  buildChannelMatrixPatch(baseDraft.value, draft.value)
);
const isDirty = computed(() => !isEmptyMatrixPatch(pendingPatch.value));

const channels = computed(() => draft.value.channels);
const assistants = computed(() => draft.value.assistants);
const missingMainIds = computed(() => channelsMissingMain(draft.value));
const errorGroups = computed(() => matrixErrorsByInbox(saveErrors.value));
// Errors without a channel, and errors for a channel that has no row here,
// go to the banner above the matrix.
const generalErrorMessages = computed(() => {
  const shownIds = new Set(channels.value.map(channel => channel.inbox_id));
  const hiddenRowErrors = Object.values(errorGroups.value.byInbox)
    .flat()
    .filter(error => !shownIds.has(error.inboxId));
  return [...errorGroups.value.general, ...hiddenRowErrors].map(
    error => error.message || t('CAPTAIN.CHANNEL_MATRIX.SAVE_ERROR')
  );
});

const inboxLookup = computed(() =>
  Object.fromEntries((inboxes.value || []).map(inbox => [inbox.id, inbox]))
);

const defaultMainOptions = computed(() =>
  assistants.value
    .filter(assistant => assistant.active)
    .map(assistant => ({
      value: assistant.id,
      label: assistant.name || `#${assistant.id}`,
      thumbnail: { name: assistant.name || '', src: assistant.avatar_url },
    }))
);
const defaultMainValue = computed(
  () => draft.value.default_main_assistant_id || ''
);

const showEmpty = computed(
  () => hasLoaded.value && !hasFetchError.value && !channels.value.length
);

const resetDraft = matrix => {
  baseDraft.value = toMatrixDraft(matrix);
  draft.value = toMatrixDraft(matrix);
  saveErrors.value = [];
};

const loadMatrix = async ({ force = false } = {}) => {
  if (!isAdmin.value) return;

  isLoading.value = true;
  const matrix = await matrixStore.fetch({ force });
  isLoading.value = false;
  hasLoaded.value = true;
  resetDraft(matrix);
};

const clearRowErrors = inboxId => {
  saveErrors.value = saveErrors.value.filter(
    error => Number(error.inbox_id) !== Number(inboxId)
  );
};

const updateDraft = (nextDraft, inboxId = null) => {
  draft.value = nextDraft;
  if (inboxId) clearRowErrors(inboxId);
};

const onToggleAi = (inboxId, enabled) =>
  updateDraft(setDraftAiEnabled(draft.value, inboxId, enabled), inboxId);

const onUpdateMode = (inboxId, mode) =>
  updateDraft(setDraftAutoReplyMode(draft.value, inboxId, mode), inboxId);

const onToggleMember = (assistantId, inboxId, member) =>
  updateDraft(
    setDraftMembership(draft.value, assistantId, inboxId, member),
    inboxId
  );

const onSetMain = (inboxId, assistantId) =>
  updateDraft(setDraftMain(draft.value, inboxId, assistantId), inboxId);

const onSetScope = (assistantId, scope) =>
  updateDraft(setDraftScope(draft.value, assistantId, scope));

const onDefaultMainChange = assistantId =>
  updateDraft(setDraftDefaultMain(draft.value, assistantId || null));

const saveMatrix = async () => {
  if (!isAdmin.value || !isDirty.value || isSaving.value) return;

  const result = await matrixStore.save(pendingPatch.value);
  if (result.ok) {
    resetDraft(result.matrix);
    useAlert(t('CAPTAIN.CHANNEL_MATRIX.SAVED'));
    return;
  }

  // Nothing was saved: keep the draft and show where it went wrong.
  saveErrors.value = result.errors || [];
  useAlert(t('CAPTAIN.CHANNEL_MATRIX.SAVE_ERROR'));
};

const confirmLeave = () =>
  !isDirty.value || window.confirm(t('CAPTAIN.CHANNEL_MATRIX.LEAVE_CONFIRM'));

const handleBeforeUnload = event => {
  if (!isDirty.value) return;
  event.preventDefault();
  event.returnValue = '';
};

const isSameAccount = (to, from) =>
  String(to.params?.accountId) === String(from.params?.accountId);

onBeforeRouteLeave(() => confirmLeave());
onBeforeRouteUpdate((to, from) => isSameAccount(to, from) || confirmLeave());

// A background refresh (e.g. the gallery toggled an agent) replaces the
// view only while there is nothing unsaved.
watch(
  () => matrixStore.getMatrix,
  matrix => {
    if (!hasLoaded.value || isDirty.value || isSaving.value) return;
    resetDraft(matrix);
  }
);

watch(
  () => route.params.accountId,
  (accountId, previousAccountId) => {
    if (accountId && accountId !== previousAccountId) loadMatrix();
  }
);

onMounted(() => {
  window.addEventListener('beforeunload', handleBeforeUnload);
  loadMatrix();
});

onBeforeUnmount(() => {
  window.removeEventListener('beforeunload', handleBeforeUnload);
});
</script>

<template>
  <PageLayout
    :header-title="t('CAPTAIN.CHANNEL_MATRIX.TITLE')"
    :button-label="t('CAPTAIN.CHANNEL_MATRIX.SAVE')"
    button-icon=""
    :button-policy="['administrator']"
    :button-disabled="!isDirty || isSaving"
    :button-loading="isSaving"
    content-width="full"
    :is-fetching="isLoading && !hasLoaded"
    :feature-flag="FEATURE_FLAGS.CAPTAIN"
    :show-pagination-footer="false"
    :show-know-more="false"
    @click="saveMatrix"
  >
    <template #paywall>
      <CaptainPaywall />
    </template>

    <template #body>
      <div class="flex flex-col gap-6 pb-6">
        <p class="mb-0 max-w-3xl text-body-main text-n-slate-11">
          {{ t('CAPTAIN.CHANNEL_MATRIX.DESCRIPTION') }}
        </p>

        <Banner
          v-if="hasFetchError"
          color="ruby"
          data-testid="matrix-load-error"
        >
          {{ t('CAPTAIN.CHANNEL_MATRIX.LOAD_ERROR') }}
        </Banner>

        <Banner
          v-if="generalErrorMessages.length"
          color="ruby"
          data-testid="matrix-general-errors"
        >
          <p
            v-for="(message, index) in generalErrorMessages"
            :key="index"
            class="mb-0"
          >
            {{ message }}
          </p>
        </Banner>

        <section v-if="hasLoaded && !hasFetchError" class="flex flex-col gap-2">
          <label
            for="captain-default-main-agent"
            class="mb-0 text-heading-3 text-n-slate-12"
          >
            {{ t('CAPTAIN.CHANNEL_MATRIX.DEFAULT_MAIN_LABEL') }}
          </label>
          <div
            class="flex flex-col gap-3 rounded-xl bg-n-solid-1 p-4 outline outline-1 -outline-offset-1 outline-n-weak sm:flex-row sm:items-center sm:justify-between"
          >
            <p class="mb-0 text-body-main text-n-slate-11">
              {{ t('CAPTAIN.CHANNEL_MATRIX.DEFAULT_MAIN_HINT') }}
            </p>
            <ComboBox
              id="captain-default-main-agent"
              :model-value="defaultMainValue"
              :options="defaultMainOptions"
              :placeholder="t('CAPTAIN.CHANNEL_MATRIX.DEFAULT_MAIN_NONE')"
              :disabled="isSaving || !defaultMainOptions.length"
              input-like
              class="sm:w-72 sm:shrink-0"
              data-testid="matrix-default-main"
              @update:model-value="onDefaultMainChange"
            />
          </div>
        </section>

        <p
          v-if="showEmpty"
          class="mb-0 text-body-main text-n-slate-11"
          data-testid="matrix-empty"
        >
          {{ t('CAPTAIN.CHANNEL_MATRIX.EMPTY') }}
        </p>

        <template v-else-if="channels.length">
          <p
            v-if="!assistants.length"
            class="mb-0 text-body-main text-n-slate-11"
          >
            {{ t('CAPTAIN.CHANNEL_MATRIX.NO_AGENTS') }}
          </p>

          <ChannelMatrixTable
            class="hidden md:block"
            :channels="channels"
            :assistants="assistants"
            :errors-by-inbox="errorGroups.byInbox"
            :missing-main-ids="missingMainIds"
            :inbox-lookup="inboxLookup"
            :disabled="isSaving"
            @toggle-ai="onToggleAi"
            @update-mode="onUpdateMode"
            @toggle-member="onToggleMember"
            @set-main="onSetMain"
            @set-scope="onSetScope"
          />

          <div class="flex flex-col gap-4 md:hidden" data-testid="matrix-cards">
            <ChannelMatrixCard
              v-for="channel in channels"
              :key="channel.inbox_id"
              :channel="channel"
              :assistants="assistants"
              :errors="errorGroups.byInbox[channel.inbox_id] || []"
              :missing-main="missingMainIds.includes(channel.inbox_id)"
              :icon-inbox="inboxLookup[channel.inbox_id] || {}"
              :disabled="isSaving"
              @toggle-ai="onToggleAi"
              @update-mode="onUpdateMode"
              @toggle-member="onToggleMember"
              @set-main="onSetMain"
            />
          </div>
        </template>

        <p
          class="mb-0 text-body-main text-n-slate-11"
          data-testid="matrix-voice-note"
        >
          {{ t('CAPTAIN.CHANNEL_MATRIX.VOICE_NOTE') }}
        </p>
      </div>
    </template>
  </PageLayout>
</template>
