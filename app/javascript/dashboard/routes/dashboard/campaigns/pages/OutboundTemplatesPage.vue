<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';

import { useMapGetter, useStoreGetters } from 'dashboard/composables/store';
import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import OutboundWorkspaceLayout from 'dashboard/components-next/Outbound/OutboundWorkspaceLayout.vue';
import { INBOX_TYPES, TWILIO_CHANNEL_MEDIUM } from 'dashboard/helper/inbox.js';
import { groupWhatsAppTemplates } from 'dashboard/helper/whatsappTemplateLibrary';
import CannedHome from '../../settings/canned/Index.vue';
import WhatsAppTemplatesPage from '../../settings/inbox/settingsPage/WhatsAppTemplatesPage.vue';
import WhatsAppFlowsPage from '../../settings/inbox/settingsPage/WhatsAppFlowsPage.vue';

const { t } = useI18n();
const route = useRoute();
const getters = useStoreGetters();
const getOutboundCampaignInboxes = useMapGetter(
  'inboxes/getOutboundCampaignInboxes'
);
const getFilteredWhatsAppTemplates = useMapGetter(
  'inboxes/getFilteredWhatsAppTemplates'
);
const cannedHomeRef = ref(null);
// Quick replies, WhatsApp templates, and WhatsApp Flows are separate entries
// of the settings hub, so the route decides which one this page shows.
const activeTabId = computed(() => {
  if (route.name === 'outbound_whatsapp_templates_index') return 'whatsapp';
  if (route.name === 'outbound_whatsapp_flows_index') return 'whatsapp_flows';
  return 'free_text';
});
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
const whatsAppFlowsCount = computed(() => {
  const flows =
    selectedWhatsAppInbox.value?.provider_config?.whatsapp_flows?.flows ||
    selectedWhatsAppInbox.value?.whatsapp_flows?.flows ||
    [];
  return Array.isArray(flows) ? flows.length : 0;
});

const activeRecordsCount = computed(() => {
  if (activeTabId.value === 'free_text') return recordsCount.value;
  if (activeTabId.value === 'whatsapp_flows') return whatsAppFlowsCount.value;
  return whatsAppTemplateCount.value;
});
const pageTitle = computed(() => {
  if (activeTabId.value === 'whatsapp') {
    return t('OUTBOUND_WORKSPACE.TEMPLATES.WHATSAPP.TITLE');
  }
  if (activeTabId.value === 'whatsapp_flows') {
    return t('OUTBOUND_WORKSPACE.TEMPLATES.WHATSAPP_FLOWS.TITLE');
  }
  return t('OUTBOUND_WORKSPACE.TEMPLATES.FREE_TEXT.TITLE');
});
const pageDescription = computed(() => {
  if (activeTabId.value === 'whatsapp') {
    return t('OUTBOUND_WORKSPACE.TEMPLATES.WHATSAPP.DESCRIPTION');
  }
  if (activeTabId.value === 'whatsapp_flows') {
    return t('OUTBOUND_WORKSPACE.TEMPLATES.WHATSAPP_FLOWS.DESCRIPTION');
  }
  return t('OUTBOUND_WORKSPACE.TEMPLATES.FREE_TEXT.DESCRIPTION');
});

const openCreateDialog = () => {
  cannedHomeRef.value?.openAddPopup();
};

watch(
  whatsAppInboxes,
  inboxes => {
    const queryInboxId = Number(route.query?.inboxId);
    if (
      queryInboxId &&
      inboxes.some(inbox => Number(inbox.id) === queryInboxId)
    ) {
      selectedWhatsAppInboxId.value = queryInboxId;
      return;
    }
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
  <OutboundWorkspaceLayout :title="pageTitle" :description="pageDescription">
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

    <div v-if="activeTabId === 'free_text'" class="pt-2">
      <CannedHome ref="cannedHomeRef" embedded />
    </div>

    <div v-else class="grid gap-4 pt-2">
      <div v-if="!whatsAppInboxes.length" class="py-12 text-center">
        <p class="mb-1 text-base font-medium text-n-slate-12">
          {{
            activeTabId === 'whatsapp_flows'
              ? $t('OUTBOUND_WORKSPACE.TEMPLATES.WHATSAPP_FLOWS.EMPTY_TITLE')
              : $t('OUTBOUND_WORKSPACE.TEMPLATES.WHATSAPP.EMPTY_TITLE')
          }}
        </p>
        <p class="mb-0 text-sm text-n-slate-11">
          {{
            activeTabId === 'whatsapp_flows'
              ? $t(
                  'OUTBOUND_WORKSPACE.TEMPLATES.WHATSAPP_FLOWS.EMPTY_DESCRIPTION'
                )
              : $t('OUTBOUND_WORKSPACE.TEMPLATES.WHATSAPP.EMPTY_DESCRIPTION')
          }}
        </p>
      </div>

      <template v-else>
        <div
          v-if="whatsAppInboxOptions.length > 1"
          class="flex flex-wrap items-center gap-2.5"
        >
          <label
            for="outbound-whatsapp-template-inbox"
            class="text-xs font-medium text-n-slate-11"
          >
            {{ $t('OUTBOUND_WORKSPACE.TEMPLATES.WHATSAPP.INBOX_LABEL') }}:
          </label>
          <div class="w-64">
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
        </div>

        <WhatsAppFlowsPage
          v-if="activeTabId === 'whatsapp_flows' && selectedWhatsAppInbox"
          :inbox="selectedWhatsAppInbox"
          embedded
        />
        <WhatsAppTemplatesPage
          v-else-if="selectedWhatsAppInbox"
          :inbox="selectedWhatsAppInbox"
          embedded
        />
      </template>
    </div>
  </OutboundWorkspaceLayout>
</template>
