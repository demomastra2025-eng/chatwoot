<script setup>
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useStore } from 'vuex';
import { useAlert } from 'dashboard/composables';
import { copyTextToClipboard } from 'shared/helpers/clipboard';
import { useIntegrationHook } from 'dashboard/composables/useIntegrationHook';
import { useBranding } from 'shared/composables/useBranding';
import BaseSettingsHeader from 'dashboard/routes/dashboard/settings/components/BaseSettingsHeader.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';

const props = defineProps({
  integrationId: {
    type: String,
    required: true,
  },
});

defineEmits(['add', 'edit', 'delete']);

const { integration, hasConnectedHooks } = useIntegrationHook(
  props.integrationId
);

const store = useStore();
const route = useRoute();
const { replaceInstallationName } = useBranding();
const { t, locale } = useI18n();

const backButtonUrl = computed(() => ({
  name: 'settings_applications',
  params: { accountId: route.params.accountId },
}));

const connectedHook = computed(() => integration.value?.hooks?.[0]);
const uiFlags = computed(() => store.getters['integrations/getUIFlags']);
const isMedelement = computed(() => props.integrationId === 'medelement');
const isMacrocrm = computed(() => props.integrationId === 'macrocrm');
const medelementMetadata = computed(() => connectedHook.value?.metadata || {});
const macrocrmMetadata = computed(() => connectedHook.value?.metadata || {});
const medelementCatalogFileInput = ref(null);
const medelementCatalogFile = ref(null);
const medelementCatalogMaxBytes = 5 * 1024 * 1024;
const hookSyncStatus = ref({
  run: null,
  phase_statuses: {},
  schedules: [],
  conflicts: [],
  conflict_counts: {},
});
const resolvingConflictId = ref(null);
const conflictFilters = ref({
  status: '',
  conflict_type: '',
  contact: '',
  from: '',
  to: '',
});
const conflictResolutionDialog = ref(null);
const pendingConflictAction = ref(null);
const resolutionNote = ref('');
let hookSyncPollTimer;
let hookSyncPollFailures = 0;
let hookSyncStatusRequestId = 0;

const syncRun = computed(() => hookSyncStatus.value?.run);
const syncSchedules = computed(() => {
  const statusSchedules = hookSyncStatus.value?.schedules || [];
  return statusSchedules.length
    ? statusSchedules
    : medelementMetadata.value.schedules || [];
});
const syncConflicts = computed(() => hookSyncStatus.value?.conflicts || []);
const conflictPagination = computed(
  () => hookSyncStatus.value?.conflict_pagination || { page: 1, total_pages: 1 }
);
const isSyncActive = computed(() =>
  ['queued', 'running', 'retrying'].includes(syncRun.value?.status)
);
const showHookSyncPanel = computed(
  () => isMedelement.value && Boolean(connectedHook.value)
);
const syncPhases = [
  'setup',
  'specialists',
  'services',
  'contacts',
  'receptions',
];
const syncStatusTranslation = {
  queued: 'INTEGRATION_APPS.MEDELEMENT.SYNC_STATUS.QUEUED',
  running: 'INTEGRATION_APPS.MEDELEMENT.SYNC_STATUS.RUNNING',
  retrying: 'INTEGRATION_APPS.MEDELEMENT.SYNC_STATUS.RETRYING',
  succeeded: 'INTEGRATION_APPS.MEDELEMENT.SYNC_STATUS.SUCCEEDED',
  partial: 'INTEGRATION_APPS.MEDELEMENT.SYNC_STATUS.PARTIAL',
  failed: 'INTEGRATION_APPS.MEDELEMENT.SYNC_STATUS.FAILED',
  skipped: 'INTEGRATION_APPS.MEDELEMENT.SYNC_STATUS.SKIPPED',
  pending: 'INTEGRATION_APPS.MEDELEMENT.SYNC_STATUS.PENDING',
};
const syncPhaseTranslation = {
  setup: 'INTEGRATION_APPS.MEDELEMENT.SYNC_PHASE.SETUP',
  specialists: 'INTEGRATION_APPS.MEDELEMENT.SYNC_PHASE.SPECIALISTS',
  services: 'INTEGRATION_APPS.MEDELEMENT.SYNC_PHASE.SERVICES',
  contacts: 'INTEGRATION_APPS.MEDELEMENT.SYNC_PHASE.CONTACTS',
  receptions: 'INTEGRATION_APPS.MEDELEMENT.SYNC_PHASE.RECEPTIONS',
};
const syncScheduleTranslation = {
  realtime: {
    next: 'INTEGRATION_APPS.MEDELEMENT.SCHEDULE.REALTIME_NEXT',
    last: 'INTEGRATION_APPS.MEDELEMENT.SCHEDULE.REALTIME_LAST',
  },
  operational: {
    next: 'INTEGRATION_APPS.MEDELEMENT.SCHEDULE.OPERATIONAL_NEXT',
    last: 'INTEGRATION_APPS.MEDELEMENT.SCHEDULE.OPERATIONAL_LAST',
  },
  catalog: {
    next: 'INTEGRATION_APPS.MEDELEMENT.SCHEDULE.CATALOG_NEXT',
    last: 'INTEGRATION_APPS.MEDELEMENT.SCHEDULE.CATALOG_LAST',
  },
};
const syncConflictTranslation = {
  invalid_specialist:
    'INTEGRATION_APPS.MEDELEMENT.CONFLICT_TYPE.INVALID_SPECIALIST',
  conflicting_cabinet_name:
    'INTEGRATION_APPS.MEDELEMENT.CONFLICT_TYPE.CONFLICTING_CABINET_NAME',
  specialist_not_returned:
    'INTEGRATION_APPS.MEDELEMENT.CONFLICT_TYPE.SPECIALIST_NOT_RETURNED',
  invalid_service: 'INTEGRATION_APPS.MEDELEMENT.CONFLICT_TYPE.INVALID_SERVICE',
  invalid_specialist_service:
    'INTEGRATION_APPS.MEDELEMENT.CONFLICT_TYPE.INVALID_SPECIALIST_SERVICE',
  patient_not_found:
    'INTEGRATION_APPS.MEDELEMENT.CONFLICT_TYPE.PATIENT_NOT_FOUND',
  patient_update_rejected:
    'INTEGRATION_APPS.MEDELEMENT.CONFLICT_TYPE.PATIENT_UPDATE_REJECTED',
  phone_owned_by_another_contact:
    'INTEGRATION_APPS.MEDELEMENT.CONFLICT_TYPE.PHONE_OWNED_BY_ANOTHER_CONTACT',
  phone_mismatch: 'INTEGRATION_APPS.MEDELEMENT.CONFLICT_TYPE.PHONE_MISMATCH',
  invalid_reception:
    'INTEGRATION_APPS.MEDELEMENT.CONFLICT_TYPE.INVALID_RECEPTION',
  patient_unresolved:
    'INTEGRATION_APPS.MEDELEMENT.CONFLICT_TYPE.PATIENT_UNRESOLVED',
  appointment_amount_mismatch:
    'INTEGRATION_APPS.MEDELEMENT.CONFLICT_TYPE.APPOINTMENT_AMOUNT_MISMATCH',
  local_payment_preserved:
    'INTEGRATION_APPS.MEDELEMENT.CONFLICT_TYPE.LOCAL_PAYMENT_PRESERVED',
};
const conflictStatusTranslation = {
  open: 'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.STATUS.OPEN',
  ignored: 'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.STATUS.IGNORED',
  resolved: 'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.STATUS.RESOLVED',
};
const conflictFieldTranslation = {
  first_name:
    'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FIELD.FIRST_NAME',
  last_name: 'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FIELD.LAST_NAME',
  middle_name:
    'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FIELD.MIDDLE_NAME',
  phone: 'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FIELD.PHONE',
  iin: 'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FIELD.IIN',
  birth_date:
    'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FIELD.BIRTH_DATE',
  gender: 'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FIELD.GENDER',
  email: 'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FIELD.EMAIL',
  address: 'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FIELD.ADDRESS',
};
const selectedConflictFieldDirections = ref({});
const syncCounterTranslation = {
  configured_fields:
    'INTEGRATION_APPS.MEDELEMENT.SYNC_COUNTER.CONFIGURED_FIELDS',
  imported_count: 'INTEGRATION_APPS.MEDELEMENT.SYNC_COUNTER.IMPORTED_COUNT',
  synced_count: 'INTEGRATION_APPS.MEDELEMENT.SYNC_COUNTER.SYNCED_COUNT',
  linked_count: 'INTEGRATION_APPS.MEDELEMENT.SYNC_COUNTER.LINKED_COUNT',
  skipped_count: 'INTEGRATION_APPS.MEDELEMENT.SYNC_COUNTER.SKIPPED_COUNT',
  created_count: 'INTEGRATION_APPS.MEDELEMENT.SYNC_COUNTER.CREATED_COUNT',
  updated_count: 'INTEGRATION_APPS.MEDELEMENT.SYNC_COUNTER.UPDATED_COUNT',
  deactivated_count:
    'INTEGRATION_APPS.MEDELEMENT.SYNC_COUNTER.DEACTIVATED_COUNT',
  provider_count: 'INTEGRATION_APPS.MEDELEMENT.SYNC_COUNTER.PROVIDER_COUNT',
  not_returned_count:
    'INTEGRATION_APPS.MEDELEMENT.SYNC_COUNTER.NOT_RETURNED_COUNT',
  local_unlinked_count:
    'INTEGRATION_APPS.MEDELEMENT.SYNC_COUNTER.LOCAL_UNLINKED_COUNT',
};
const syncPhaseRows = computed(() =>
  syncPhases.map(phase => {
    const history = hookSyncStatus.value?.phase_statuses?.[phase];
    const currentResult = syncRun.value?.phase_results?.[phase];
    const isCurrent = syncRun.value?.current_phase === phase;
    return {
      phase,
      result: currentResult || history?.result,
      status: isCurrent ? 'running' : currentResult?.status || history?.status,
      lastSyncedAt: history?.last_synced_at,
      isCurrent,
    };
  })
);

