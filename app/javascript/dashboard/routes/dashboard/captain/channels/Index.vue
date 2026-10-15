<script setup>
import { computed, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { usePolicy } from 'dashboard/composables/usePolicy';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { useCaptainChannelMatrixStore } from 'dashboard/store/captain/channelMatrix';
import { getInboxIconByType } from 'dashboard/helper/inbox';
import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import CaptainPaywall from 'dashboard/components-next/captain/pageComponents/Paywall.vue';
import Banner from 'dashboard/components-next/banner/Banner.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';

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
const anyChannelEnabled = computed(() =>
  draft.value.some(channel => channel.ai_enabled === true)
);
const dirtyRows = computed(() =>
  draft.value.filter(row => {
    const saved = matrix.value?.channels?.find(
      channel => channel.inbox_id === row.inbox_id
    );
    return saved && saved.ai_enabled !== row.ai_enabled;
  })
);

const channelIcon = channel =>
  getInboxIconByType(channel?.channel_type, channel?.medium, 'fill');

const toggleAllChannels = () => {
  if (!hasMain.value || saving.value || !draft.value.length) return;
  const nextState = !anyChannelEnabled.value;
  draft.value = draft.value.map(channel => ({
    ...channel,
    ai_enabled: nextState,
  }));
};

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
      <div class="flex flex-col gap-4 pb-8">
        <Banner
          v-if="matrixStore.getUIFlags.fetchError || errors.length"
          color="ruby"
        >
          {{ errors[0]?.message || t('CAPTAIN.CHANNEL_MATRIX.LOAD_ERROR') }}
        </Banner>

        <div
          v-if="draft.length"
          class="flex flex-wrap items-center justify-between gap-3"
        >
          <p class="mb-0 text-body-main text-n-slate-11">
            {{ t('CAPTAIN.CHANNEL_MATRIX.DESCRIPTION') }}
          </p>
          <Button
            :label="
              anyChannelEnabled
                ? t('CAPTAIN.CHANNEL_MATRIX.DISABLE_ALL')
                : t('CAPTAIN.CHANNEL_MATRIX.ENABLE_ALL')
            "
            color="slate"
            variant="faded"
            size="sm"
            class="shrink-0"
            :disabled="!hasMain || saving"
            data-testid="channels-toggle-all"
            @click="toggleAllChannels"
          />
        </div>

        <p v-if="!hasMain" class="mb-0 text-body-main text-n-slate-11">
          {{ t('CAPTAIN.CHANNEL_MATRIX.NO_AGENTS') }}
        </p>

        <div
          v-if="draft.length"
          class="flex flex-col divide-y divide-n-weak rounded-xl bg-n-solid-2 outline outline-1 -outline-offset-1 outline-n-weak"
        >
          <div
            v-for="channel in draft"
            :key="channel.inbox_id"
            class="flex items-center justify-between gap-4 px-5 py-4"
            data-testid="channel-row"
          >
            <div class="flex min-w-0 items-center gap-3">
              <span
                class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-n-alpha-2 text-n-slate-12"
                data-testid="channel-icon"
              >
                <Icon
                  :icon="channelIcon(channel)"
                  class="size-5 shrink-0"
                />
              </span>
              <span class="truncate text-heading-3 text-n-slate-12">
                {{ channel.name }}
              </span>
            </div>
            <div class="flex shrink-0 items-center gap-3">
              <span class="text-body-main text-n-slate-11">
                {{ t('CAPTAIN.CHANNEL_MATRIX.CHANNEL_SWITCH') }}
              </span>
              <Switch
                v-model="channel.ai_enabled"
                :disabled="!hasMain || saving"
                :aria-label="
                  t('CAPTAIN.CHANNEL_MATRIX.AI_TOGGLE', {
                    channel: channel.name,
                  })
                "
                data-testid="channel-switch"
              />
            </div>
          </div>
        </div>

        <p
          v-if="loaded && !draft.length"
          class="mb-0 text-body-main text-n-slate-11"
        >
          {{ t('CAPTAIN.CHANNEL_MATRIX.EMPTY') }}
        </p>
      </div>
    </template>
  </PageLayout>
</template>
