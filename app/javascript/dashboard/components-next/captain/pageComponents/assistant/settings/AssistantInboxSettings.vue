<script setup>
import { computed, reactive, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useMapGetter, useStore } from 'dashboard/composables/store';

import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import CardLayout from 'dashboard/components-next/CardLayout.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import Policy from 'dashboard/components/policy.vue';
import { INBOX_TYPES, getInboxIconByType } from 'dashboard/helper/inbox';

const props = defineProps({
  assistantId: {
    type: Number,
    required: true,
  },
});

const store = useStore();
const { t } = useI18n();

const inboxUiFlags = useMapGetter('inboxes/getUIFlags');
const isFetching = computed(() => inboxUiFlags.value.isFetching);
const inboxes = useMapGetter('inboxes/getInboxes');

const connectionStateByInboxId = reactive({});
const isUpdatingByInboxId = reactive({});

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
  return inbox?.captain_assistant?.id === props.assistantId;
};

const isLockedToAnotherAssistant = inbox => {
  return (
    inbox?.captain_assistant?.id &&
    inbox?.captain_assistant?.id !== props.assistantId
  );
};

const sortedInboxes = computed(() => {
  return [...(inboxes.value || [])].sort((a, b) => {
    const aName = a?.name || '';
    const bName = b?.name || '';
    return aName.localeCompare(bName);
  });
});

const fetchInboxes = () => {
  store.dispatch('inboxes/get');
};

watch(
  [sortedInboxes, () => props.assistantId],
  ([newInboxes]) => {
    (newInboxes || []).forEach(inbox => {
      if (isUpdatingByInboxId[inbox.id]) {
        return;
      }

      connectionStateByInboxId[inbox.id] = isConnectedToCurrentAssistant(inbox);
    });
  },
  { immediate: true }
);

watch(
  () => props.assistantId,
  () => {
    fetchInboxes();
  },
  { immediate: true }
);

const toggleInboxConnection = async (inbox, nextValue) => {
  if (!inbox?.id || isLockedToAnotherAssistant(inbox)) {
    return;
  }

  isUpdatingByInboxId[inbox.id] = true;

  try {
    if (nextValue) {
      await store.dispatch('captainInboxes/create', {
        assistantId: props.assistantId,
        inboxId: inbox.id,
      });
      useAlert(t('CAPTAIN.INBOXES.CREATE.SUCCESS_MESSAGE'));
    } else {
      await store.dispatch('captainInboxes/delete', {
        assistantId: props.assistantId,
        inboxId: inbox.id,
      });
      useAlert(t('CAPTAIN.INBOXES.DELETE.SUCCESS_MESSAGE'));
    }

    await fetchInboxes();
  } catch (error) {
    connectionStateByInboxId[inbox.id] = !nextValue;
    let errorMessage = error?.message;

    if (!errorMessage) {
      errorMessage = nextValue
        ? t('CAPTAIN.INBOXES.CREATE.ERROR_MESSAGE')
        : t('CAPTAIN.INBOXES.DELETE.ERROR_MESSAGE');
    }

    useAlert(errorMessage);
  } finally {
    isUpdatingByInboxId[inbox.id] = false;
  }
};

const toggleDisabled = inbox => {
  return isLockedToAnotherAssistant(inbox) || isUpdatingByInboxId[inbox.id];
};
</script>

<template>
  <div class="flex flex-col gap-4">
    <div
      v-if="isFetching"
      class="flex min-h-40 items-center justify-center rounded-2xl border border-n-weak bg-n-solid-1"
    >
      <Spinner />
    </div>

    <div
      v-else-if="!sortedInboxes.length"
      class="rounded-2xl border border-dashed border-n-weak bg-n-alpha-1 px-6 py-10 text-center"
    >
      <h3 class="text-base font-medium text-n-slate-12">
        {{ t('CAPTAIN.INBOXES.EMPTY_STATE.TITLE') }}
      </h3>
      <p class="mt-2 text-sm text-n-slate-11">
        {{ t('CAPTAIN.INBOXES.EMPTY_STATE.SUBTITLE') }}
      </p>
    </div>

    <template v-else>
      <CardLayout v-for="inbox in sortedInboxes" :key="inbox.id">
        <div class="flex w-full items-center justify-between gap-4">
          <div class="min-w-0">
            <span
              class="flex items-center gap-2 line-clamp-1 text-base text-n-slate-12"
            >
              <span :class="inboxIcon(inbox)" />
              {{ inboxName(inbox) }}
            </span>
            <p
              v-if="isLockedToAnotherAssistant(inbox)"
              class="mt-1 line-clamp-1 text-xs text-n-slate-11"
            >
              {{
                t('CAPTAIN.INBOXES.CONNECTED_TO', {
                  assistantName: inbox.captain_assistant?.name,
                })
              }}
            </p>
          </div>

          <div class="flex shrink-0 items-center gap-3">
            <Policy :permissions="['administrator']">
              <Switch
                v-model="connectionStateByInboxId[inbox.id]"
                :disabled="toggleDisabled(inbox)"
                @change="value => toggleInboxConnection(inbox, value)"
              />
            </Policy>
          </div>
        </div>
      </CardLayout>
    </template>
  </div>
</template>
