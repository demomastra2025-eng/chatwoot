<script setup>
import { computed, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';

import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import SettingsFieldSection from 'dashboard/components-next/Settings/SettingsFieldSection.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import { getIntlLocale, getLanguageName } from '../helpers/intlLocale';

const props = defineProps({
  embedded: {
    type: Boolean,
    default: false,
  },
  inbox: {
    type: Object,
    required: true,
  },
});

const { t, locale } = useI18n();
const store = useStore();

const uiLocale = computed(() => locale?.value || 'en');

const FIELD_LABEL_MAX_LENGTH = 20;
const CTA_LABEL_MAX_LENGTH = 35;

const searchQuery = ref('');
const isSettingUpEncryption = ref(false);
const isRotatingKeys = ref(false);
const isSyncingFlows = ref(false);
const isProvisioningBooking = ref(false);
const isProvisioningIntake = ref(false);
const publishingFlowIds = ref(new Set());
const isRemovingFlow = ref(false);
const flowPendingRemove = ref(null);
const removeDialogRef = ref(null);

const bookingForm = reactive({
  locale: 'ru',
  clinicPreset: '',
  name: '',
  specialistLabel: '',
  serviceLabel: '',
  confirmCta: '',
  publish: true,
});

const clinicPresetOptions = [
  { value: '', label: 'Авто по клинике (АлияЦентр / Intermedical / Универсальный)' },
  { value: 'aliya_center', label: 'МО «Әлия» (гинекология, беременность, УЗИ, КДЛ Олимп)' },
  { value: 'intermedical', label: 'Intermedical (взрослый/детский, УЗИ/МРТ/КТ/ФГДС, 075/у, ОСМС)' },
  { value: 'default', label: 'Универсальный профиль' },
];

const flowsConfig = computed(
  () =>
    props.inbox?.provider_config?.whatsapp_flows ||
    props.inbox?.whatsapp_flows ||
    {}
);

const flows = computed(() =>
  Array.isArray(flowsConfig.value.flows) ? flowsConfig.value.flows : []
);

const bookingFlowId = computed(() =>
  String(flowsConfig.value.booking_flow_id || '')
);

const encryptionStatus = computed(() =>
  String(flowsConfig.value.encryption_status || 'not_configured').toLowerCase()
);

const isEncryptionConfigured = computed(
  () => encryptionStatus.value === 'configured'
);

const encryptionBadgeClass = computed(() => {
  if (encryptionStatus.value === 'configured') {
    return 'bg-n-teal-9/10 text-n-teal-11';
  }
  if (encryptionStatus.value === 'error') {
    return 'bg-n-ruby-9/10 text-n-ruby-11';
  }
  return 'bg-n-amber-9/10 text-n-amber-11';
});

const encryptionStatusLabel = computed(() => {
  if (encryptionStatus.value === 'configured') {
    return t('INBOX_MGMT.WHATSAPP_FLOWS.ENCRYPTION.STATUS_CONFIGURED');
  }
  if (encryptionStatus.value === 'pending_upload') {
    return t('INBOX_MGMT.WHATSAPP_FLOWS.ENCRYPTION.STATUS_PENDING');
  }
  if (encryptionStatus.value === 'error') {
    return t('INBOX_MGMT.WHATSAPP_FLOWS.ENCRYPTION.STATUS_ERROR');
  }
  return t('INBOX_MGMT.WHATSAPP_FLOWS.ENCRYPTION.STATUS_NOT_CONFIGURED');
});

const formatTimestamp = rawValue => {
  if (!rawValue) return '';
  const parsed = new Date(rawValue);
  if (Number.isNaN(parsed.getTime())) return '';

  return new Intl.DateTimeFormat(getIntlLocale(uiLocale.value), {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(parsed);
};

const lastSyncedText = computed(() => {
  const formatted = formatTimestamp(flowsConfig.value.flows_synced_at);
  return formatted || t('INBOX_MGMT.WHATSAPP_FLOWS.NOT_SYNCED_YET');
});

const publicKeyUploadedText = computed(() =>
  formatTimestamp(flowsConfig.value.public_key_uploaded_at)
);

const bookingLocaleOptions = computed(() =>
  ['ru', 'kk', 'en'].map(code => ({
    value: code,
    label: `${getLanguageName(code, uiLocale.value)} (${code})`,
  }))
);

const getFlowStatusLabel = status => {
  const normalized = String(status || 'DRAFT').toUpperCase();
  switch (normalized) {
    case 'PUBLISHED':
      return t('INBOX_MGMT.WHATSAPP_FLOWS.STATUSES.PUBLISHED');
    case 'DRAFT':
      return t('INBOX_MGMT.WHATSAPP_FLOWS.STATUSES.DRAFT');
    case 'DEPRECATED':
      return t('INBOX_MGMT.WHATSAPP_FLOWS.STATUSES.DEPRECATED');
    case 'BLOCKED':
      return t('INBOX_MGMT.WHATSAPP_FLOWS.STATUSES.BLOCKED');
    case 'THROTTLED':
      return t('INBOX_MGMT.WHATSAPP_FLOWS.STATUSES.THROTTLED');
    default:
      return normalized;
  }
};

const getFlowStatusClass = status => {
  const normalized = String(status || 'DRAFT').toUpperCase();
  if (normalized === 'PUBLISHED') {
    return 'bg-n-teal-9/10 text-n-teal-11';
  }
  if (['DEPRECATED', 'BLOCKED', 'THROTTLED'].includes(normalized)) {
    return 'bg-n-ruby-9/10 text-n-ruby-11';
  }
  return 'bg-n-amber-9/10 text-n-amber-11';
};

const isBookingFlow = flow =>
  (bookingFlowId.value && String(flow?.id) === bookingFlowId.value) ||
  flow?.kind === 'booking';

const isDraftFlow = flow =>
  String(flow?.status || 'DRAFT').toUpperCase() === 'DRAFT';

const canRemoveFlow = flow => {
  const normalized = String(flow?.status || 'DRAFT').toUpperCase();
  return normalized !== 'DEPRECATED';
};

const canRotateEncryptionKeys = computed(
  () => encryptionStatus.value !== 'not_configured'
);

const requiresDeprecateOnRemove = flow => !isDraftFlow(flow);

const filteredFlows = computed(() => {
  const query = searchQuery.value.trim().toLowerCase();
  if (!query) return flows.value;

  return flows.value.filter(flow => {
    const haystack = [
      flow.name,
      flow.id,
      flow.status,
      getFlowStatusLabel(flow.status),
      ...(Array.isArray(flow.categories) ? flow.categories : []),
    ]
      .filter(Boolean)
      .join(' ')
      .toLowerCase();
    return haystack.includes(query);
  });
});

const getValidationErrorMessages = flow => {
  const messages = [];
  if (flow?.last_publish_error) {
    messages.push(String(flow.last_publish_error));
  }
  if (Array.isArray(flow?.validation_errors)) {
    flow.validation_errors.forEach(err => {
      const msg =
        typeof err === 'string'
          ? err
          : err?.message || err?.error || err?.error_type || '';
      if (msg) messages.push(msg);
    });
  }
  return messages;
};

const setupEncryption = async (rotateKeys = false) => {
  try {
    if (rotateKeys) {
      isRotatingKeys.value = true;
    } else {
      isSettingUpEncryption.value = true;
    }
    await store.dispatch('inboxes/setupWhatsAppFlowsEncryption', {
      inboxId: props.inbox.id,
      rotateKeys: Boolean(rotateKeys),
    });
    useAlert(t('INBOX_MGMT.WHATSAPP_FLOWS.ENCRYPTION.SETUP_SUCCESS'));
  } catch (error) {
    useAlert(error.message);
  } finally {
    isSettingUpEncryption.value = false;
    isRotatingKeys.value = false;
  }
};

const syncFlows = async () => {
  try {
    isSyncingFlows.value = true;
    await store.dispatch('inboxes/syncWhatsAppFlows', props.inbox.id);
    useAlert(t('INBOX_MGMT.WHATSAPP_FLOWS.SYNC_SUCCESS'));
  } catch (error) {
    useAlert(error.message);
  } finally {
    isSyncingFlows.value = false;
  }
};

const validateBookingFormLabels = () => {
  if (
    bookingForm.specialistLabel.trim().length > FIELD_LABEL_MAX_LENGTH ||
    bookingForm.serviceLabel.trim().length > FIELD_LABEL_MAX_LENGTH
  ) {
    return t('INBOX_MGMT.WHATSAPP_FLOWS.BOOKING.FIELD_LABEL_MAX_LENGTH');
  }
  if (bookingForm.confirmCta.trim().length > CTA_LABEL_MAX_LENGTH) {
    return t('INBOX_MGMT.WHATSAPP_FLOWS.BOOKING.CTA_MAX_LENGTH');
  }
  return '';
};

const notifyProvisionOutcome = (updatedInbox, requestedPublish) => {
  const latestCfg = updatedInbox?.provider_config?.whatsapp_flows;
  const latestFlows = Array.isArray(latestCfg?.flows) ? latestCfg.flows : [];
  const createdFlow =
    latestFlows.find(
      item => String(item?.id) === String(latestCfg?.booking_flow_id || '')
    ) || latestFlows[0];

  if (
    requestedPublish &&
    createdFlow &&
    String(createdFlow.status || '').toUpperCase() !== 'PUBLISHED'
  ) {
    const reason = getValidationErrorMessages(createdFlow)[0];
    useAlert(
      reason
        ? t('INBOX_MGMT.WHATSAPP_FLOWS.BOOKING.PROVISION_DRAFT_WARNING', {
            reason,
          })
        : t('INBOX_MGMT.WHATSAPP_FLOWS.BOOKING.PROVISION_DRAFT_FALLBACK')
    );
    return;
  }

  useAlert(t('INBOX_MGMT.WHATSAPP_FLOWS.BOOKING.PROVISION_SUCCESS'));
};

const provisionBookingFlow = async () => {
  const labelError = validateBookingFormLabels();
  if (labelError) {
    useAlert(labelError);
    return;
  }

  try {
    isProvisioningBooking.value = true;
    const payload = {
      locale: bookingForm.locale || 'ru',
      publish: Boolean(bookingForm.publish),
    };
    if (bookingForm.name.trim()) payload.name = bookingForm.name.trim();
    if (bookingForm.specialistLabel.trim()) {
      payload.specialist_label = bookingForm.specialistLabel.trim();
    }
    if (bookingForm.serviceLabel.trim()) {
      payload.service_label = bookingForm.serviceLabel.trim();
    }
    if (bookingForm.confirmCta.trim()) {
      payload.confirm_cta = bookingForm.confirmCta.trim();
    }
    if (bookingForm.clinicPreset) {
      payload.clinic_preset = bookingForm.clinicPreset;
    }

    const updatedInbox = await store.dispatch(
      'inboxes/provisionWhatsAppBookingFlow',
      {
        inboxId: props.inbox.id,
        whatsappFlow: payload,
      }
    );
    notifyProvisionOutcome(updatedInbox, payload.publish);
  } catch (error) {
    useAlert(error.message);
  } finally {
    isProvisioningBooking.value = false;
  }
};

const provisionIntakeFlow = async () => {
  try {
    isProvisioningIntake.value = true;
    const payload = {
      flow_type: 'clinic_intake',
      locale: bookingForm.locale || 'ru',
      publish: Boolean(bookingForm.publish),
    };
    if (bookingForm.clinicPreset) {
      payload.clinic_preset = bookingForm.clinicPreset;
    }
    const updatedInbox = await store.dispatch(
      'inboxes/provisionWhatsAppBookingFlow',
      {
        inboxId: props.inbox.id,
        whatsappFlow: payload,
      }
    );
    notifyProvisionOutcome(updatedInbox, payload.publish);
  } catch (error) {
    useAlert(error.message);
  } finally {
    isProvisioningIntake.value = false;
  }
};

const publishFlow = async flow => {
  const flowId = String(flow?.id || '');
  if (!flowId || publishingFlowIds.value.has(flowId)) return;

  publishingFlowIds.value.add(flowId);
  try {
    await store.dispatch('inboxes/publishWhatsAppFlow', {
      inboxId: props.inbox.id,
      flowId,
    });
    useAlert(t('INBOX_MGMT.WHATSAPP_FLOWS.PUBLISH_SUCCESS'));
  } catch (error) {
    useAlert(error.message);
  } finally {
    publishingFlowIds.value.delete(flowId);
  }
};

const openRemoveDialog = flow => {
  flowPendingRemove.value = flow;
  removeDialogRef.value?.open();
};

const confirmRemoveFlow = async () => {
  if (!flowPendingRemove.value?.id) return;

  const shouldDeprecate = requiresDeprecateOnRemove(flowPendingRemove.value);
  try {
    isRemovingFlow.value = true;
    await store.dispatch('inboxes/deleteWhatsAppFlow', {
      inboxId: props.inbox.id,
      flowId: String(flowPendingRemove.value.id),
    });
    useAlert(
      shouldDeprecate
        ? t('INBOX_MGMT.WHATSAPP_FLOWS.DEPRECATE_SUCCESS')
        : t('INBOX_MGMT.WHATSAPP_FLOWS.DELETE_SUCCESS')
    );
    removeDialogRef.value?.close();
    flowPendingRemove.value = null;
  } catch (error) {
    useAlert(error.message);
  } finally {
    isRemovingFlow.value = false;
  }
};

const sectionComponent = computed(() =>
  props.embedded ? 'div' : SettingsFieldSection
);
const containerClass = computed(() =>
  props.embedded ? 'space-y-4' : 'mx-6 max-w-7xl space-y-4'
);
</script>

<template>
  <div :class="containerClass">
    <component
      :is="sectionComponent"
      v-bind="
        embedded
          ? {}
          : {
              label: t('INBOX_MGMT.WHATSAPP_FLOWS.PAGE_TITLE'),
              helpText: t('INBOX_MGMT.WHATSAPP_FLOWS.PAGE_DESCRIPTION'),
            }
      "
    >
      <div class="space-y-4">
        <div
          class="flex flex-col gap-3 rounded-xl bg-n-solid-2 p-4 outline outline-1 -outline-offset-1 outline-n-weak sm:flex-row sm:items-center sm:justify-between"
          data-test="whatsapp-flows-encryption-card"
        >
          <div class="min-w-0 space-y-1">
            <div class="flex flex-wrap items-center gap-2">
              <p class="mb-0 text-sm font-medium text-n-slate-12">
                {{ t('INBOX_MGMT.WHATSAPP_FLOWS.ENCRYPTION.TITLE') }}
              </p>
              <span
                class="rounded-full px-2 py-0.5 text-xs font-medium"
                :class="encryptionBadgeClass"
                data-test="encryption-status-badge"
              >
                {{ encryptionStatusLabel }}
              </span>
            </div>
            <p class="mb-0 text-xs text-n-slate-11">
              {{ t('INBOX_MGMT.WHATSAPP_FLOWS.ENCRYPTION.DESCRIPTION') }}
            </p>
            <p
              v-if="publicKeyUploadedText"
              class="mb-0 text-xs text-n-slate-10"
            >
              {{
                t('INBOX_MGMT.WHATSAPP_FLOWS.ENCRYPTION.UPLOADED_AT', {
                  timestamp: publicKeyUploadedText,
                })
              }}
            </p>
          </div>
          <div class="flex shrink-0 flex-wrap items-center gap-2">
            <Button
              v-if="canRotateEncryptionKeys"
              variant="ghost"
              color="slate"
              size="sm"
              icon="i-lucide-key-round"
              data-test="rotate-encryption-keys-button"
              :label="t('INBOX_MGMT.WHATSAPP_FLOWS.ENCRYPTION.ROTATE_BUTTON')"
              :is-loading="isRotatingKeys"
              @click="setupEncryption(true)"
            />
            <Button
              variant="outline"
              color="slate"
              size="sm"
              icon="i-lucide-shield-check"
              data-test="setup-encryption-button"
              :label="
                isEncryptionConfigured
                  ? t('INBOX_MGMT.WHATSAPP_FLOWS.ENCRYPTION.REUPLOAD_BUTTON')
                  : t('INBOX_MGMT.WHATSAPP_FLOWS.ENCRYPTION.SETUP_BUTTON')
              "
              :is-loading="isSettingUpEncryption"
              @click="setupEncryption(false)"
            />
          </div>
        </div>

        <div
          class="space-y-4 rounded-xl bg-n-solid-2 p-4 outline outline-1 -outline-offset-1 outline-n-weak"
          data-test="whatsapp-flows-booking-card"
        >
          <div
            class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"
          >
            <div class="space-y-1">
              <p class="mb-0 text-sm font-medium text-n-slate-12">
                {{ t('INBOX_MGMT.WHATSAPP_FLOWS.BOOKING.TITLE') }}
              </p>
              <p class="mb-0 text-xs text-n-slate-11">
                {{ t('INBOX_MGMT.WHATSAPP_FLOWS.BOOKING.DESCRIPTION') }}
              </p>
            </div>
            <div class="flex flex-wrap items-center gap-2">
              <Button
                size="sm"
                variant="outline"
                color="slate"
                icon="i-lucide-file-check-2"
                data-test="provision-intake-flow-button"
                label="Создать Flow анализов и справок"
                :is-loading="isProvisioningIntake"
                @click="provisionIntakeFlow"
              />
              <Button
                size="sm"
                icon="i-lucide-sparkles"
                data-test="provision-booking-flow-button"
                :label="t('INBOX_MGMT.WHATSAPP_FLOWS.BOOKING.PROVISION_BUTTON')"
                :is-loading="isProvisioningBooking"
                @click="provisionBookingFlow"
              />
            </div>
          </div>

          <div class="grid grid-cols-1 gap-3 md:grid-cols-4">
            <div class="flex flex-col gap-1">
              <label class="mb-0.5 text-xs font-medium text-n-slate-12">
                Профиль процессов клиники
              </label>
              <ComboBox
                v-model="bookingForm.clinicPreset"
                :options="clinicPresetOptions"
                input-like
              />
            </div>
            <div class="flex flex-col gap-1">
              <label class="mb-0.5 text-xs font-medium text-n-slate-12">
                {{ t('INBOX_MGMT.WHATSAPP_FLOWS.BOOKING.LOCALE_LABEL') }}
              </label>
              <ComboBox
                v-model="bookingForm.locale"
                :options="bookingLocaleOptions"
                input-like
              />
            </div>
            <Input
              v-model="bookingForm.name"
              :label="t('INBOX_MGMT.WHATSAPP_FLOWS.BOOKING.NAME_LABEL')"
              :placeholder="
                t('INBOX_MGMT.WHATSAPP_FLOWS.BOOKING.NAME_PLACEHOLDER')
              "
            />
            <Input
              v-model="bookingForm.confirmCta"
              :label="t('INBOX_MGMT.WHATSAPP_FLOWS.BOOKING.CTA_LABEL')"
              :placeholder="
                t('INBOX_MGMT.WHATSAPP_FLOWS.BOOKING.CTA_PLACEHOLDER')
              "
            />
          </div>

          <div class="grid grid-cols-1 gap-3 md:grid-cols-3">
            <Input
              v-model="bookingForm.specialistLabel"
              :label="t('INBOX_MGMT.WHATSAPP_FLOWS.BOOKING.SPECIALIST_LABEL')"
              :placeholder="
                t('INBOX_MGMT.WHATSAPP_FLOWS.BOOKING.SPECIALIST_PLACEHOLDER')
              "
            />
            <Input
              v-model="bookingForm.serviceLabel"
              :label="t('INBOX_MGMT.WHATSAPP_FLOWS.BOOKING.SERVICE_LABEL')"
              :placeholder="
                t('INBOX_MGMT.WHATSAPP_FLOWS.BOOKING.SERVICE_PLACEHOLDER')
              "
            />
            <label
              class="flex cursor-pointer items-center gap-2 self-end pb-2 text-xs text-n-slate-12"
            >
              <Switch
                v-model="bookingForm.publish"
                :aria-label="
                  t('INBOX_MGMT.WHATSAPP_FLOWS.BOOKING.PUBLISH_LABEL')
                "
              />
              <span>
                {{ t('INBOX_MGMT.WHATSAPP_FLOWS.BOOKING.PUBLISH_LABEL') }}
              </span>
            </label>
          </div>
        </div>

        <div
          class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between"
          data-test="whatsapp-flows-toolbar"
        >
          <div
            class="flex min-w-0 flex-1 flex-wrap items-center gap-x-3 gap-y-1"
          >
            <div class="w-full max-w-md shrink-0">
              <Input
                v-model="searchQuery"
                size="sm"
                type="search"
                :placeholder="t('INBOX_MGMT.WHATSAPP_FLOWS.SEARCH_PLACEHOLDER')"
              />
            </div>
            <span class="min-w-0 text-xs text-n-slate-10">
              {{
                t('INBOX_MGMT.WHATSAPP_FLOWS.LAST_SYNC', {
                  timestamp: lastSyncedText,
                })
              }}
            </span>
          </div>
          <div class="flex shrink-0 flex-wrap items-center gap-2">
            <Button
              variant="outline"
              color="slate"
              size="sm"
              icon="i-lucide-refresh-cw"
              data-test="sync-flows-button"
              :label="t('INBOX_MGMT.WHATSAPP_FLOWS.SYNC_BUTTON')"
              :is-loading="isSyncingFlows"
              @click="syncFlows"
            />
          </div>
        </div>

        <div v-if="!flows.length" class="p-6 text-center">
          <p class="mb-1 text-sm font-medium text-n-slate-12">
            {{ t('INBOX_MGMT.WHATSAPP_FLOWS.EMPTY_TITLE') }}
          </p>
          <p class="mb-0 text-sm text-n-slate-11">
            {{ t('INBOX_MGMT.WHATSAPP_FLOWS.EMPTY_DESCRIPTION') }}
          </p>
        </div>

        <div v-else-if="!filteredFlows.length" class="p-6 text-center">
          <p class="mb-1 text-sm font-medium text-n-slate-12">
            {{ t('INBOX_MGMT.WHATSAPP_FLOWS.NO_RESULTS_TITLE') }}
          </p>
          <p class="mb-0 text-sm text-n-slate-11">
            {{ t('INBOX_MGMT.WHATSAPP_FLOWS.NO_RESULTS_DESCRIPTION') }}
          </p>
        </div>

        <div v-else class="grid grid-cols-1 gap-3 xl:grid-cols-2">
          <div
            v-for="flow in filteredFlows"
            :key="flow.id"
            class="space-y-2 rounded-xl bg-n-solid-2 p-4 outline outline-1 -outline-offset-1 outline-n-weak"
            data-test="whatsapp-flow-card"
          >
            <div class="grid grid-cols-[minmax(0,1fr)_auto] items-start gap-3">
              <div class="min-w-0 space-y-1">
                <div class="flex min-w-0 flex-wrap items-center gap-1.5">
                  <p
                    class="mb-0 min-w-0 truncate text-sm font-medium text-n-slate-12"
                  >
                    {{ flow.name }}
                  </p>
                  <span
                    class="rounded-full px-1.5 py-0.5 text-[10px] font-medium"
                    :class="getFlowStatusClass(flow.status)"
                    data-test="flow-status-badge"
                  >
                    {{ getFlowStatusLabel(flow.status) }}
                  </span>
                  <span
                    v-if="isBookingFlow(flow)"
                    class="rounded-full bg-n-brand/10 px-1.5 py-0.5 text-[10px] font-medium text-n-brand"
                    data-test="flow-booking-badge"
                  >
                    {{ t('INBOX_MGMT.WHATSAPP_FLOWS.BOOKING_BADGE') }}
                  </span>
                </div>

                <div
                  class="flex flex-wrap items-center gap-2 text-xs text-n-slate-10"
                >
                  <span>
                    {{
                      t('INBOX_MGMT.WHATSAPP_FLOWS.FLOW_ID_LABEL', {
                        id: flow.id,
                      })
                    }}
                  </span>
                  <span
                    v-for="category in flow.categories || []"
                    :key="`${flow.id}-${category}`"
                    class="rounded-full bg-n-alpha-black2 px-1.5 py-0.5 text-[10px] font-medium text-n-slate-11"
                  >
                    {{ category }}
                  </span>
                </div>

                <ul
                  v-if="getValidationErrorMessages(flow).length"
                  class="mb-0 list-inside list-disc text-xs text-n-ruby-11"
                  data-test="flow-validation-errors"
                >
                  <li
                    v-for="(errMsg, idx) in getValidationErrorMessages(flow)"
                    :key="`${flow.id}-err-${idx}`"
                  >
                    {{ errMsg }}
                  </li>
                </ul>
              </div>

              <div class="flex shrink-0 items-center gap-1.5">
                <Button
                  v-if="isDraftFlow(flow)"
                  variant="outline"
                  color="slate"
                  size="xs"
                  icon="i-lucide-upload-cloud"
                  data-test="publish-flow-button"
                  :label="t('INBOX_MGMT.WHATSAPP_FLOWS.PUBLISH_ACTION')"
                  :is-loading="publishingFlowIds.has(String(flow.id))"
                  @click="publishFlow(flow)"
                />
                <Button
                  v-if="canRemoveFlow(flow)"
                  variant="ghost"
                  color="ruby"
                  size="xs"
                  icon="i-lucide-trash-2"
                  data-test="remove-flow-button"
                  :aria-label="
                    requiresDeprecateOnRemove(flow)
                      ? `${t('INBOX_MGMT.WHATSAPP_FLOWS.DEPRECATE_ACTION')}: ${flow.name}`
                      : `${t('INBOX_MGMT.WHATSAPP_FLOWS.DELETE_ACTION')}: ${flow.name}`
                  "
                  :title="
                    requiresDeprecateOnRemove(flow)
                      ? `${t('INBOX_MGMT.WHATSAPP_FLOWS.DEPRECATE_ACTION')}: ${flow.name}`
                      : `${t('INBOX_MGMT.WHATSAPP_FLOWS.DELETE_ACTION')}: ${flow.name}`
                  "
                  @click="openRemoveDialog(flow)"
                />
              </div>
            </div>
          </div>
        </div>
      </div>
    </component>

    <Dialog
      ref="removeDialogRef"
      type="alert"
      :title="
        requiresDeprecateOnRemove(flowPendingRemove)
          ? t('INBOX_MGMT.WHATSAPP_FLOWS.DEPRECATE_TITLE')
          : t('INBOX_MGMT.WHATSAPP_FLOWS.DELETE_TITLE')
      "
      :description="
        requiresDeprecateOnRemove(flowPendingRemove)
          ? t('INBOX_MGMT.WHATSAPP_FLOWS.DEPRECATE_DESCRIPTION', {
              flowName: flowPendingRemove?.name || '',
            })
          : t('INBOX_MGMT.WHATSAPP_FLOWS.DELETE_DESCRIPTION', {
              flowName: flowPendingRemove?.name || '',
            })
      "
      :confirm-button-label="
        requiresDeprecateOnRemove(flowPendingRemove)
          ? t('INBOX_MGMT.WHATSAPP_FLOWS.DEPRECATE_ACTION')
          : t('INBOX_MGMT.WHATSAPP_FLOWS.DELETE_ACTION')
      "
      :cancel-button-label="t('DIALOG.BUTTONS.CANCEL')"
      :is-loading="isRemovingFlow"
      @confirm="confirmRemoveFlow"
      @close="flowPendingRemove = null"
    />
  </div>
</template>