const hasCustomLogo = computed(
  () =>
    !!integration.value?.logo &&
    integration.value.logo !== `${props.integrationId}.png`
);

const lightLogoSource = computed(() =>
  integration.value?.logo
    ? `/dashboard/images/integrations/${integration.value.logo}`
    : `/dashboard/images/integrations/${props.integrationId}.png`
);

const darkLogoSource = computed(() =>
  hasCustomLogo.value
    ? lightLogoSource.value
    : `/dashboard/images/integrations/${props.integrationId}-dark.png`
);

const visibleProperties = computed(
  () => integration.value?.visible_properties || []
);

const formItemLabelMap = computed(() =>
  Object.fromEntries(
    (integration.value?.settings_form_schema || []).map(item => [
      item.name,
      item.label,
    ])
  )
);

const headerDescription = computed(() =>
  replaceInstallationName(
    integration.value?.short_description || integration.value?.description || ''
  )
);

const headerFeatureName = computed(() =>
  ['dashboard_apps', 'webhook'].includes(props.integrationId)
    ? props.integrationId
    : 'integrations'
);

function humanizeProperty(property) {
  return property
    .split('_')
    .map(part => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ');
}

function formatFrequency(hours) {
  const normalizedHours = Number(hours);
  if (!normalizedHours) {
    return '--';
  }

  if (normalizedHours < 1) {
    return t('INTEGRATION_APPS.MEDELEMENT.FREQUENCY.EVERY_MINUTES', {
      count: normalizedHours * 60,
    });
  }

  if (normalizedHours === 24) {
    return t('INTEGRATION_APPS.MEDELEMENT.FREQUENCY.DAILY');
  }

  if (normalizedHours === 1) {
    return t('INTEGRATION_APPS.MEDELEMENT.FREQUENCY.HOURLY');
  }

  if (locale.value === 'ru') {
    return t('INTEGRATION_APPS.MEDELEMENT.FREQUENCY.EVERY_HOURS_RU', {
      count: normalizedHours,
    });
  }

  return t('INTEGRATION_APPS.MEDELEMENT.FREQUENCY.EVERY_HOURS', {
    count: normalizedHours,
  });
}

function formatValue(value, key = null) {
  if (key === 'sync_interval_hours') {
    return formatFrequency(value);
  }

  if (typeof value === 'boolean') {
    return value
      ? t('INTEGRATION_APPS.STATUS.ENABLED')
      : t('INTEGRATION_APPS.STATUS.DISABLED');
  }

  return value || '--';
}

function formatConflictDate(value) {
  if (!value) return '—';
  return new Intl.DateTimeFormat(locale.value, {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(new Date(value));
}

function formatConflictAmount(value) {
  if (value === null || value === undefined) return '—';
  return new Intl.NumberFormat(locale.value).format(value);
}

function schedulingStatusLabel(type, value) {
  if (!value) return '—';
  const namespace =
    type === 'payment'
      ? 'SCHEDULING.PAYMENT_STATUS'
      : 'SCHEDULING.APPOINTMENT_STATUS';
  const key = `${namespace}.${value}`;
  // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys
  const translated = t(key);
  return translated === key ? humanizeProperty(value) : translated;
}

const hookStatusLabel = computed(() =>
  connectedHook.value?.status
    ? t('INTEGRATION_APPS.STATUS.ENABLED')
    : t('INTEGRATION_APPS.STATUS.DISABLED')
);

const hookStatusClass = computed(() =>
  connectedHook.value?.status
    ? 'bg-n-teal-9 text-white'
    : 'bg-n-slate-8 text-white'
);

const hookDetails = computed(() => {
  if (!connectedHook.value) {
    return [];
  }

  return visibleProperties.value.map(property => ({
    key: property,
    label: formItemLabelMap.value[property] || humanizeProperty(property),
    value: formatValue(connectedHook.value.settings?.[property], property),
  }));
});

const medelementScheduleDetails = computed(() => {
  if (!isMedelement.value || !connectedHook.value) {
    return [];
  }

  if (syncSchedules.value.length) {
    return syncSchedules.value.flatMap(schedule => {
      const translation = syncScheduleTranslation[schedule.key];
      if (!translation) return [];
      return [
        {
          key: `${schedule.key}_next`,
          // Translation keys are selected from the closed allowlist above.
          // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys
          label: t(translation.next),
          value: schedule.next_sync_at_display || '--',
        },
        {
          key: `${schedule.key}_last`,
          // Translation keys are selected from the closed allowlist above.
          // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys
          label: t(translation.last),
          value: schedule.last_scheduled_sync_at_display || '--',
        },
      ];
    });
  }

  return [
    {
      key: 'next_sync_at',
      label: t('INTEGRATION_APPS.MEDELEMENT.NEXT_SYNC'),
      value: medelementMetadata.value.next_sync_at_display || '--',
    },
    {
      key: 'last_scheduled_sync_at',
      label: t('INTEGRATION_APPS.MEDELEMENT.LAST_SYNC'),
      value: medelementMetadata.value.last_scheduled_sync_at_display || '--',
    },
  ];
});

const macrocrmWebhookUrl = computed(
  () => macrocrmMetadata.value.webhook_url || ''
);

const macrocrmWebhookKey = computed(
  () => connectedHook.value?.reference_id || ''
);

function clearHookSyncPoll() {
  window.clearTimeout(hookSyncPollTimer);
  hookSyncPollTimer = undefined;
}

function beginHookSyncStatusMutation() {
  clearHookSyncPoll();
  hookSyncStatusRequestId += 1;
  return hookSyncStatusRequestId;
}

async function runSyncNow() {
  const requestId = beginHookSyncStatusMutation();
  try {
    const response = await store.dispatch('integrations/runHookSync', {
      hookId: connectedHook.value.id,
    });
    if (requestId !== hookSyncStatusRequestId) return;

    hookSyncStatus.value = response.sync_status;
    hookSyncPollFailures = 0;
    // Function declarations are hoisted; keeping the action flow grouped is clearer here.
    // eslint-disable-next-line no-use-before-define
    scheduleHookSyncPoll();
    useAlert(
      response?.message || t('INTEGRATION_APPS.MEDELEMENT.RUN_SYNC.SUCCESS')
    );
  } catch (error) {
    const errorMessage =
      error?.response?.data?.message ||
      t('INTEGRATION_APPS.MEDELEMENT.RUN_SYNC.ERROR');
    useAlert(errorMessage);
  } finally {
    // Function declarations are hoisted; keeping the action flow grouped is clearer here.
    // eslint-disable-next-line no-use-before-define
    if (requestId === hookSyncStatusRequestId) scheduleHookSyncPoll();
  }
}

function scheduleHookSyncPoll(delay = 2000) {
  clearHookSyncPoll();
  if (isSyncActive.value) {
    // eslint-disable-next-line no-use-before-define
    hookSyncPollTimer = window.setTimeout(fetchHookSyncStatus, delay);
  }
}

async function fetchHookSyncStatus() {
  const hookId = connectedHook.value?.id;
  if (!hookId) return;
  hookSyncStatusRequestId += 1;
  const requestId = hookSyncStatusRequestId;

  try {
    const status = await store.dispatch('integrations/getHookSyncStatus', {
      hookId,
      conflictPage: conflictPagination.value.page,
      filters: conflictFilters.value,
    });
    if (requestId !== hookSyncStatusRequestId) return;

    hookSyncStatus.value = status;
    hookSyncPollFailures = 0;
  } catch {
    if (requestId !== hookSyncStatusRequestId) return;

    hookSyncPollFailures += 1;
  } finally {
    if (requestId === hookSyncStatusRequestId) {
      const retryDelay = Math.min(2000 * 2 ** hookSyncPollFailures, 30000);
      scheduleHookSyncPoll(retryDelay);
    }
  }
}

async function loadConflictPage(page) {
  const hookId = connectedHook.value?.id;
  if (!hookId || page < 1 || page > conflictPagination.value.total_pages)
    return;
  clearHookSyncPoll();
  hookSyncStatusRequestId += 1;
  const requestId = hookSyncStatusRequestId;

  try {
    const status = await store.dispatch('integrations/getHookSyncStatus', {
      hookId,
      conflictPage: page,
      filters: conflictFilters.value,
    });
    if (requestId !== hookSyncStatusRequestId) return;

    hookSyncStatus.value = status;
    hookSyncPollFailures = 0;
  } catch {
    if (requestId === hookSyncStatusRequestId) hookSyncPollFailures += 1;
  } finally {
    if (requestId === hookSyncStatusRequestId) {
      const retryDelay = Math.min(2000 * 2 ** hookSyncPollFailures, 30000);
      scheduleHookSyncPoll(retryDelay);
    }
  }
}

function applyConflictFilters() {
  loadConflictPage(1);
}

function clearConflictFilters() {
  conflictFilters.value = {
    status: '',
    conflict_type: '',
    contact: '',
    from: '',
    to: '',
  };
  loadConflictPage(1);
}

function openContact(contact) {
  if (!contact?.id) return;
  window.open(
    `/app/accounts/${route.params.accountId}/contacts/${contact.id}`,
    '_blank',
    'noopener,noreferrer'
  );
}

function clearConflictFieldDirections(conflictId) {
  const directions = { ...selectedConflictFieldDirections.value };
  delete directions[conflictId];
  selectedConflictFieldDirections.value = directions;
}

function conflictFieldLabel(field) {
  const key = conflictFieldTranslation[field];
  return key ? t(key) : humanizeProperty(field);
}

async function resolveContactConflict(conflict, resolution) {
  const hookId = connectedHook.value?.id;
  if (!hookId) return false;

  const requestId = beginHookSyncStatusMutation();
  resolvingConflictId.value = conflict.id;
  try {
    const status = await store.dispatch(
      'integrations/resolveHookSyncConflict',
      { hookId, conflictId: conflict.id, ...resolution }
    );
    if (requestId !== hookSyncStatusRequestId) return false;

    hookSyncStatus.value = status;
    clearConflictFieldDirections(conflict.id);
    useAlert(t('INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.SUCCESS'));
    return true;
  } catch (error) {
    if (requestId !== hookSyncStatusRequestId) return false;

    const response = error?.response?.data;
    if (response?.code === 'contact_field_already_used') {
      await fetchHookSyncStatus();
    }
    const message =
      response?.code === 'contact_field_already_used'
        ? t(
            'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FIELD_ALREADY_USED',
            {
              field: conflictFieldLabel(response.field),
              contactId: response.contact_id,
            }
          )
        : response?.message ||
          t('INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.ERROR');
    useAlert(message);
    return false;
  } finally {
    resolvingConflictId.value = null;
    if (requestId === hookSyncStatusRequestId) scheduleHookSyncPoll();
  }
}

function mergeContactConflict(conflict, survivor = 'primary') {
  const resolution = conflict.contact_resolution;
  if (!resolution?.can_merge) return;
  pendingConflictAction.value = {
    type: 'merge',
    conflict,
    survivor,
  };
  conflictResolutionDialog.value?.open();
}

function fieldDirectionsForConflict(conflict) {
  const selected = selectedConflictFieldDirections.value[conflict.id] || {};
  const comparisons = new Map(
    (conflict.contact_resolution?.field_comparisons || []).map(field => [
      field.field,
      field,
    ])
  );
  return Object.fromEntries(
    Object.entries(selected).filter(([field, direction]) => {
      const comparison = comparisons.get(field);
      return direction === 'medelement_to_onelink'
        ? comparison?.can_sync_to_onelink
        : comparison?.can_sync_to_medelement;
    })
  );
}

function setConflictFieldDirection(conflict, field, direction) {
  const directions = { ...fieldDirectionsForConflict(conflict) };
  if (direction) directions[field] = direction;
  else delete directions[field];
  selectedConflictFieldDirections.value = {
    ...selectedConflictFieldDirections.value,
    [conflict.id]: directions,
  };
}

function fieldDirectionLabel(direction) {
  const key =
    direction === 'medelement_to_onelink'
      ? 'FROM_MEDELEMENT_TO_ONELINK'
      : 'FROM_ONELINK_TO_MEDELEMENT';
  return t(`INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.${key}`);
}

function syncConflictFields(conflict) {
  const fieldDirections = fieldDirectionsForConflict(conflict);
  if (!Object.keys(fieldDirections).length) return;
  pendingConflictAction.value = {
    type: 'sync_fields',
    conflict,
    fieldDirections,
  };
  conflictResolutionDialog.value?.open();
}

function keepContactsSeparate(conflict) {
  resolutionNote.value = '';
  pendingConflictAction.value = { type: 'keep_separate', conflict };
  conflictResolutionDialog.value?.open();
}

function deleteConflictContact(conflict, contact) {
  if (!contact?.id) return;
  pendingConflictAction.value = { type: 'delete', conflict, contact };
  conflictResolutionDialog.value?.open();
}

const conflictDialogDescription = computed(() => {
  const action = pendingConflictAction.value;
  if (!action) return '';
  if (action.type === 'keep_separate')
    return t('INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.NOTE_PROMPT');
  if (action.type === 'delete') {
    return t('INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.DELETE_CONFIRM', {
      contact: action.contact.name || `#${action.contact.id}`,
    });
  }

  if (action.type === 'sync_fields') {
    const changes = Object.entries(action.fieldDirections)
      .map(
        ([field, direction]) =>
          `${conflictFieldLabel(field)}: ${fieldDirectionLabel(direction)}`
      )
      .join('; ');
    return t(
      'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.SYNC_FIELDS_CONFIRM',
      { changes }
    );
  }

  const { primary_contact: primary, conflicting_contact: duplicate } =
    action.conflict.contact_resolution;
  const survivor = action.survivor === 'conflicting' ? duplicate : primary;
  const mergee = action.survivor === 'conflicting' ? primary : duplicate;
  return t('INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.MERGE_CONFIRM', {
    primary: survivor.name || `#${survivor.id}`,
    duplicate: mergee.name || `#${mergee.id}`,
  });
});

async function confirmConflictAction() {
  const action = pendingConflictAction.value;
  if (!action) return;
  let payload;
  if (action.type === 'merge') {
    const resolution = action.conflict.contact_resolution;
    const base =
      action.survivor === 'conflicting'
        ? resolution.conflicting_contact
        : resolution.primary_contact;
    const mergee =
      action.survivor === 'conflicting'
        ? resolution.primary_contact
        : resolution.conflicting_contact;
    payload = {
      resolution: 'merge',
      base_contact_id: base.id,
      mergee_contact_id: mergee.id,
    };
  } else if (action.type === 'delete') {
    payload = { resolution: 'delete', contact_id: action.contact.id };
  } else if (action.type === 'sync_fields') {
    payload = {
      resolution: 'sync_fields',
      field_directions: action.fieldDirections,
    };
  } else {
    payload = {
      resolution: 'keep_separate',
      note: resolutionNote.value.trim(),
    };
  }
  const resolved = await resolveContactConflict(action.conflict, payload);
  if (!resolved) return;
  conflictResolutionDialog.value?.close();
  pendingConflictAction.value = null;
}

async function retrySyncPhase(conflict) {
  const hookId = connectedHook.value?.id;
  if (!hookId || isSyncActive.value) return;

  const requestId = beginHookSyncStatusMutation();
  try {
    const response = await store.dispatch('integrations/runHookSync', {
      hookId,
      phases: [conflict.phase],
    });
    if (requestId !== hookSyncStatusRequestId) return;

    hookSyncStatus.value = response.sync_status;
    hookSyncPollFailures = 0;
    scheduleHookSyncPoll();
    useAlert(t('INTEGRATION_APPS.MEDELEMENT.RUN_SYNC.RETRY_QUEUED'));
  } catch (error) {
    useAlert(
      error?.response?.data?.message ||
        t('INTEGRATION_APPS.MEDELEMENT.RUN_SYNC.ERROR')
    );
  } finally {
    if (requestId === hookSyncStatusRequestId) scheduleHookSyncPoll();
  }
}

async function updateSyncConflict(conflict, resolution) {
  const hookId = connectedHook.value?.id;
  if (!hookId) return;

  const requestId = beginHookSyncStatusMutation();
  try {
    const status = await store.dispatch('integrations/updateHookSyncConflict', {
      hookId,
      conflictId: conflict.id,
      resolution,
    });
    if (requestId === hookSyncStatusRequestId) hookSyncStatus.value = status;
  } catch (error) {
    useAlert(
      error?.response?.data?.message ||
        t('INTEGRATION_APPS.MEDELEMENT.RUN_SYNC.CONFLICT_ERROR')
    );
  } finally {
    if (requestId === hookSyncStatusRequestId) scheduleHookSyncPoll();
  }
}

function syncStatusLabel(status) {
  const translationKey =
    syncStatusTranslation[status] || syncStatusTranslation.pending;
  // Translation keys are selected from the closed allowlist above.
  // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys
  return t(translationKey);
}

function syncPhaseLabel(phase) {
  const translationKey = syncPhaseTranslation[phase];
  if (!translationKey) return humanizeProperty(phase);

  // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys
  return t(translationKey);
}

function syncConflictLabel(type) {
  const translationKey = syncConflictTranslation[type];
  if (!translationKey) return humanizeProperty(type);

  // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys
  return t(translationKey);
}

function contactRoleLabel(role) {
  return role === 'primary'
    ? t('INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.PRIMARY')
    : t('INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.CONFLICTING');
}

function conflictStatusLabel(status) {
  const translationKey = conflictStatusTranslation[status];
  if (!translationKey) return humanizeProperty(status);

  // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys
  return t(translationKey);
}

function syncCounterLabel(key) {
  const translationKey = syncCounterTranslation[key];
  if (!translationKey) return humanizeProperty(key);

  // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys
  return t(translationKey);
}

function syncResultCounters(result) {
  return Object.entries(result || {}).filter(
    ([key, value]) => key.endsWith('_count') && Number.isFinite(Number(value))
  );
}

function formatSyncDate(value) {
  if (!value) return '—';

  return new Intl.DateTimeFormat(locale.value, {
    dateStyle: 'short',
    timeStyle: 'medium',
  }).format(new Date(value));
}

function resetMedelementCatalogFile() {
  medelementCatalogFile.value = null;
  if (medelementCatalogFileInput.value) {
    medelementCatalogFileInput.value.value = '';
  }
}

function openMedelementCatalogFilePicker() {
  medelementCatalogFileInput.value?.click();
}

function selectMedelementCatalogFile(event) {
  const file = event.target.files?.[0];
  if (!file) return;

  if (!file.name.toLowerCase().endsWith('.json')) {
    resetMedelementCatalogFile();
    useAlert(t('INTEGRATION_APPS.MEDELEMENT.IMPORT.ERRORS.INVALID_TYPE'));
    return;
  }

  if (file.size > medelementCatalogMaxBytes) {
    resetMedelementCatalogFile();
    useAlert(t('INTEGRATION_APPS.MEDELEMENT.IMPORT.ERRORS.FILE_TOO_LARGE'));
    return;
  }

  medelementCatalogFile.value = file;
}

function importErrorMessage(error) {
  const errorCode = error?.response?.data?.code;
  const messages = {
    missing_file: t('INTEGRATION_APPS.MEDELEMENT.IMPORT.ERRORS.MISSING_FILE'),
    file_too_large: t(
      'INTEGRATION_APPS.MEDELEMENT.IMPORT.ERRORS.FILE_TOO_LARGE'
    ),
    invalid_json: t('INTEGRATION_APPS.MEDELEMENT.IMPORT.ERRORS.INVALID_JSON'),
    invalid_payload: t(
      'INTEGRATION_APPS.MEDELEMENT.IMPORT.ERRORS.INVALID_PAYLOAD'
    ),
    import_in_progress: t(
      'INTEGRATION_APPS.MEDELEMENT.IMPORT.ERRORS.IMPORT_IN_PROGRESS'
    ),
  };
  return (
    messages[errorCode] ||
    t('INTEGRATION_APPS.MEDELEMENT.IMPORT.ERRORS.GENERIC')
  );
}

async function importMedelementCatalog() {
  if (!medelementCatalogFile.value) return;

  try {
    const response = await store.dispatch('integrations/importHookCatalog', {
      hookId: connectedHook.value.id,
      file: medelementCatalogFile.value,
    });
    useAlert(
      t('INTEGRATION_APPS.MEDELEMENT.IMPORT.SUCCESS', {
        specialists: response?.result?.specialists?.imported_count || 0,
        services: response?.result?.services?.imported_count || 0,
        links: response?.result?.services?.linked_count || 0,
      })
    );
    resetMedelementCatalogFile();
  } catch (error) {
    useAlert(importErrorMessage(error));
  }
}

async function copyMacrocrmWebhookUrl() {
  if (!macrocrmWebhookUrl.value) {
    return;
  }

  try {
    await copyTextToClipboard(macrocrmWebhookUrl.value);
    useAlert(t('INTEGRATION_APPS.MACROCRM.WEBHOOK.COPY_SUCCESS'));
  } catch (error) {
    useAlert(error.message);
  }
}

watch(
  () => connectedHook.value?.id,
  hookId => {
    clearHookSyncPoll();
    hookSyncStatusRequestId += 1;
    hookSyncPollFailures = 0;
    selectedConflictFieldDirections.value = {};
    hookSyncStatus.value = {
      run: null,
      phase_statuses: {},
      schedules: [],
      conflicts: [],
      conflict_counts: {},
    };
    if (isMedelement.value && hookId) fetchHookSyncStatus();
  },
  { immediate: true }
);

onBeforeUnmount(() => {
  clearHookSyncPoll();
  hookSyncStatusRequestId += 1;
});
</script>

<template>
  <div class="flex flex-col flex-1 gap-8 overflow-auto">
    <BaseSettingsHeader
      :title="integration.name"
      :description="headerDescription"
      :feature-name="headerFeatureName"
      :back-button-label="$t('GENERAL_SETTINGS.BACK')"
      :back-button-url="backButtonUrl"
    >
      <template #actions>
        <div v-if="hasConnectedHooks" class="flex gap-2">
          <NextButton
            v-if="isMedelement && connectedHook?.status"
            blue
            :label="$t('INTEGRATION_APPS.MEDELEMENT.RUN_SYNC.BUTTON')"
            :disabled="isSyncActive"
            :is-loading="uiFlags.isRunningHookSync || isSyncActive"
            @click="runSyncNow"
          />
          <NextButton
            faded
            slate
            :label="$t('INTEGRATION_APPS.CONFIGURE')"
            @click="$emit('edit', connectedHook)"
          />
          <NextButton
            faded
            ruby
            :label="$t('INTEGRATION_APPS.DISCONNECT.BUTTON_TEXT')"
            @click="$emit('delete', connectedHook)"
          />
        </div>
        <NextButton
          v-else
          blue
          :label="$t('INTEGRATION_APPS.CONNECT.BUTTON_TEXT')"
          @click="$emit('add')"
        />
      </template>
    </BaseSettingsHeader>

    <section
      v-if="showHookSyncPanel"
      class="flex flex-col gap-5 rounded-xl border border-n-weak bg-n-alpha-2 p-5"
    >
      <header class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h3 class="text-base font-medium text-n-slate-12">
            {{ $t('INTEGRATION_APPS.MEDELEMENT.RUN_SYNC.TITLE') }}
          </h3>
          <p v-if="syncRun" class="mt-1 text-sm text-n-slate-11">
            {{
              $t('INTEGRATION_APPS.MEDELEMENT.RUN_SYNC.STARTED_AT_VALUE', {
                date: formatSyncDate(syncRun.started_at || syncRun.created_at),
              })
            }}
          </p>
        </div>
        <span
          v-if="syncRun"
          class="rounded-full bg-n-alpha-3 px-3 py-1 text-sm font-medium text-n-slate-12"
        >
          {{ syncStatusLabel(syncRun.status) }}
        </span>
      </header>

      <p
        class="rounded-lg border border-n-weak bg-n-solid-1 p-3 text-sm text-n-slate-11"
      >
        {{ $t('INTEGRATION_APPS.MEDELEMENT.RUN_SYNC.DIRECTION_NOTE') }}
      </p>

      <div v-if="syncRun" class="grid gap-3 md:grid-cols-2 xl:grid-cols-5">
        <article
          v-for="row in syncPhaseRows"
          :key="row.phase"
          class="rounded-lg border border-n-weak bg-n-solid-1 p-3"
          :class="{ 'ring-2 ring-n-brand': row.isCurrent }"
        >
          <p class="text-sm font-medium text-n-slate-12">
            {{ syncPhaseLabel(row.phase) }}
          </p>
          <p class="mt-1 text-xs text-n-slate-10">
            {{
              row.status
                ? syncStatusLabel(row.status)
                : $t('INTEGRATION_APPS.MEDELEMENT.SYNC_STATUS.PENDING')
            }}
          </p>
          <p v-if="row.lastSyncedAt" class="mt-1 text-xs text-n-slate-9">
            {{
              $t('INTEGRATION_APPS.MEDELEMENT.RUN_SYNC.LAST_PHASE_SYNC', {
                date: formatSyncDate(row.lastSyncedAt),
              })
            }}
          </p>
          <dl
            v-if="syncResultCounters(row.result).length"
            class="mt-2 space-y-1"
          >
            <div
              v-for="[key, value] in syncResultCounters(row.result)"
              :key="key"
              class="flex justify-between gap-2 text-xs text-n-slate-11"
            >
              <dt>{{ syncCounterLabel(key) }}</dt>
              <dd class="font-medium text-n-slate-12">{{ value }}</dd>
            </div>
          </dl>
        </article>
      </div>

      <div
        v-if="syncRun?.error_message"
        class="rounded-lg border border-n-ruby-5 bg-n-ruby-2 p-3 text-sm text-n-ruby-11"
      >
        {{
          $t('INTEGRATION_APPS.MEDELEMENT.RUN_SYNC.ERROR_WITH_MESSAGE', {
            message: syncRun.error_message,
          })
        }}
      </div>

      <div class="flex flex-col gap-3">
        <div class="flex items-center justify-between gap-3">
          <h4 class="text-sm font-medium text-n-slate-12">
            {{ $t('INTEGRATION_APPS.MEDELEMENT.RUN_SYNC.CONFLICTS') }}
          </h4>
          <span class="text-xs text-n-slate-10">
            {{ hookSyncStatus.conflict_counts?.open || 0 }}
            {{ $t('INTEGRATION_APPS.MEDELEMENT.RUN_SYNC.OPEN_CONFLICTS') }}
          </span>
        </div>

        <div
          class="grid gap-3 rounded-lg border border-n-weak bg-n-alpha-2 p-3 md:grid-cols-2 xl:grid-cols-5"
        >
          <label class="flex flex-col gap-1 text-xs text-n-slate-11">
            {{
              $t(
                'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FILTER.STATUS'
              )
            }}
            <select
              v-model="conflictFilters.status"
              class="rounded-lg border border-n-weak bg-n-solid-1 px-3 py-2 text-sm"
            >
              <option value="">
                {{
                  $t(
                    'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FILTER.ALL'
                  )
                }}
              </option>
              <option value="open">{{ conflictStatusLabel('open') }}</option>
              <option value="ignored">
                {{ conflictStatusLabel('ignored') }}
              </option>
              <option value="resolved">
                {{ conflictStatusLabel('resolved') }}
              </option>
            </select>
          </label>
          <label class="flex flex-col gap-1 text-xs text-n-slate-11">
            {{
              $t('INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FILTER.TYPE')
            }}
            <select
              v-model="conflictFilters.conflict_type"
              class="rounded-lg border border-n-weak bg-n-solid-1 px-3 py-2 text-sm"
            >
              <option value="">
                {{
                  $t(
                    'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FILTER.ALL'
                  )
                }}
              </option>
              <option
                v-for="(_, type) in syncConflictTranslation"
                :key="type"
                :value="type"
              >
                {{ syncConflictLabel(type) }}
              </option>
            </select>
          </label>
          <Input
            v-model="conflictFilters.contact"
            :label="
              $t(
                'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FILTER.CONTACT'
              )
            "
          />
          <Input
            v-model="conflictFilters.from"
            type="date"
            :label="
              $t('INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FILTER.FROM')
            "
          />
          <Input
            v-model="conflictFilters.to"
            type="date"
            :label="
              $t('INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FILTER.TO')
            "
          />
          <div class="flex flex-wrap gap-2 md:col-span-2 xl:col-span-5">
            <NextButton
              blue
              :label="
                $t(
                  'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FILTER.APPLY'
                )
              "
              @click="applyConflictFilters"
            />
            <NextButton
              faded
              slate
              :label="
                $t(
                  'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FILTER.CLEAR'
                )
              "
              @click="clearConflictFilters"
            />
          </div>
        </div>

        <p
          v-if="!syncConflicts.length"
          class="rounded-lg border border-n-weak bg-n-solid-1 p-4 text-sm text-n-slate-10"
        >
          {{
            $t('INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FILTER.EMPTY')
          }}
        </p>

        <article
          v-for="conflict in syncConflicts"
          :key="conflict.id"
          class="flex flex-col gap-4 rounded-lg border border-n-weak bg-n-solid-1 p-4"
        >
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div>
              <p class="text-sm font-medium text-n-slate-12">
                {{ syncConflictLabel(conflict.conflict_type) }}
              </p>
              <p class="mt-1 text-xs text-n-slate-10">
                {{
                  $t('INTEGRATION_APPS.MEDELEMENT.RUN_SYNC.CONFLICT_META', {
                    phase: syncPhaseLabel(conflict.phase),
                    count: conflict.occurrences,
                  })
                }}
              </p>
            </div>
            <span
              class="rounded-full bg-n-alpha-3 px-2 py-1 text-xs text-n-slate-11"
            >
              {{ conflictStatusLabel(conflict.status) }}
            </span>
          </div>

          <div
            v-if="conflict.contact_resolution"
            class="grid gap-3 lg:grid-cols-2"
          >
            <article
              v-for="(contact, role) in {
                primary: conflict.contact_resolution.primary_contact,
                conflicting: conflict.contact_resolution.conflicting_contact,
              }"
              :key="role"
              class="rounded-lg border border-n-weak bg-n-alpha-2 p-3"
            >
              <template v-if="contact">
                <p
                  class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
                >
                  {{ contactRoleLabel(role) }}
                </p>
                <p class="mt-1 text-sm font-medium text-n-slate-12">
                  {{ contact.name || `#${contact.id}` }}
                </p>
                <dl class="mt-2 grid grid-cols-2 gap-2 text-xs text-n-slate-11">
                  <div>
                    <dt>
                      {{
                        $t(
                          'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.PHONE'
                        )
                      }}
                    </dt>
                    <dd>{{ contact.phone_number || '—' }}</dd>
                  </div>
                  <div>
                    <dt>
                      {{
                        $t(
                          'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.IIN'
                        )
                      }}
                    </dt>
                    <dd>{{ contact.identifier_masked || '—' }}</dd>
                  </div>
                  <div>
                    <dt>
                      {{
                        $t(
                          'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.CONVERSATIONS'
                        )
                      }}
                    </dt>
                    <dd>{{ contact.conversations_count }}</dd>
                  </div>
                  <div>
                    <dt>
                      {{
                        $t(
                          'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.APPOINTMENTS'
                        )
                      }}
                    </dt>
                    <dd>{{ contact.appointments_count }}</dd>
                  </div>
                  <div>
                    <dt>
                      {{
                        $t(
                          'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.DEALS'
                        )
                      }}
                    </dt>
                    <dd>{{ contact.deals_count }}</dd>
                  </div>
                  <div>
                    <dt>
                      {{
                        $t(
                          'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.CALLS'
                        )
                      }}
                    </dt>
                    <dd>{{ contact.call_sessions_count }}</dd>
                  </div>
                </dl>
                <div class="mt-3 flex flex-wrap gap-2">
                  <NextButton
                    faded
                    slate
                    size="sm"
                    :label="
                      $t(
                        'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.OPEN_EDIT'
                      )
                    "
                    @click="openContact(contact)"
                  />
                  <NextButton
                    v-if="
                      role === 'primary'
                        ? conflict.contact_resolution.can_delete_primary
                        : conflict.contact_resolution.can_delete_conflicting
                    "
                    faded
                    ruby
                    size="sm"
                    :label="
                      $t(
                        'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.DELETE_EMPTY'
                      )
                    "
                    @click="deleteConflictContact(conflict, contact)"
                  />
                </div>
              </template>
              <p v-else class="text-sm text-n-slate-10">
                {{
                  $t(
                    'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.CONTACT_MISSING'
                  )
                }}
              </p>
            </article>

            <div
              v-if="conflict.contact_resolution.field_comparisons?.length"
              class="overflow-x-auto rounded-lg border border-n-weak lg:col-span-2"
              data-test="contact-field-comparison"
            >
              <table class="w-full text-left text-xs text-n-slate-11">
                <thead class="bg-n-alpha-3 text-n-slate-12">
                  <tr>
                    <th class="px-3 py-2">
                      {{
                        $t(
                          'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.DIRECTION'
                        )
                      }}
                    </th>
                    <th class="px-3 py-2">
                      {{
                        $t(
                          'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FIELD_LABEL'
                        )
                      }}
                    </th>
                    <th class="px-3 py-2">
                      {{
                        $t(
                          'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.ONELINK_SOURCE'
                        )
                      }}
                    </th>
                    <th class="px-3 py-2">
                      {{
                        $t(
                          'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.MEDELEMENT_SOURCE'
                        )
                      }}
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    v-for="field in conflict.contact_resolution
                      .field_comparisons"
                    :key="field.field"
                    :class="field.differs ? 'bg-n-amber-1' : ''"
                    class="border-t border-n-weak"
                  >
                    <td class="px-3 py-2">
                      <select
                        :data-test="`field-direction-${field.field}`"
                        class="min-w-48 rounded-md border border-n-weak bg-n-solid-2 px-2 py-1 text-xs text-n-slate-12"
                        :value="
                          fieldDirectionsForConflict(conflict)[field.field] ||
                          ''
                        "
                        @change="
                          setConflictFieldDirection(
                            conflict,
                            field.field,
                            $event.target.value
                          )
                        "
                      >
                        <option value="">
                          {{
                            $t(
                              'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.DO_NOT_CHANGE'
                            )
                          }}
                        </option>
                        <option
                          v-if="field.can_sync_to_onelink"
                          value="medelement_to_onelink"
                        >
                          {{
                            $t(
                              'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FROM_MEDELEMENT_TO_ONELINK'
                            )
                          }}
                        </option>
                        <option
                          v-if="field.can_sync_to_medelement"
                          value="onelink_to_medelement"
                        >
                          {{
                            $t(
                              'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.FROM_ONELINK_TO_MEDELEMENT'
                            )
                          }}
                        </option>
                      </select>
                    </td>
                    <td class="px-3 py-2 font-medium text-n-slate-12">
                      {{ conflictFieldLabel(field.field) }}
                    </td>
                    <td class="px-3 py-2">{{ field.onelink_value || '—' }}</td>
                    <td class="px-3 py-2">
                      {{ field.medelement_value || '—' }}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <div
            v-else-if="conflict.entity_context?.kind === 'specialist'"
            class="rounded-lg border border-n-weak bg-n-alpha-2 p-3"
            data-test="specialist-conflict-card"
          >
            <p
              class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
            >
              {{
                $t('INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.SPECIALIST')
              }}
            </p>
            <p class="mt-1 text-sm font-medium text-n-slate-12">
              {{
                conflict.entity_context.resource?.name ||
                conflict.entity_context.specialist_name ||
                conflict.entity_context.specialist_code ||
                '—'
              }}
            </p>
            <dl
              class="mt-2 grid gap-2 text-xs text-n-slate-11 sm:grid-cols-2 lg:grid-cols-4"
            >
              <div>
                <dt>
                  {{
                    $t('INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.CODE')
                  }}
                </dt>
                <dd>{{ conflict.entity_context.specialist_code || '—' }}</dd>
              </div>
              <div>
                <dt>
                  {{
                    $t(
                      'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.SPECIALTY'
                    )
                  }}
                </dt>
                <dd>{{ conflict.entity_context.specialty || '—' }}</dd>
              </div>
              <div>
                <dt>
                  {{
                    $t(
                      'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.CABINET'
                    )
                  }}
                </dt>
                <dd>{{ conflict.entity_context.cabinet_code || '—' }}</dd>
              </div>
              <div>
                <dt>
                  {{
                    $t(
                      'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.SERVICE'
                    )
                  }}
                </dt>
                <dd>
                  {{
                    conflict.entity_context.service?.name ||
                    conflict.entity_context.service_code ||
                    '—'
                  }}
                </dd>
              </div>
            </dl>
          </div>

          <div
            v-else-if="conflict.entity_context?.kind === 'appointment'"
            class="rounded-lg border border-n-weak bg-n-alpha-2 p-3"
            data-test="appointment-conflict-card"
          >
            <p
              class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
            >
              {{
                $t(
                  'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.APPOINTMENT'
                )
              }}
            </p>
            <p class="mt-1 text-sm font-medium text-n-slate-12">
              {{
                conflict.entity_context.appointment?.client_name ||
                conflict.entity_context.patient_code ||
                conflict.entity_context.reception_code ||
                '—'
              }}
            </p>
            <dl
              class="mt-2 grid gap-2 text-xs text-n-slate-11 sm:grid-cols-2 lg:grid-cols-4"
            >
              <div>
                <dt>
                  {{
                    $t(
                      'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.RECEPTION_CODE'
                    )
                  }}
                </dt>
                <dd>{{ conflict.entity_context.reception_code || '—' }}</dd>
              </div>
              <div>
                <dt>
                  {{
                    $t(
                      'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.DATE_TIME'
                    )
                  }}
                </dt>
                <dd>
                  {{ formatConflictDate(conflict.entity_context.starts_at) }}
                </dd>
              </div>
              <div>
                <dt>
                  {{
                    $t(
                      'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.SPECIALIST'
                    )
                  }}
                </dt>
                <dd>
                  {{
                    conflict.entity_context.appointment?.resource_name ||
                    conflict.entity_context.resource?.name ||
                    conflict.entity_context.specialist_code ||
                    '—'
                  }}
                </dd>
              </div>
              <div>
                <dt>
                  {{
                    $t(
                      'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.SERVICE'
                    )
                  }}
                </dt>
                <dd>
                  {{ conflict.entity_context.appointment?.service_name || '—' }}
                </dd>
              </div>
              <div>
                <dt>
                  {{
                    $t(
                      'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.STATUS_LABEL'
                    )
                  }}
                </dt>
                <dd>
                  {{
                    schedulingStatusLabel(
                      'appointment',
                      conflict.entity_context.appointment?.status
                    )
                  }}
                </dd>
              </div>
              <div>
                <dt>
                  {{
                    $t(
                      'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.PAYMENT_STATUS'
                    )
                  }}
                </dt>
                <dd>
                  {{
                    schedulingStatusLabel(
                      'payment',
                      conflict.entity_context.appointment?.payment_status
                    )
                  }}
                </dd>
              </div>
              <div>
                <dt>
                  {{
                    $t(
                      'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.LOCAL_AMOUNT'
                    )
                  }}
                </dt>
                <dd>
                  {{
                    formatConflictAmount(
                      conflict.entity_context.local_amount ??
                        conflict.entity_context.appointment?.service_amount
                    )
                  }}
                </dd>
              </div>
              <div>
                <dt>
                  {{
                    $t(
                      'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.PROVIDER_AMOUNT'
                    )
                  }}
                </dt>
                <dd>
                  {{
                    formatConflictAmount(
                      conflict.entity_context.provider_amount
                    )
                  }}
                </dd>
              </div>
            </dl>
          </div>

          <div class="flex flex-wrap gap-2">
            <NextButton
              v-if="
                conflict.status === 'open' &&
                conflict.contact_resolution?.can_merge
              "
              blue
              :is-loading="resolvingConflictId === conflict.id"
              :label="
                $t(
                  'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.MERGE_TO_PRIMARY'
                )
              "
              @click="mergeContactConflict(conflict, 'primary')"
            />
            <NextButton
              v-if="
                conflict.status === 'open' &&
                conflict.contact_resolution?.can_merge
              "
              faded
              blue
              :is-loading="resolvingConflictId === conflict.id"
              :label="
                $t(
                  'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.MERGE_TO_CONFLICTING'
                )
              "
              @click="mergeContactConflict(conflict, 'conflicting')"
            />
            <NextButton
              v-if="
                conflict.status === 'open' &&
                conflict.contact_resolution?.can_sync_fields
              "
              blue
              :is-loading="resolvingConflictId === conflict.id"
              :disabled="
                !Object.keys(fieldDirectionsForConflict(conflict)).length
              "
              :label="
                $t(
                  'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.APPLY_FIELD_DIRECTIONS'
                )
              "
              @click="syncConflictFields(conflict)"
            />
            <NextButton
              v-if="conflict.status === 'open' && conflict.contact_resolution"
              faded
              slate
              :label="
                $t(
                  'INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.KEEP_SEPARATE'
                )
              "
              @click="keepContactsSeparate(conflict)"
            />
            <NextButton
              v-if="conflict.status === 'open'"
              faded
              blue
              :disabled="isSyncActive"
              :label="$t('INTEGRATION_APPS.MEDELEMENT.RUN_SYNC.RETRY_PHASE')"
              @click="retrySyncPhase(conflict)"
            />
            <NextButton
              v-if="conflict.status === 'open' && !conflict.contact_resolution"
              faded
              slate
              :label="$t('INTEGRATION_APPS.MEDELEMENT.RUN_SYNC.IGNORE')"
              @click="updateSyncConflict(conflict, 'ignore')"
            />
            <NextButton
              v-if="conflict.status === 'ignored'"
              faded
              slate
              :label="$t('INTEGRATION_APPS.MEDELEMENT.RUN_SYNC.REOPEN')"
              @click="updateSyncConflict(conflict, 'reopen')"
            />
          </div>
        </article>

        <div
          v-if="conflictPagination.total_pages > 1"
          class="flex items-center justify-end gap-2"
        >
          <NextButton
            faded
            slate
            :disabled="conflictPagination.page <= 1"
            :label="
              $t('INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.PREVIOUS')
            "
            @click="loadConflictPage(conflictPagination.page - 1)"
          />
          <span class="text-xs text-n-slate-10">
            {{
              $t('INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.PAGE', {
                page: conflictPagination.page,
                total: conflictPagination.total_pages,
              })
            }}
          </span>
          <NextButton
            faded
            slate
            :disabled="
              conflictPagination.page >= conflictPagination.total_pages
            "
            :label="$t('INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.NEXT')"
            @click="loadConflictPage(conflictPagination.page + 1)"
          />
        </div>
      </div>
    </section>

    <div
      v-if="hasConnectedHooks"
      class="outline outline-n-container outline-1 bg-n-alpha-3 rounded-md shadow p-6"
    >
      <div class="flex flex-col gap-6 lg:flex-row lg:items-start">
        <div class="flex h-16 w-16 shrink-0 items-center justify-center">
          <img
            :src="lightLogoSource"
            class="max-w-full rounded-md border border-n-weak shadow-sm block dark:hidden bg-n-alpha-3 dark:bg-n-alpha-2"
          />
          <img
            :src="darkLogoSource"
            class="max-w-full rounded-md border border-n-weak shadow-sm hidden dark:block bg-n-alpha-3 dark:bg-n-alpha-2"
          />
        </div>
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-start justify-end gap-3">
            <span
              class="inline-flex shrink-0 items-center rounded-full px-3 py-1 text-xs font-medium"
              :class="hookStatusClass"
            >
              {{ hookStatusLabel }}
            </span>
          </div>

          <div
            class="mt-4 grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3"
          >
            <div
              v-for="detail in hookDetails"
              :key="detail.key"
              class="rounded-md bg-n-alpha-2 px-4 py-3"
            >
              <p class="text-xs uppercase tracking-[1px] text-n-slate-10">
                {{ detail.label }}
              </p>
              <p class="mt-1 break-all text-sm font-medium text-n-slate-12">
                {{ detail.value }}
              </p>
            </div>
          </div>

          <div
            v-if="medelementScheduleDetails.length"
            class="mt-4 grid grid-cols-1 gap-4 md:grid-cols-2"
          >
            <div
              v-for="detail in medelementScheduleDetails"
              :key="detail.key"
              class="rounded-md bg-n-alpha-2 px-4 py-3"
            >
              <p class="text-xs uppercase tracking-[1px] text-n-slate-10">
                {{ detail.label }}
              </p>
              <p class="mt-1 break-all text-sm font-medium text-n-slate-12">
                {{ detail.value }}
              </p>
            </div>
          </div>

          <div v-if="isMedelement" class="mt-4 rounded-md bg-n-alpha-2 p-4">
            <p class="text-sm font-medium text-n-slate-12">
              {{ $t('INTEGRATION_APPS.MEDELEMENT.IMPORT.TITLE') }}
            </p>
            <p class="mt-1 text-sm leading-6 text-n-slate-11">
              {{ $t('INTEGRATION_APPS.MEDELEMENT.IMPORT.DESCRIPTION') }}
              <a
                href="/downloads/medelement-catalog-sample.json"
                download="medelement-catalog-sample.json"
                class="text-n-blue-11"
              >
                {{ $t('INTEGRATION_APPS.MEDELEMENT.IMPORT.DOWNLOAD_SAMPLE') }}
              </a>
            </p>
            <div class="mt-3 flex flex-wrap items-center gap-2">
              <NextButton
                faded
                slate
                size="sm"
                icon="i-lucide-upload"
                :label="$t('INTEGRATION_APPS.MEDELEMENT.IMPORT.CHOOSE_FILE')"
                :disabled="uiFlags.isImportingHookCatalog"
                @click="openMedelementCatalogFilePicker"
              />
              <span
                v-if="medelementCatalogFile"
                class="max-w-64 truncate text-sm text-n-slate-11"
              >
                {{ medelementCatalogFile.name }}
              </span>
              <NextButton
                v-if="medelementCatalogFile"
                blue
                size="sm"
                :label="$t('INTEGRATION_APPS.MEDELEMENT.IMPORT.BUTTON')"
                :is-loading="uiFlags.isImportingHookCatalog"
                @click="importMedelementCatalog"
              />
              <input
                ref="medelementCatalogFileInput"
                type="file"
                accept=".json,application/json"
                class="hidden"
                @change="selectMedelementCatalogFile"
              />
            </div>
          </div>

          <div
            v-if="isMacrocrm && macrocrmWebhookUrl"
            class="mt-4 rounded-md bg-n-alpha-2 p-4"
          >
            <p class="text-sm leading-6 text-n-slate-11">
              {{ $t('INTEGRATION_APPS.MACROCRM.WEBHOOK.DESCRIPTION') }}
            </p>

            <div class="mt-3 flex flex-wrap gap-2">
              <span
                class="inline-flex items-center rounded-full bg-n-alpha-3 px-3 py-1 text-xs font-medium text-n-slate-12"
              >
                {{ $t('INTEGRATION_APPS.MACROCRM.WEBHOOK.METHOD') }}
              </span>
              <span
                class="inline-flex items-center rounded-full bg-n-alpha-3 px-3 py-1 text-xs font-medium text-n-slate-12"
              >
                {{ $t('INTEGRATION_APPS.MACROCRM.WEBHOOK.EVENT') }}
              </span>
            </div>

            <div
              class="mt-4 flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between"
            >
              <div class="min-w-0 flex-1">
                <p class="text-xs uppercase tracking-[1px] text-n-slate-10">
                  {{ $t('INTEGRATION_APPS.MACROCRM.WEBHOOK.URL_LABEL') }}
                </p>
                <p class="mt-1 break-all text-sm font-medium text-n-slate-12">
                  {{ macrocrmWebhookUrl }}
                </p>
              </div>
              <NextButton
                faded
                slate
                size="sm"
                icon="i-lucide-clipboard"
                :label="$t('INTEGRATION_APPS.MACROCRM.WEBHOOK.COPY')"
                @click="copyMacrocrmWebhookUrl"
              />
            </div>

            <div v-if="macrocrmWebhookKey" class="mt-4">
              <p class="text-xs uppercase tracking-[1px] text-n-slate-10">
                {{ $t('INTEGRATION_APPS.MACROCRM.WEBHOOK.KEY_LABEL') }}
              </p>
              <p class="mt-1 break-all text-sm font-medium text-n-slate-12">
                {{ macrocrmWebhookKey }}
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>

    <div
      v-else
      class="outline outline-n-container outline-1 bg-n-alpha-3 rounded-md shadow p-8 text-center text-sm text-n-slate-11"
    >
      {{
        $t('INTEGRATION_APPS.NO_HOOK_CONFIGURED', {
          integrationId: integration.id,
        })
      }}
    </div>

    <Dialog
      ref="conflictResolutionDialog"
      type="alert"
      :title="$t('INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.TITLE')"
      :description="conflictDialogDescription"
      :is-loading="Boolean(resolvingConflictId)"
      :disable-confirm-button="
        pendingConflictAction?.type === 'keep_separate' &&
        !resolutionNote.trim()
      "
      @confirm="confirmConflictAction"
      @close="pendingConflictAction = null"
    >
      <Input
        v-if="pendingConflictAction?.type === 'keep_separate'"
        v-model="resolutionNote"
        :label="
          $t('INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.NOTE_LABEL')
        "
        :placeholder="
          $t('INTEGRATION_APPS.MEDELEMENT.CONFLICT_RESOLUTION.NOTE_PLACEHOLDER')
        "
      />
    </Dialog>
  </div>
</template>
