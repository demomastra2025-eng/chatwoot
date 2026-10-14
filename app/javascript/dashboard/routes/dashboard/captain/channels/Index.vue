<script setup>
import { computed, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { usePolicy } from 'dashboard/composables/usePolicy';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { useCaptainChannelMatrixStore } from 'dashboard/store/captain/channelMatrix';
import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import CaptainPaywall from 'dashboard/components-next/captain/pageComponents/Paywall.vue';
import Banner from 'dashboard/components-next/banner/Banner.vue';

const { t } = useI18n();
const route = useRoute();
const { checkPermissions } = usePolicy();
const matrixStore = useCaptainChannelMatrixStore();
const draft = ref([]);
const loaded = ref(false);
const saving = ref(false);
const errors = ref([]);
const isAdmin = computed(() => checkPermissions(['administrator']));
const matrix = computed(() => matrixStore.getMatrix);
const textChannels = result =>
  (result?.channels || []).filter(
    channel => channel.channel_type !== 'Channel::Voice'
  );
const hasMain = computed(() =>
  Boolean(matrix.value?.default_main_assistant_id)
);
const dirtyRows = computed(() =>
  draft.value.filter(row => {
    const saved = matrix.value?.channels?.find(
      channel => channel.inbox_id === row.inbox_id
    );
    return saved && saved.ai_enabled !== row.ai_enabled;
  })
);

const load = async () => {
  if (!isAdmin.value) return;
  const result = await matrixStore.fetch({ force: true });
  draft.value = textChannels(result).map(channel => ({ ...channel }));
  loaded.value = true;
};

const save = async () => {
  if (!dirtyRows.value.length || saving.value) return;
  saving.value = true;
  errors.value = [];
  const result = await matrixStore.save({
    channels: dirtyRows.value.map(row => ({
      inbox_id: row.inbox_id,
      ai_enabled: row.ai_enabled,
    })),
  });
  saving.value = false;
  if (result.ok) {
    draft.value = textChannels(result.matrix).map(channel => ({
      ...channel,
    }));
    useAlert(t('CAPTAIN.CHANNEL_MATRIX.SAVED'));
  } else {
    errors.value = result.errors || [];
    useAlert(t('CAPTAIN.CHANNEL_MATRIX.SAVE_ERROR'));
  }
};

watch(() => route.params.accountId, load);
onMounted(load);
</script>

<template>
  <PageLayout
    :header-title="t('CAPTAIN.CHANNEL_MATRIX.TITLE')"
    :button-label="t('CAPTAIN.CHANNEL_MATRIX.SAVE')"
    button-icon=""
    :button-policy="['administrator']"
    :button-disabled="!dirtyRows.length || saving"
    :button-loading="saving"
    :is-fetching="!loaded"
    :feature-flag="FEATURE_FLAGS.CAPTAIN"
    :show-pagination-footer="false"
    :show-know-more="false"
    @click="save"
  >
    <template #paywall><CaptainPaywall /></template>
    <template #body>
      <div class="flex flex-col gap-4 pb-6">
        <Banner
          v-if="matrixStore.getUIFlags.fetchError || errors.length"
          color="ruby"
        >
          {{ errors[0]?.message || t('CAPTAIN.CHANNEL_MATRIX.LOAD_ERROR') }}
        </Banner>
        <p v-if="!hasMain" class="text-body-main text-n-slate-11">
          {{ t('CAPTAIN.CHANNEL_MATRIX.NO_AGENTS') }}
        </p>
        <div
          v-for="channel in draft"
          :key="channel.inbox_id"
          class="flex items-center justify-between rounded-xl bg-n-solid-2 p-4 outline outline-1 -outline-offset-1 outline-n-weak"
        >
          <span class="text-body-main text-n-slate-12">{{ channel.name }}</span>
          <label class="flex items-center gap-2 text-body-main text-n-slate-12">
            {{ t('CAPTAIN.CHANNEL_MATRIX.CHANNEL_SWITCH') }}
            <input
              v-model="channel.ai_enabled"
              type="checkbox"
              :disabled="!hasMain || saving"
            />
          </label>
        </div>
        <p
          v-if="loaded && !draft.length"
          class="text-body-main text-n-slate-11"
        >
          {{ t('CAPTAIN.CHANNEL_MATRIX.EMPTY') }}
        </p>
      </div>
    </template>
  </PageLayout>
</template>
