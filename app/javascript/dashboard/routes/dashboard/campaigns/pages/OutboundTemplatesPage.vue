<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import { usePolicy } from 'dashboard/composables/usePolicy';

import { useMapGetter, useStoreGetters } from 'dashboard/composables/store';
import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import OutboundWorkspaceLayout from 'dashboard/components-next/Outbound/OutboundWorkspaceLayout.vue';
import { INBOX_TYPES, TWILIO_CHANNEL_MEDIUM } from 'dashboard/helper/inbox.js';
import { groupWhatsAppTemplates } from 'dashboard/helper/whatsappTemplateLibrary';
import CannedHome from '../../settings/canned/Index.vue';
import WhatsAppTemplatesPage from '../../settings/inbox/settingsPage/WhatsAppTemplatesPage.vue';

const { t } = useI18n();
const route = useRoute();
const { checkPermissions } = usePolicy();
const getters = useStoreGetters();
const getOutboundCampaignInboxes = useMapGetter(
  'inboxes/getOutboundCampaignInboxes'
);
const getFilteredWhatsAppTemplates = useMapGetter(
  'inboxes/getFilteredWhatsAppTemplates'
);
const cannedHomeRef = ref(null);
const whatsAppTemplatesRef = ref(null);
const activeTabId = computed(() =>
  route.name === 'outbound_whatsapp_templates_index' ? 'whatsapp' : 'free_text'
);
const selectedWhatsAppInboxId = ref(null);
const canManageWhatsAppTemplates = computed(() =>
  checkPermissions(['administrator'])
);

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
const activeRecordsCount = computed(() =>
  activeTabId.value === 'free_text'
    ? recordsCount.value
    : whatsAppTemplateCount.value
);
const pageTitle = computed(() =>
  activeTabId.value === 'whatsapp'
    ? t('OUTBOUND_WORKSPACE.TEMPLATES.WHATSAPP.TITLE')
    : t('OUTBOUND_WORKSPACE.TEMPLATES.FREE_TEXT.TITLE')
);
const pageDescription = computed(() =>
  activeTabId.value === 'whatsapp'
    ? t('OUTBOUND_WORKSPACE.TEMPLATES.WHATSAPP.DESCRIPTION')
    : t('OUTBOUND_WORKSPACE.TEMPLATES.FREE_TEXT.DESCRIPTION')
);

const openCreateDialog = () => {
  cannedHomeRef.value?.openAddPopup();
};

const isSyncingWhatsAppTemplates = computed(
  () => whatsAppTemplatesRef.value?.isSyncingTemplates || false
);
const syncWhatsAppTemplates = () => whatsAppTemplatesRef.value?.syncTemplates();
const openCreateWhatsAppTemplateDialog = () =>
  whatsAppTemplatesRef.value?.openCreateDialog();

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
        <div class="flex flex-col gap-3 md:flex-row md:items-end">
          <div class="w-full max-w-md">
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

          <div
            v-if="selectedWhatsAppInbox && canManageWhatsAppTemplates"
            class="flex gap-2 md:ml-auto"
          >
            <Button
              variant="outline"
              color="slate"
              size="sm"
              icon="i-lucide-refresh-cw"
              :is-loading="isSyncingWhatsAppTemplates"
              :aria-label="
                $t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_TEMPLATES_SYNC_BUTTON')
              "
              :title="
                $t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_TEMPLATES_SYNC_BUTTON')
              "
              @click="syncWhatsAppTemplates"
            />
            <Button
              size="sm"
              icon="i-lucide-plus"
              :label="$t('WHATSAPP_TEMPLATES.MANAGEMENT.CREATE_ACTION')"
              @click="openCreateWhatsAppTemplateDialog"
            />
          </div>
        </div>

        <WhatsAppTemplatesPage
          v-if="selectedWhatsAppInbox"
          ref="whatsAppTemplatesRef"
          :inbox="selectedWhatsAppInbox"
          embedded
        />
      </template>
    </div>
  </OutboundWorkspaceLayout>
</template>
