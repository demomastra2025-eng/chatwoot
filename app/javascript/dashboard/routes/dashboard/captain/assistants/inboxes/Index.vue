<script setup>
import { computed, watch, reactive } from 'vue';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { useRoute } from 'vue-router';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';

import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import CardLayout from 'dashboard/components-next/CardLayout.vue';
import SettingsHeader from 'dashboard/components-next/captain/pageComponents/settings/SettingsHeader.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import Policy from 'dashboard/components/policy.vue';
import { INBOX_TYPES, getInboxIconByType } from 'dashboard/helper/inbox';
import InboxPageEmptyState from 'dashboard/components-next/captain/pageComponents/emptyStates/InboxPageEmptyState.vue';

const store = useStore();
const route = useRoute();
const { t } = useI18n();

const assistantId = computed(() => Number(route.params.assistantId));
const assistant = computed(() =>
  store.getters['captainAssistants/getRecord'](assistantId.value)
);
const assistantUiFlags = useMapGetter('captainAssistants/getUIFlags');
const isFetchingAssistant = computed(() => assistantUiFlags.value.fetchingItem);
const inboxUiFlags = useMapGetter('inboxes/getUIFlags');
const isFetching = computed(() => inboxUiFlags.value.isFetching);
const isInternalAssistant = computed(
  () => assistant.value?.usage_mode === 'internal_assistant'
);

const inboxes = useMapGetter('inboxes/getInboxes');
const connectionStateByInboxId = reactive({});
const autoReplyModeByInboxId = reactive({});
const isUpdatingByInboxId = reactive({});
const isUpdatingModeByInboxId = reactive({});

const DEFAULT_AUTO_REPLY_MODE = 'always';
const autoReplyModeOptions = computed(() => [
  {
    value: 'always',
    label: t('CAPTAIN.INBOXES.AUTO_REPLY_MODE.OPTIONS.ALWAYS'),
  },
  {
    value: 'working_hours',
    label: t('CAPTAIN.INBOXES.AUTO_REPLY_MODE.OPTIONS.WORKING_HOURS'),
  },
  {
    value: 'outside_working_hours',
    label: t('CAPTAIN.INBOXES.AUTO_REPLY_MODE.OPTIONS.OUTSIDE_WORKING_HOURS'),
  },
]);

const inboxName = inbox => {
  if (!inbox?.name) {
    return '';
  }

  const isTwilioChannel = inbox.channel_type === INBOX_TYPES.TWILIO;
  const isWhatsAppChannel = inbox.channel_type === INBOX_TYPES.WHATSAPP;
  const isEmailChannel = inbox.channel_type === INBOX_TYPES.EMAIL;

  if (isTwilioChannel || isWhatsAppChannel) {
    const identifier = inbox.messaging_service_sid || inbox.phone_number;
    return identifier ? `${inbox.name} (${identifier})` : inbox.name;
  }

  if (isEmailChannel && inbox.email) {
    return `${inbox.name} (${inbox.email})`;
  }

  return inbox.name;
};

const inboxIcon = inbox => {
  const { medium, channel_type: type } = inbox;
  return getInboxIconByType(type, medium, 'outline');
};

const isConnectedToCurrentAssistant = inbox => {
  return inbox?.captain_assistant?.id === assistantId.value;
};

const autoReplyMode = inbox => {
  return inbox?.captain_auto_reply_mode || DEFAULT_AUTO_REPLY_MODE;
};

const isLockedToAnotherAssistant = inbox => {
  return (
    inbox?.captain_assistant?.id &&
    inbox?.captain_assistant?.id !== assistantId.value
  );
};

const sortedInboxes = computed(() => {
  return [...(inboxes.value || [])].sort((a, b) => {
    const aName = a?.name || '';
    const bName = b?.name || '';
    return aName.localeCompare(bName);
  });
});

watch(
  [sortedInboxes, assistantId],
  ([newInboxes]) => {
    (newInboxes || []).forEach(inbox => {
      if (isUpdatingByInboxId[inbox.id]) {
        return;
      }
      connectionStateByInboxId[inbox.id] = isConnectedToCurrentAssistant(inbox);
      if (!isUpdatingModeByInboxId[inbox.id]) {
        autoReplyModeByInboxId[inbox.id] = autoReplyMode(inbox);
      }
    });
  },
  { immediate: true }
);

watch(
  assistantId,
  currentAssistantId => {
    if (!currentAssistantId) {
      return;
    }

    store.dispatch('inboxes/get');
    store.dispatch('captainAssistants/show', currentAssistantId);
  },
  { immediate: true }
);

const toggleInboxConnection = async (inbox, nextValue) => {
  if (
    !inbox?.id ||
    isLockedToAnotherAssistant(inbox) ||
    isInternalAssistant.value
  ) {
    return;
  }

  isUpdatingByInboxId[inbox.id] = true;

  try {
    if (nextValue) {
      await store.dispatch('captainInboxes/create', {
        assistantId: assistantId.value,
        inboxId: inbox.id,
        autoReplyMode:
          autoReplyModeByInboxId[inbox.id] || DEFAULT_AUTO_REPLY_MODE,
      });
      useAlert(t('CAPTAIN.INBOXES.CREATE.SUCCESS_MESSAGE'));
    } else {
      await store.dispatch('captainInboxes/delete', {
        assistantId: assistantId.value,
        inboxId: inbox.id,
      });
      useAlert(t('CAPTAIN.INBOXES.DELETE.SUCCESS_MESSAGE'));
    }

    await store.dispatch('inboxes/get');
  } catch (error) {
    connectionStateByInboxId[inbox.id] = !nextValue;
    const fallbackErrorMessage = nextValue
      ? t('CAPTAIN.INBOXES.CREATE.ERROR_MESSAGE')
      : t('CAPTAIN.INBOXES.DELETE.ERROR_MESSAGE');
    const errorMessage = error?.message || fallbackErrorMessage;
    useAlert(errorMessage);
  } finally {
    isUpdatingByInboxId[inbox.id] = false;
  }
};

