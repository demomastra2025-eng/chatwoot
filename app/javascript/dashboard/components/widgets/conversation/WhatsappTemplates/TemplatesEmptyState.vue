<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useMapGetter } from 'dashboard/composables/store';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import { frontendURL } from 'dashboard/helper/URLHelper';
import {
  countApprovedWhatsAppTemplates,
  countWhatsAppTemplatesInReview,
} from 'dashboard/helper/whatsappTemplateLibrary';

// What the template lists show when nothing can be sent yet: a plain sentence,
// how many templates WhatsApp is still reviewing, and a way to the templates
// page for the people who may open it.
const props = defineProps({
  inboxId: {
    type: Number,
    default: undefined,
  },
});

const { t } = useI18n();

const getWhatsAppTemplates = useMapGetter('inboxes/getWhatsAppTemplates');
const getInbox = useMapGetter('inboxes/getInbox');
const currentRole = useMapGetter('getCurrentRole');
const currentAccountId = useMapGetter('getCurrentAccountId');
const isFeatureEnabledonAccount = useMapGetter(
  'accounts/isFeatureEnabledonAccount'
);

const templates = computed(() => getWhatsAppTemplates.value?.(props.inboxId));

const inReviewCount = computed(() =>
  countWhatsAppTemplatesInReview(templates.value)
);

// «Нет одобренных» is true only when WhatsApp approved nothing. Approved
// templates that a conversation cannot send (hidden by an admin, the survey
// template, an unsupported format) get the plain «нет шаблонов для отправки».
const headline = computed(() =>
  countApprovedWhatsAppTemplates(templates.value)
    ? t('WHATSAPP_TEMPLATES.PICKER.NO_TEMPLATES_TO_SEND')
    : t('WHATSAPP_TEMPLATES.PICKER.NO_APPROVED_TEMPLATES')
);

// The templates page exists only for WhatsApp Cloud inboxes, and the inbox
// settings are for administrators (the same rule as the settings route).
const templatesSettingsUrl = computed(() => {
  const inbox = getInbox.value?.(props.inboxId) || {};
  const isCloudInbox =
    inbox.channel_type === INBOX_TYPES.WHATSAPP &&
    inbox.provider === 'whatsapp_cloud';
  const accountId = currentAccountId.value;
  if (!isCloudInbox || !accountId || currentRole.value !== 'administrator') {
    return '';
  }
  if (
    !isFeatureEnabledonAccount.value?.(
      accountId,
      FEATURE_FLAGS.INBOX_MANAGEMENT
    )
  ) {
    return '';
  }

  return frontendURL(
    `accounts/${accountId}/settings/inboxes/${props.inboxId}/whatsapp-templates`
  );
});
</script>

<template>
  <div class="flex flex-col gap-2" data-test-id="whatsapp-templates-empty">
    <p class="mb-0 text-sm text-n-slate-11">
      {{ headline }}
      <template v-if="inReviewCount">
        {{
          t('WHATSAPP_TEMPLATES.PICKER.TEMPLATES_IN_REVIEW', {
            count: inReviewCount,
          })
        }}
      </template>
    </p>
    <a
      v-if="templatesSettingsUrl"
      :href="templatesSettingsUrl"
      target="_blank"
      rel="noopener noreferrer"
      class="text-sm font-medium text-n-brand hover:underline"
      data-test-id="whatsapp-templates-settings-link"
    >
      {{ t('WHATSAPP_TEMPLATES.PICKER.OPEN_TEMPLATES_SETTINGS') }}
    </a>
  </div>
</template>
