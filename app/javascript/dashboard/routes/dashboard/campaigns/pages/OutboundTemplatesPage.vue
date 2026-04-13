<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import { useMapGetter, useStoreGetters } from 'dashboard/composables/store';
import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import OutboundWorkspaceLayout from 'dashboard/components-next/Outbound/OutboundWorkspaceLayout.vue';
import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';
import { INBOX_TYPES, TWILIO_CHANNEL_MEDIUM } from 'dashboard/helper/inbox.js';
import { groupWhatsAppTemplates } from 'dashboard/helper/whatsappTemplateLibrary';
import CannedHome from '../../settings/canned/Index.vue';
import WhatsAppTemplatesPage from '../../settings/inbox/settingsPage/WhatsAppTemplatesPage.vue';

const { t } = useI18n();
const getters = useStoreGetters();
const getOutboundCampaignInboxes = useMapGetter(
  'inboxes/getOutboundCampaignInboxes'
);
const getFilteredWhatsAppTemplates = useMapGetter(
  'inboxes/getFilteredWhatsAppTemplates'
);
const cannedHomeRef = ref(null);
const activeTabId = ref('free_text');
const selectedWhatsAppInboxId = ref(null);

const recordsCount = computed(() => {
  return getters.getSortedCannedResponses.value('asc')?.length || 0;
});
const whatsAppInboxes = computed(() =>
  (getOutboundCampaignInboxes.value || []).filter(
    inbox =>
      inbox.channel_type === INBOX_TYPES.WHATSAPP ||
      (inbox.channel_type === INBOX_TYPES.TWILIO &&
        inbox.medium === TWILIO_CHANNEL_MEDIUM.WHATSAPP)
  )
);
const selectedWhatsAppInbox = computed(() => {
  return (
    whatsAppInboxes.value.find(
      inbox => Number(inbox.id) === Number(selectedWhatsAppInboxId.value)
    ) || null
  );
});
const whatsAppInboxOptions = computed(() =>
  whatsAppInboxes.value.map(inbox => ({
    value: inbox.id,
    label: inbox.name,
  }))
);
const whatsAppTemplateCount = computed(() => {
  if (!selectedWhatsAppInboxId.value) {
    return 0;
  }

  return groupWhatsAppTemplates(
    getFilteredWhatsAppTemplates.value(selectedWhatsAppInboxId.value) || []
  ).length;
});
const tabs = computed(() => [
  {
    id: 'free_text',
    label: t('OUTBOUND_WORKSPACE.TEMPLATES.TABS.FREE_TEXT'),
    count: recordsCount.value,
  },
  {
    id: 'whatsapp',
    label: t('OUTBOUND_WORKSPACE.TEMPLATES.TABS.WHATSAPP'),
    count: whatsAppTemplateCount.value,
  },
]);
const activeTabIndex = computed(() =>
  tabs.value.findIndex(tab => tab.id === activeTabId.value)
);
const activeRecordsCount = computed(() =>
  activeTabId.value === 'free_text'
    ? recordsCount.value
    : whatsAppTemplateCount.value
);

const openCreateDialog = () => {
  cannedHomeRef.value?.openAddPopup();
};

const handleTabChanged = tab => {
  activeTabId.value = tab.id;
};

watch(
  whatsAppInboxes,
  inboxes => {
    if (
      !inboxes.some(
        inbox => Number(inbox.id) === Number(selectedWhatsAppInboxId.value)
      )
    ) {
      selectedWhatsAppInboxId.value = inboxes[0]?.id || null;
    }
  },
  { immediate: true }
);
</script>

<template>
  <OutboundWorkspaceLayout
    :title="$t('OUTBOUND_WORKSPACE.TEMPLATES.TITLE')"
    :description="$t('OUTBOUND_WORKSPACE.TEMPLATES.DESCRIPTION')"
  >
    <template #meta>
      <span>
        {{
          t('OUTBOUND_WORKSPACE.TOUCHES.COUNT', {
            n: activeRecordsCount,
          })
        }}
      </span>
    </template>

    <template #actions>
      <Button
        v-if="activeTabId === 'free_text'"
        :label="$t('CANNED_MGMT.HEADER_BTN_TXT')"
        size="sm"
        @click="openCreateDialog"
      />
    </template>

    <template #tabs>
      <TabBar
        :tabs="tabs"
        :initial-active-tab="activeTabIndex"
        @tab-changed="handleTabChanged"
      />
    </template>

    <div v-if="activeTabId === 'free_text'" class="pt-2">
      <CannedHome ref="cannedHomeRef" embedded />
    </div>

    <div v-else class="grid gap-4 pt-2">
      <div
        v-if="!whatsAppInboxes.length"
        class="rounded-2xl border border-dashed border-n-weak bg-n-surface-1 p-8 text-center"
      >
        <p class="mb-1 text-base font-medium text-n-slate-12">
          {{ $t('OUTBOUND_WORKSPACE.TEMPLATES.WHATSAPP.EMPTY_TITLE') }}
        </p>
        <p class="mb-0 text-sm text-n-slate-11">
          {{ $t('OUTBOUND_WORKSPACE.TEMPLATES.WHATSAPP.EMPTY_DESCRIPTION') }}
        </p>
      </div>

      <template v-else>
        <div class="max-w-md">
          <label
            for="outbound-whatsapp-template-inbox"
            class="mb-1 block text-sm font-medium text-n-slate-12"
          >
            {{ $t('OUTBOUND_WORKSPACE.TEMPLATES.WHATSAPP.INBOX_LABEL') }}
          </label>
          <ComboBox
            id="outbound-whatsapp-template-inbox"
            v-model="selectedWhatsAppInboxId"
            :options="whatsAppInboxOptions"
            :placeholder="
              $t('OUTBOUND_WORKSPACE.TEMPLATES.WHATSAPP.INBOX_PLACEHOLDER')
            "
            class="[&>div>button]:bg-n-alpha-black2 [&>div>button:not(.focused)]:dark:outline-n-weak [&>div>button:not(.focused)]:hover:!outline-n-slate-6"
          />
        </div>

        <WhatsAppTemplatesPage
          v-if="selectedWhatsAppInbox"
          :inbox="selectedWhatsAppInbox"
          embedded
        />
      </template>
    </div>
  </OutboundWorkspaceLayout>
</template>