const updateAutoReplyMode = async (inbox, event) => {
  const nextMode = event?.target?.value;
  if (!inbox?.id || !nextMode || !isConnectedToCurrentAssistant(inbox)) {
    return;
  }

  const previousMode = autoReplyModeByInboxId[inbox.id] || autoReplyMode(inbox);
  isUpdatingModeByInboxId[inbox.id] = true;

  try {
    await store.dispatch('captainInboxes/create', {
      assistantId: assistantId.value,
      inboxId: inbox.id,
      autoReplyMode: nextMode,
    });
    useAlert(t('CAPTAIN.INBOXES.AUTO_REPLY_MODE.UPDATE.SUCCESS_MESSAGE'));
    await store.dispatch('inboxes/get');
  } catch (error) {
    autoReplyModeByInboxId[inbox.id] = previousMode;
    useAlert(
      error?.message ||
        t('CAPTAIN.INBOXES.AUTO_REPLY_MODE.UPDATE.ERROR_MESSAGE')
    );
  } finally {
    isUpdatingModeByInboxId[inbox.id] = false;
  }
};

const toggleDisabled = inbox => {
  return isLockedToAnotherAssistant(inbox) || isUpdatingByInboxId[inbox.id];
};

const autoReplyModeDisabled = inbox => {
  return (
    !isConnectedToCurrentAssistant(inbox) ||
    isUpdatingModeByInboxId[inbox.id] ||
    isUpdatingByInboxId[inbox.id]
  );
};
</script>

<template>
  <PageLayout
    :header-title="$t('CAPTAIN.ASSISTANTS.SETTINGS.TABS.CHANNELS.LABEL')"
    :is-fetching="isFetchingAssistant || isFetching"
    :is-empty="!isInternalAssistant && !sortedInboxes.length"
    :show-pagination-footer="false"
    :show-know-more="false"
    :feature-flag="FEATURE_FLAGS.CAPTAIN"
  >
    <template #emptyState>
      <InboxPageEmptyState />
    </template>

    <template #body>
      <div class="flex flex-col gap-4">
        <SettingsHeader
          :heading="t('CAPTAIN.ASSISTANTS.SETTINGS.TABS.CHANNELS.LABEL')"
          :description="
            t('CAPTAIN.ASSISTANTS.SETTINGS.TABS.CHANNELS.DESCRIPTION')
          "
        />

        <div
          v-if="isInternalAssistant"
          class="rounded-2xl border border-dashed border-n-weak bg-n-alpha-1 px-6 py-10 text-center"
        >
          <h3 class="text-base font-medium text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.SETTINGS.CHANNELS.INTERNAL_TITLE') }}
          </h3>
          <p class="mt-2 text-sm text-n-slate-11">
            {{ t('CAPTAIN.ASSISTANTS.SETTINGS.CHANNELS.INTERNAL_DESCRIPTION') }}
          </p>
        </div>

        <CardLayout
          v-for="inbox in isInternalAssistant ? [] : sortedInboxes"
          :key="inbox.id"
        >
          <div class="flex justify-between items-center w-full gap-4">
            <div class="min-w-0">
              <span
                class="text-base text-n-slate-12 line-clamp-1 flex items-center gap-2"
              >
                <span :class="inboxIcon(inbox)" />
                {{ inboxName(inbox) }}
              </span>
              <p
                v-if="isLockedToAnotherAssistant(inbox)"
                class="text-xs text-n-slate-11 mt-1 line-clamp-1"
              >
                {{
                  $t('CAPTAIN.INBOXES.CONNECTED_TO', {
                    assistantName: inbox.captain_assistant?.name,
                  })
                }}
              </p>
            </div>

            <div class="flex items-center gap-3 shrink-0">
              <Policy
                :permissions="['administrator']"
                class="flex items-center gap-6"
              >
                <div
                  v-if="isConnectedToCurrentAssistant(inbox)"
                  class="flex items-center gap-2 min-w-[18rem]"
                >
                  <label
                    class="text-xs font-medium text-n-slate-11 whitespace-nowrap"
                    :for="`captain-auto-reply-mode-${inbox.id}`"
                  >
                    {{ t('CAPTAIN.INBOXES.AUTO_REPLY_MODE.LABEL') }}
                  </label>
                  <Select
                    :id="`captain-auto-reply-mode-${inbox.id}`"
                    v-model="autoReplyModeByInboxId[inbox.id]"
                    :options="autoReplyModeOptions"
                    :disabled="autoReplyModeDisabled(inbox)"
                    class="min-w-[12rem]"
                    @change="event => updateAutoReplyMode(inbox, event)"
                  />
                </div>

                <div class="flex items-center gap-2">
                  <span
                    :id="`captain-channel-toggle-label-${inbox.id}`"
                    class="text-xs font-medium text-n-slate-11 whitespace-nowrap"
                  >
                    {{ t('CAPTAIN.INBOXES.CONNECTION_TOGGLE_LABEL') }}
                  </span>
                  <Switch
                    v-model="connectionStateByInboxId[inbox.id]"
                    :aria-labelledby="`captain-channel-toggle-label-${inbox.id}`"
                    :disabled="toggleDisabled(inbox)"
                    @change="value => toggleInboxConnection(inbox, value)"
                  />
                </div>
              </Policy>
            </div>
          </div>
        </CardLayout>
      </div>
    </template>
  </PageLayout>
</template>
