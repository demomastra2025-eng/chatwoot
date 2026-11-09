<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import VoiceAPI from 'dashboard/api/channel/voice/voiceAPIClient';
import InboxMembersAPI from 'dashboard/api/inboxMembers';
import SettingsLayout from '../SettingsLayout.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const VIRTUAL_PBX_PROVIDERS = [
  'asterisk_analog',
  'sipuni',
  'binotel',
  'beeline',
  'wazo',
  'virtual_pbx',
  'kazakhtelecom',
  'tele2',
  'altel',
  'kcell',
];

const PHONE_NUMBER_EXAMPLE = '+77000000000';

const SIP_CREDENTIAL_PROVIDERS = [
  'asterisk_analog',
  'sipuni',
  'binotel',
  'beeline',
];

const defaultCallRoutingConfig = () => ({
  show_extended_call_card: true,
  inbound: {
    routing_authority: 'onelink',
    schedule_mode: 'always',
    off_hours_action: 'reject',
    off_hours_forward_number: '',
    ring_timeout_seconds: 30,
    skip_busy_operators: true,
    ringtone: 'default',
    groups: [
      {
        id: 'group-1',
        name: '',
        strategy: 'broadcast',
        ring_seconds: 25,
        user_ids: [],
      },
    ],
    fallback_action: 'reject',
    fallback_forward_number: '',
    whatsapp_followup: {
      enabled: false,
      inbox_id: '',
      template_name: '',
      template_language: 'ru',
      custom_message: '',
      cooldown_minutes: 60,
    },
  },
  outbound: {
    access_mode: 'all_members',
    allowed_user_ids: [],
    caller_id_number: '',
  },
});

const { t } = useI18n();
const store = useStore();
const inboxes = useMapGetter('inboxes/getInboxes');
const agents = useMapGetter('agents/getAgents');

const isBootstrapping = ref(false);
const activeMainTab = ref('routing');
const callRoutingSubTab = ref('inbound');
const isSavingUnifiedRouting = ref(false);
const hasHydratedUnifiedRouting = ref(false);
const selectedRoutingInboxIds = ref([]);
const callRoutingForm = reactive(defaultCallRoutingConfig());
const phoneStates = reactive({});
let profileCounter = 0;

const nextClientId = () => {
  profileCounter += 1;
  return `telephony-profile-${profileCounter}`;
};

const isVoiceChannel = inbox => inbox?.channel_type === 'Channel::Voice';

const isWhatsappCallingChannel = inbox =>
  inbox?.channel_type === 'Channel::Whatsapp' &&
  inbox?.provider === 'whatsapp_cloud' &&
  Boolean(inbox?.provider_config?.calling_enabled);

const voiceInboxes = computed(() =>
  (inboxes.value || []).filter(isVoiceChannel)
);

const telephonyInboxes = computed(() =>
  (inboxes.value || []).filter(
    inbox => isVoiceChannel(inbox) || isWhatsappCallingChannel(inbox)
  )
);

const whatsappFollowupInboxes = computed(() =>
  (inboxes.value || []).filter(inbox =>
    ['Channel::Whatsapp', 'Channel::WhatsappWeb'].includes(inbox.channel_type)
  )
);

const selectedWhatsappFollowupInbox = computed(() => {
  const targetId = Number(callRoutingForm.inbound.whatsapp_followup.inbox_id);
  if (!targetId) return null;
  return (
    whatsappFollowupInboxes.value.find(
      inbox => Number(inbox.id) === targetId
    ) || null
  );
});

const isSelectedWhatsappFollowupOfficial = computed(
  () =>
    selectedWhatsappFollowupInbox.value?.channel_type === 'Channel::Whatsapp' &&
    selectedWhatsappFollowupInbox.value?.provider === 'whatsapp_cloud'
);

const selectedWhatsappFollowupTemplates = computed(() => {
  const templates =
    selectedWhatsappFollowupInbox.value?.message_templates || [];
  return templates.filter(
    tpl => !tpl.status || String(tpl.status).toLowerCase() === 'approved'
  );
});

const isVirtualPbxInbox = inbox => {
  if (!isVoiceChannel(inbox)) return false;
  if (!inbox.provider) return true;
  return VIRTUAL_PBX_PROVIDERS.includes(inbox.provider);
};

const ensurePhoneState = inboxId => {
  if (!phoneStates[inboxId]) {
    phoneStates[inboxId] = {
      isLoading: false,
      isSaving: false,
      loadError: '',
      readOnly: false,
      remoteCommitAllowed: false,
      configurationVersion: null,
      providerKind: '',
      providerLabel: '',
      displayPhoneNumber: '',
      routingMode: 'operator',
      fallbackMode: 'reject',
      operatorDistributionMode: 'broadcast',
      maxCallDurationSeconds: 1800,
      callRouting: null,
      profiles: [],
      members: [],
    };
  }
  return phoneStates[inboxId];
};

const requiresSipCredentials = (inbox, phoneState) => {
  const kind = phoneState?.providerKind || inbox?.provider || '';
  return SIP_CREDENTIAL_PROVIDERS.includes(kind);
};

const isWazoInbox = (inbox, phoneState) => {
  const kind = phoneState?.providerKind || inbox?.provider || '';
  return ['wazo', 'kazakhtelecom', 'tele2', 'altel', 'kcell'].includes(kind);
};

const mapServerProfile = profile => ({
  clientId: nextClientId(),
  id: profile.id || null,
  profileKind: profile.profile_kind || 'human_operator',
  userId: profile.user_id || '',
  userName: profile.user_name || '',
  internalExtension: profile.internal_extension || '',
  sipUsername: profile.sip_username || '',
  originalSipUsername: profile.sip_username || '',
  sipPassword: '',
  sipPasswordConfigured: Boolean(profile.sip_password_configured),
  enabled: profile.enabled !== false,
});

const getEmployeeOptions = (inbox, phoneState) => {
  const byId = new Map();
  const addMember = member => {
    const id = Number(member?.id || member?.user_id);
    if (!id || byId.has(id)) return;
    byId.set(id, {
      value: id,
      label:
        member.name ||
        member.user_name ||
        member.available_name ||
        member.email ||
        `#${id}`,
    });
  };

  (agents.value || []).forEach(addMember);
  (phoneState?.members || []).forEach(addMember);
  (inbox?.members || inbox?.agents || inbox?.users || []).forEach(addMember);
  (phoneState?.profiles || []).forEach(profile =>
    addMember({ id: profile.userId, name: profile.userName })
  );

  return Array.from(byId.values());
};

const allEmployeeOptions = computed(() => {
  const byId = new Map();
  const addMember = member => {
    const id = Number(member?.id || member?.user_id || member?.value);
    if (!id || byId.has(id)) return;
    byId.set(id, {
      value: id,
      label:
        member.label ||
        member.name ||
        member.user_name ||
        member.available_name ||
        member.email ||
        `#${id}`,
    });
  };

  (agents.value || []).forEach(addMember);
  telephonyInboxes.value.forEach(inbox => {
    const state = phoneStates[inbox.id];
    getEmployeeOptions(inbox, state).forEach(addMember);
  });

  return Array.from(byId.values());
});

const hydrateUnifiedRoutingFromRaw = rawConfig => {
  if (!rawConfig || typeof rawConfig !== 'object') return;
  const defaults = defaultCallRoutingConfig();
  const inbound = rawConfig.inbound || {};
  const outbound = rawConfig.outbound || {};
  const rawFollowup = inbound.whatsapp_followup || {};
  const rawGroups =
    Array.isArray(inbound.groups) && inbound.groups.length
      ? inbound.groups
      : defaults.inbound.groups;

  callRoutingForm.show_extended_call_card =
    rawConfig.show_extended_call_card !== undefined
      ? Boolean(rawConfig.show_extended_call_card)
      : defaults.show_extended_call_card;

  callRoutingForm.inbound.routing_authority =
    inbound.routing_authority === 'external_pbx' ? 'external_pbx' : 'onelink';
  callRoutingForm.inbound.schedule_mode =
    inbound.schedule_mode || defaults.inbound.schedule_mode;
  callRoutingForm.inbound.off_hours_action =
    inbound.off_hours_action || defaults.inbound.off_hours_action;
  callRoutingForm.inbound.off_hours_forward_number =
    inbound.off_hours_forward_number || '';
  callRoutingForm.inbound.ring_timeout_seconds = Number(
    inbound.ring_timeout_seconds || defaults.inbound.ring_timeout_seconds
  );
  callRoutingForm.inbound.skip_busy_operators =
    inbound.skip_busy_operators !== undefined
      ? Boolean(inbound.skip_busy_operators)
      : defaults.inbound.skip_busy_operators;
  callRoutingForm.inbound.ringtone =
    inbound.ringtone || defaults.inbound.ringtone;
  callRoutingForm.inbound.groups = rawGroups.map((group, idx) => ({
    id: group.id || `group-${idx + 1}`,
    name: group.name || '',
    strategy: group.strategy || 'broadcast',
    ring_seconds: Number(group.ring_seconds || 25),
    user_ids: Array.isArray(group.user_ids)
      ? group.user_ids
          .map(id => Number(id))
          .filter(id => Number.isFinite(id) && id > 0)
      : [],
  }));
  callRoutingForm.inbound.fallback_action =
    inbound.fallback_action || defaults.inbound.fallback_action;
  callRoutingForm.inbound.fallback_forward_number =
    inbound.fallback_forward_number || '';
  callRoutingForm.inbound.whatsapp_followup = {
    enabled: Boolean(rawFollowup.enabled),
    inbox_id: rawFollowup.inbox_id ? Number(rawFollowup.inbox_id) : '',
    template_name: rawFollowup.template_name || '',
    template_language: rawFollowup.template_language || 'ru',
    custom_message: rawFollowup.custom_message || '',
    cooldown_minutes: Number(rawFollowup.cooldown_minutes || 60),
  };

  callRoutingForm.outbound.access_mode =
    outbound.access_mode || defaults.outbound.access_mode;
  callRoutingForm.outbound.allowed_user_ids = Array.isArray(
    outbound.allowed_user_ids
  )
    ? outbound.allowed_user_ids
        .map(id => Number(id))
        .filter(id => Number.isFinite(id) && id > 0)
    : [];
  callRoutingForm.outbound.caller_id_number = outbound.caller_id_number || '';
};

const serializeUnifiedCallRouting = ({
  forceOnelinkAuthority = false,
} = {}) => {
  const inbound = callRoutingForm.inbound || {};
  const outbound = callRoutingForm.outbound || {};
  const followup = inbound.whatsapp_followup || {};
  let authority = 'onelink';
  if (!forceOnelinkAuthority && inbound.routing_authority === 'external_pbx') {
    authority = 'external_pbx';
  }

  return {
    show_extended_call_card: callRoutingForm.show_extended_call_card !== false,
    inbound: {
      routing_authority: authority,
      schedule_mode: inbound.schedule_mode || 'always',
      off_hours_action: inbound.off_hours_action || 'reject',
      off_hours_forward_number: (inbound.off_hours_forward_number || '').trim(),
      ring_timeout_seconds: Number(inbound.ring_timeout_seconds || 30),
      skip_busy_operators: Boolean(inbound.skip_busy_operators),
      ringtone: inbound.ringtone || 'default',
      groups: (inbound.groups || []).map((group, idx) => ({
        id: group.id || `group-${idx + 1}`,
        name: (group.name || '').trim(),
        strategy: group.strategy || 'broadcast',
        ring_seconds: Number(group.ring_seconds || 25),
        user_ids: (group.user_ids || [])
          .map(id => Number(id))
          .filter(id => Number.isFinite(id) && id > 0),
      })),
      fallback_action: inbound.fallback_action || 'reject',
      fallback_forward_number: (inbound.fallback_forward_number || '').trim(),
      whatsapp_followup: {
        enabled: Boolean(followup.enabled),
        inbox_id: followup.inbox_id ? Number(followup.inbox_id) : null,
        template_name: (followup.template_name || '').trim(),
        template_language: (followup.template_language || 'ru').trim(),
        custom_message: (followup.custom_message || '').trim(),
        cooldown_minutes: Math.min(
          Math.max(Number(followup.cooldown_minutes || 60), 5),
          1440
        ),
      },
    },
    outbound: {
      access_mode: outbound.access_mode || 'all_members',
      allowed_user_ids: (outbound.allowed_user_ids || [])
        .map(id => Number(id))
        .filter(id => Number.isFinite(id) && id > 0),
      caller_id_number: (outbound.caller_id_number || '').trim(),
    },
  };
};

const addCallRoutingGroup = () => {
  const nextIndex = (callRoutingForm.inbound.groups?.length || 0) + 1;
  callRoutingForm.inbound.groups.push({
    id: `group-${Date.now()}-${nextIndex}`,
    name: '',
    strategy: 'broadcast',
    ring_seconds: 25,
    user_ids: [],
  });
};

const removeCallRoutingGroup = index => {
  if (callRoutingForm.inbound.groups.length <= 1) return;
  callRoutingForm.inbound.groups.splice(index, 1);
};

const toggleCallRoutingGroupUser = (group, userId) => {
  const numericId = Number(userId);
  if (!numericId) return;
  const idx = (group.user_ids || []).indexOf(numericId);
  if (idx >= 0) {
    group.user_ids.splice(idx, 1);
  } else {
    group.user_ids.push(numericId);
  }
};

const toggleCallRoutingOutboundUser = userId => {
  const numericId = Number(userId);
  if (!numericId) return;
  const list = callRoutingForm.outbound.allowed_user_ids;
  const idx = list.indexOf(numericId);
  if (idx >= 0) {
    list.splice(idx, 1);
  } else {
    list.push(numericId);
  }
};

const toggleRoutingInboxSelection = inboxId => {
  const numericId = Number(inboxId);
  const idx = selectedRoutingInboxIds.value.indexOf(numericId);
  if (idx >= 0) {
    if (selectedRoutingInboxIds.value.length > 1) {
      selectedRoutingInboxIds.value.splice(idx, 1);
    }
  } else {
    selectedRoutingInboxIds.value.push(numericId);
  }
};

const loadPhoneStatus = async inbox => {
  if (!inbox?.id) return;
  const state = ensurePhoneState(inbox.id);

  if (isWhatsappCallingChannel(inbox)) {
    state.providerKind = 'whatsapp_cloud';
    state.providerLabel = 'WhatsApp';
    state.displayPhoneNumber = inbox.phone_number || '';
    state.callRouting = inbox.provider_config?.call_routing || null;
    if (!hasHydratedUnifiedRouting.value && state.callRouting) {
      hydrateUnifiedRoutingFromRaw(state.callRouting);
      hasHydratedUnifiedRouting.value = true;
    }
    return;
  }

  if (!isVirtualPbxInbox(inbox)) return;
  state.isLoading = true;
  state.loadError = '';

  try {
    const [statusResponse, membersResponse] = await Promise.all([
      VoiceAPI.getVirtualPbxStatus(inbox.id, { includeDiagnostics: false }),
      InboxMembersAPI.get(inbox.id).catch(() => ({ data: { payload: [] } })),
    ]);
    const uiConfig =
      statusResponse?.payload?.ui_config || statusResponse?.ui_config || {};
    state.configurationVersion = uiConfig.configuration_version ?? null;
    state.readOnly = Boolean(
      uiConfig.status?.read_only || uiConfig.permissions?.editable === false
    );
    state.remoteCommitAllowed = Boolean(
      uiConfig.permissions?.remote_commit_allowed
    );
    state.providerKind =
      uiConfig.channel?.provider_kind ||
      uiConfig.connection?.provider_kind ||
      inbox.provider ||
      '';
    state.providerLabel =
      uiConfig.channel?.provider_label ||
      uiConfig.connection?.provider_label ||
      inbox.provider ||
      '';
    state.displayPhoneNumber =
      uiConfig.channel?.display_phone_number || inbox.phone_number || '';
    state.routingMode = uiConfig.routing?.mode || 'operator';
    state.fallbackMode = uiConfig.routing?.fallback_mode || 'reject';
    state.operatorDistributionMode =
      uiConfig.routing?.operator_distribution_mode || 'broadcast';
    state.maxCallDurationSeconds =
      Number(uiConfig.routing?.max_call_duration_seconds) || 1800;
    state.callRouting = uiConfig.routing?.call_routing || null;
    state.members = membersResponse?.data?.payload || [];
    const serverProfiles = uiConfig.employees || uiConfig.profiles || [];
    state.profiles = serverProfiles
      .filter(profile => profile?.profile_kind !== 'voice_agent')
      .map(mapServerProfile);

    if (!hasHydratedUnifiedRouting.value && state.callRouting) {
      hydrateUnifiedRoutingFromRaw(state.callRouting);
      hasHydratedUnifiedRouting.value = true;
    }
  } catch (error) {
    state.loadError =
      error?.response?.data?.message ||
      error?.response?.data?.error ||
      t('TELEPHONY_SETTINGS.LOAD_ERROR');
  } finally {
    state.isLoading = false;
  }
};

const loadAllPhones = async () => {
  const currentIds = telephonyInboxes.value.map(inbox => Number(inbox.id));
  if (!selectedRoutingInboxIds.value.length) {
    selectedRoutingInboxIds.value = [...currentIds];
  } else {
    selectedRoutingInboxIds.value = selectedRoutingInboxIds.value.filter(id =>
      currentIds.includes(id)
    );
    currentIds.forEach(id => {
      if (!selectedRoutingInboxIds.value.includes(id)) {
        selectedRoutingInboxIds.value.push(id);
      }
    });
  }
  await Promise.all(
    telephonyInboxes.value.map(inbox => loadPhoneStatus(inbox))
  );
};

const saveRoutingForSingleInbox = async (inbox, primaryStrategy) => {
  const state = ensurePhoneState(inbox.id);
  if (isWhatsappCallingChannel(inbox)) {
    const serialized = serializeUnifiedCallRouting({
      forceOnelinkAuthority: true,
    });
    await store.dispatch('inboxes/updateInbox', {
      id: inbox.id,
      formData: false,
      channel: {
        provider_config: {
          ...inbox.provider_config,
          calling_enabled: true,
          call_routing: serialized,
        },
      },
    });
    return [];
  }

  if (!isVirtualPbxInbox(inbox) || state.readOnly) {
    return [];
  }

  const serialized = serializeUnifiedCallRouting({
    forceOnelinkAuthority: isWazoInbox(inbox, state),
  });
  const response = await VoiceAPI.updateVirtualPbxChannel(
    inbox.id,
    {
      expected_configuration_version: state.configurationVersion,
      routing: {
        mode: state.routingMode || 'operator',
        fallback_mode: state.fallbackMode || 'reject',
        operator_distribution_mode: primaryStrategy,
        max_call_duration_seconds: state.maxCallDurationSeconds || 1800,
        call_routing: serialized,
      },
    },
    { dryRun: false, remoteCommit: false }
  );
  const errors = response?.payload?.errors || [];
  if (errors.length) {
    return errors;
  }
  if (isWazoInbox(inbox, state) && state.remoteCommitAllowed) {
    await VoiceAPI.provisionVirtualPbxChannel(inbox.id, {
      remoteCommit: true,
      includeDiagnostics: false,
    });
  }
  await loadPhoneStatus(inbox);
  return [];
};

const saveUnifiedRouting = async () => {
  const targetInboxes = telephonyInboxes.value.filter(inbox =>
    selectedRoutingInboxIds.value.includes(Number(inbox.id))
  );
  if (!targetInboxes.length) return;

  isSavingUnifiedRouting.value = true;
  try {
    const primaryStrategy =
      callRoutingForm.inbound.groups?.[0]?.strategy === 'broadcast'
        ? 'broadcast'
        : 'targeted';

    const results = await Promise.all(
      targetInboxes.map(inbox =>
        saveRoutingForSingleInbox(inbox, primaryStrategy)
      )
    );
    const errors = results.flat();
    if (errors.length) {
      useAlert(
        errors.map(err => err.message || err.code).join('; ') ||
          t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE')
      );
      return;
    }

    useAlert(t('TELEPHONY_SETTINGS.SAVE_ROUTING_SUCCESS'));
  } catch (error) {
    useAlert(
      error?.response?.data?.message ||
        error?.response?.data?.error ||
        t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE')
    );
  } finally {
    isSavingUnifiedRouting.value = false;
  }
};

const addProfile = inboxId => {
  const state = ensurePhoneState(inboxId);
  state.profiles.push({
    clientId: nextClientId(),
    id: null,
    profileKind: 'human_operator',
    userId: '',
    userName: '',
    internalExtension: '',
    sipUsername: '',
    originalSipUsername: '',
    sipPassword: '',
    sipPasswordConfigured: false,
    enabled: true,
  });
};

const removeProfile = (inboxId, index) => {
  const state = ensurePhoneState(inboxId);
  state.profiles.splice(index, 1);
};

const validateProfiles = (inbox, state) => {
  const invalidProfile = state.profiles.find(
    profile =>
      !profile.userId || !String(profile.internalExtension || '').trim()
  );
  if (invalidProfile) {
    useAlert(t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.REQUIRED'));
    return false;
  }

  if (requiresSipCredentials(inbox, state)) {
    const invalidSip = state.profiles.find(profile => {
      const hasUsername = Boolean(profile.sipUsername?.trim());
      const hasPassword = Boolean(profile.sipPassword?.trim());
      const usernameChanged =
        (profile.sipUsername || '').trim() !==
        (profile.originalSipUsername || '').trim();

      if (!hasUsername) return hasPassword;
      if (hasPassword) return false;
      return !profile.sipPasswordConfigured || usernameChanged;
    });

    if (invalidSip) {
      useAlert(
        t(
          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.SIP_PAIR_REQUIRED'
        )
      );
      return false;
    }
  }

  return true;
};

const serializeProfiles = (inbox, state) => {
  const withSip = requiresSipCredentials(inbox, state);
  return state.profiles.map(profile => {
    const payload = {
      profile_kind: 'human_operator',
      user_id: Number(profile.userId),
      internal_extension: String(profile.internalExtension || '').trim(),
      enabled: profile.enabled !== false,
    };
    if (profile.id) {
      payload.id = profile.id;
    }
    if (withSip && profile.sipUsername?.trim()) {
      payload.sip_username = profile.sipUsername.trim();
    }
    if (withSip && profile.sipPassword?.trim()) {
      payload.sip_password = profile.sipPassword.trim();
    }
    return payload;
  });
};

const saveLines = async inbox => {
  const state = ensurePhoneState(inbox.id);
  if (state.readOnly) {
    useAlert(t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.READ_ONLY'));
    return;
  }
  if (!validateProfiles(inbox, state)) return;

  state.isSaving = true;
  try {
    const response = await VoiceAPI.updateVirtualPbxChannel(
      inbox.id,
      {
        expected_configuration_version: state.configurationVersion,
        profiles: serializeProfiles(inbox, state),
      },
      { dryRun: false, remoteCommit: false }
    );
    const errors = response?.payload?.errors || [];
    if (errors.length) {
      useAlert(
        errors.map(err => err.message || err.code).join('; ') ||
          t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE')
      );
      return;
    }

    if (isWazoInbox(inbox, state) && state.remoteCommitAllowed) {
      await VoiceAPI.provisionVirtualPbxChannel(inbox.id, {
        remoteCommit: true,
        includeDiagnostics: false,
      });
    }

    useAlert(t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.UPDATE_SUCCESS'));
    await loadPhoneStatus(inbox);
  } catch (error) {
    useAlert(
      error?.response?.data?.message ||
        error?.response?.data?.error ||
        t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE')
    );
  } finally {
    state.isSaving = false;
  }
};

watch(
  () => telephonyInboxes.value.map(inbox => inbox.id).join(','),
  () => {
    loadAllPhones();
  }
);

onMounted(async () => {
  isBootstrapping.value = true;
  try {
    await Promise.allSettled([
      store.dispatch('inboxes/get'),
      store.dispatch('agents/get'),
    ]);
    await loadAllPhones();
  } finally {
    isBootstrapping.value = false;
  }
});
</script>

<template>
  <SettingsLayout :is-loading="isBootstrapping && !telephonyInboxes.length">
    <template #header>
      <BaseSettingsHeader
        :title="$t('TELEPHONY_SETTINGS.TITLE')"
        :description="$t('TELEPHONY_SETTINGS.DESCRIPTION')"
        icon-name="call"
      />
    </template>

    <template #body>
      <div
        v-if="!telephonyInboxes.length"
        data-testid="telephony-empty-state"
        class="rounded-2xl border border-n-weak bg-n-solid-1 p-6 text-sm text-n-slate-11"
      >
        <p class="mb-1 font-medium text-n-slate-12">
          {{ $t('TELEPHONY_SETTINGS.EMPTY_TITLE') }}
        </p>
        <p class="mb-0">
          {{ $t('TELEPHONY_SETTINGS.EMPTY_DESCRIPTION') }}
        </p>
      </div>

      <div v-else class="flex flex-col gap-6">
        <div
          class="inline-flex self-start rounded-xl border border-n-weak bg-n-alpha-1 p-1"
          role="tablist"
        >
          <button
            type="button"
            data-testid="telephony-tab-routing"
            class="rounded-lg px-4 py-2 text-sm font-medium transition"
            :class="
              activeMainTab === 'routing'
                ? 'bg-n-solid-2 text-n-slate-12 shadow-sm'
                : 'text-n-slate-11'
            "
            @click="activeMainTab = 'routing'"
          >
            {{ $t('TELEPHONY_SETTINGS.TAB_ROUTING') }}
          </button>
          <button
            type="button"
            data-testid="telephony-tab-lines"
            class="rounded-lg px-4 py-2 text-sm font-medium transition"
            :class="
              activeMainTab === 'lines'
                ? 'bg-n-solid-2 text-n-slate-12 shadow-sm'
                : 'text-n-slate-11'
            "
            @click="activeMainTab = 'lines'"
          >
            {{ $t('TELEPHONY_SETTINGS.TAB_LINES') }}
          </button>
        </div>

        <section
          v-show="activeMainTab === 'routing'"
          data-testid="telephony-unified-routing"
          class="rounded-2xl border border-n-weak bg-n-solid-1 p-5 flex flex-col gap-5"
        >
          <div
            class="flex flex-col gap-3 border-b border-n-weak pb-4 md:flex-row md:items-center md:justify-between"
          >
            <div class="space-y-1">
              <h2 class="mb-0 text-base font-medium text-n-slate-12">
                {{ $t('TELEPHONY_SETTINGS.UNIFIED_ROUTING_TITLE') }}
              </h2>
              <p class="mb-0 text-sm text-n-slate-11">
                {{ $t('TELEPHONY_SETTINGS.UNIFIED_ROUTING_HINT') }}
              </p>
            </div>

            <div class="inline-flex rounded-lg bg-n-alpha-1 p-1" role="tablist">
              <button
                type="button"
                data-testid="telephony-routing-inbound-tab"
                class="rounded-md px-3 py-1.5 text-xs font-medium transition"
                :class="
                  callRoutingSubTab === 'inbound'
                    ? 'bg-n-solid-2 text-n-slate-12 shadow-sm'
                    : 'text-n-slate-11'
                "
                @click="callRoutingSubTab = 'inbound'"
              >
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.INBOUND_TAB'
                  )
                }}
              </button>
              <button
                type="button"
                data-testid="telephony-routing-outbound-tab"
                class="rounded-md px-3 py-1.5 text-xs font-medium transition"
                :class="
                  callRoutingSubTab === 'outbound'
                    ? 'bg-n-solid-2 text-n-slate-12 shadow-sm'
                    : 'text-n-slate-11'
                "
                @click="callRoutingSubTab = 'outbound'"
              >
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.OUTBOUND_TAB'
                  )
                }}
              </button>
            </div>
          </div>

          <div class="rounded-xl bg-n-alpha-1 p-3.5 space-y-2">
            <div class="text-xs font-medium text-n-slate-12">
              {{ $t('TELEPHONY_SETTINGS.APPLIED_PHONES_LABEL') }}
            </div>
            <div class="flex flex-wrap gap-2">
              <button
                v-for="inbox in telephonyInboxes"
                :key="inbox.id"
                type="button"
                data-testid="telephony-routing-phone-pill"
                class="inline-flex items-center gap-2 rounded-full border px-3 py-1 text-xs transition"
                :class="
                  selectedRoutingInboxIds.includes(Number(inbox.id))
                    ? 'border-n-brand bg-n-brand/10 font-medium text-n-brand'
                    : 'border-n-weak text-n-slate-11'
                "
                @click="toggleRoutingInboxSelection(inbox.id)"
              >
                <span>{{ inbox.name }}</span>
                <span
                  v-if="
                    phoneStates[inbox.id]?.displayPhoneNumber ||
                    inbox.phone_number
                  "
                  class="font-mono opacity-80"
                >
                  {{
                    phoneStates[inbox.id]?.displayPhoneNumber ||
                    inbox.phone_number
                  }}
                </span>
              </button>
            </div>
          </div>

          <div
            v-if="callRoutingSubTab === 'inbound'"
            data-testid="telephony-routing-inbound-panel"
            class="flex flex-col gap-4"
          >
            <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
              <label
                class="flex min-w-0 flex-col gap-1 text-sm text-n-slate-12"
              >
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.SCHEDULE.MODE_LABEL'
                  )
                }}
                <select
                  v-model="callRoutingForm.inbound.schedule_mode"
                  data-testid="telephony-routing-schedule-mode"
                  class="rounded-lg border border-n-weak py-2 text-sm"
                >
                  <option value="always">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.SCHEDULE.ALWAYS'
                      )
                    }}
                  </option>
                  <option value="business_hours">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.SCHEDULE.BUSINESS_HOURS'
                      )
                    }}
                  </option>
                </select>
              </label>

              <label
                v-if="
                  callRoutingForm.inbound.schedule_mode === 'business_hours'
                "
                class="flex min-w-0 flex-col gap-1 text-sm text-n-slate-12"
              >
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.SCHEDULE.OFF_HOURS_ACTION_LABEL'
                  )
                }}
                <select
                  v-model="callRoutingForm.inbound.off_hours_action"
                  data-testid="telephony-routing-off-hours-action"
                  class="rounded-lg border border-n-weak py-2 text-sm"
                >
                  <option value="reject">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ACTIONS.REJECT'
                      )
                    }}
                  </option>
                  <option value="ai">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ACTIONS.AI'
                      )
                    }}
                  </option>
                  <option value="forward">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ACTIONS.FORWARD'
                      )
                    }}
                  </option>
                </select>
              </label>

              <label
                v-if="
                  callRoutingForm.inbound.schedule_mode === 'business_hours' &&
                  callRoutingForm.inbound.off_hours_action === 'forward'
                "
                class="flex min-w-0 flex-col gap-1 text-sm text-n-slate-12 md:col-span-2"
              >
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.SCHEDULE.FORWARD_NUMBER_LABEL'
                  )
                }}
                <input
                  v-model="callRoutingForm.inbound.off_hours_forward_number"
                  data-testid="telephony-routing-off-hours-forward"
                  class="rounded-lg border border-n-weak py-2 text-sm"
                  type="text"
                  :placeholder="PHONE_NUMBER_EXAMPLE"
                />
              </label>
            </div>

            <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
              <label
                class="flex min-w-0 flex-col gap-1 text-sm text-n-slate-12"
              >
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WAITING.RING_TIMEOUT_LABEL'
                  )
                }}
                <input
                  v-model.number="callRoutingForm.inbound.ring_timeout_seconds"
                  data-testid="telephony-routing-ring-timeout"
                  class="rounded-lg border border-n-weak py-2 text-sm"
                  type="number"
                  min="5"
                  max="180"
                />
              </label>

              <label
                class="flex min-w-0 flex-col gap-1 text-sm text-n-slate-12"
              >
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WAITING.RINGTONE_LABEL'
                  )
                }}
                <select
                  v-model="callRoutingForm.inbound.ringtone"
                  data-testid="telephony-routing-ringtone"
                  class="rounded-lg border border-n-weak py-2 text-sm"
                >
                  <option value="default">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.RINGTONES.DEFAULT'
                      )
                    }}
                  </option>
                  <option value="classic">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.RINGTONES.CLASSIC'
                      )
                    }}
                  </option>
                  <option value="soft">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.RINGTONES.SOFT'
                      )
                    }}
                  </option>
                  <option value="urgent">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.RINGTONES.URGENT'
                      )
                    }}
                  </option>
                </select>
              </label>

              <label
                class="flex items-center gap-2 text-sm text-n-slate-12 md:col-span-2"
              >
                <input
                  v-model="callRoutingForm.inbound.skip_busy_operators"
                  data-testid="telephony-routing-skip-busy"
                  type="checkbox"
                />
                <span>
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WAITING.SKIP_BUSY_LABEL'
                    )
                  }}
                </span>
              </label>
            </div>

            <div class="rounded-xl bg-n-alpha-1 p-4 space-y-3">
              <div class="flex items-center justify-between">
                <h3 class="mb-0 text-xs font-semibold text-n-slate-12">
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUPS.TITLE'
                    )
                  }}
                </h3>
                <button
                  type="button"
                  data-testid="telephony-routing-add-group"
                  class="p-0 text-xs font-medium text-n-brand"
                  @click="addCallRoutingGroup"
                >
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUPS.ADD_GROUP'
                    )
                  }}
                </button>
              </div>

              <div class="flex flex-col gap-3">
                <div
                  v-for="(group, gIdx) in callRoutingForm.inbound.groups"
                  :key="group.id || gIdx"
                  data-testid="telephony-routing-group"
                  class="rounded-xl border border-n-weak bg-n-solid-1 p-3.5"
                >
                  <div class="mb-2 flex items-center justify-between">
                    <span class="text-xs font-medium text-n-slate-11">
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUPS.STEP_LABEL',
                          { index: gIdx + 1 }
                        )
                      }}
                    </span>
                    <button
                      v-if="callRoutingForm.inbound.groups.length > 1"
                      type="button"
                      data-testid="telephony-routing-remove-group"
                      class="p-0 text-xs text-n-ruby-10"
                      @click="removeCallRoutingGroup(gIdx)"
                    >
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUPS.REMOVE_GROUP'
                        )
                      }}
                    </button>
                  </div>

                  <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
                    <label
                      class="flex min-w-0 flex-col gap-1 text-sm text-n-slate-12 md:col-span-2"
                    >
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUPS.NAME_LABEL'
                        )
                      }}
                      <input
                        v-model="group.name"
                        data-testid="telephony-routing-group-name"
                        class="rounded-lg border border-n-weak py-1.5 text-sm"
                        type="text"
                        :placeholder="
                          $t(
                            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUPS.NAME_PLACEHOLDER'
                          )
                        "
                      />
                    </label>

                    <label
                      class="flex min-w-0 flex-col gap-1 text-sm text-n-slate-12"
                    >
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUPS.STRATEGY_LABEL'
                        )
                      }}
                      <select
                        v-model="group.strategy"
                        data-testid="telephony-routing-group-strategy"
                        class="rounded-lg border border-n-weak py-1.5 text-sm"
                      >
                        <option value="broadcast">
                          {{
                            $t(
                              'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUP_STRATEGIES.BROADCAST'
                            )
                          }}
                        </option>
                        <option value="least_recent">
                          {{
                            $t(
                              'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUP_STRATEGIES.LEAST_RECENT'
                            )
                          }}
                        </option>
                        <option value="round_robin">
                          {{
                            $t(
                              'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUP_STRATEGIES.ROUND_ROBIN'
                            )
                          }}
                        </option>
                      </select>
                    </label>

                    <label
                      class="flex min-w-0 flex-col gap-1 text-sm text-n-slate-12"
                    >
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUPS.RING_SECONDS_LABEL'
                        )
                      }}
                      <input
                        v-model.number="group.ring_seconds"
                        data-testid="telephony-routing-group-ring-seconds"
                        class="rounded-lg border border-n-weak py-1.5 text-sm"
                        type="number"
                        min="5"
                        max="120"
                      />
                    </label>
                  </div>

                  <div class="mt-3">
                    <div class="mb-1.5 text-xs text-n-slate-11">
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.GROUPS.OPERATORS_LABEL'
                        )
                      }}
                    </div>
                    <div class="flex flex-wrap gap-2">
                      <button
                        v-for="member in allEmployeeOptions"
                        :key="member.value"
                        type="button"
                        data-testid="telephony-routing-group-operator"
                        class="rounded-full border px-2.5 py-1 text-xs transition"
                        :class="
                          (group.user_ids || []).includes(member.value)
                            ? 'border-n-brand bg-n-brand/10 font-medium text-n-brand'
                            : 'border-n-weak text-n-slate-11'
                        "
                        @click="toggleCallRoutingGroupUser(group, member.value)"
                      >
                        {{ member.label }}
                      </button>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
              <label
                class="flex min-w-0 flex-col gap-1 text-sm text-n-slate-12"
              >
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.FALLBACK.ACTION_LABEL'
                  )
                }}
                <select
                  v-model="callRoutingForm.inbound.fallback_action"
                  data-testid="telephony-routing-fallback-action"
                  class="rounded-lg border border-n-weak py-2 text-sm"
                >
                  <option value="reject">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ACTIONS.REJECT'
                      )
                    }}
                  </option>
                  <option value="ai">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ACTIONS.AI'
                      )
                    }}
                  </option>
                  <option value="forward">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ACTIONS.FORWARD'
                      )
                    }}
                  </option>
                </select>
              </label>

              <label
                v-if="callRoutingForm.inbound.fallback_action === 'forward'"
                class="flex min-w-0 flex-col gap-1 text-sm text-n-slate-12"
              >
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.FALLBACK.FORWARD_NUMBER_LABEL'
                  )
                }}
                <input
                  v-model="callRoutingForm.inbound.fallback_forward_number"
                  data-testid="telephony-routing-fallback-forward"
                  class="rounded-lg border border-n-weak py-2 text-sm"
                  type="text"
                  :placeholder="PHONE_NUMBER_EXAMPLE"
                />
              </label>
            </div>

            <div class="rounded-xl bg-n-alpha-1 p-3.5 flex flex-col gap-3">
              <label class="flex items-center gap-2 text-sm text-n-slate-12">
                <input
                  v-model="callRoutingForm.inbound.whatsapp_followup.enabled"
                  data-testid="telephony-routing-whatsapp-followup-enabled"
                  type="checkbox"
                />
                <span>
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WHATSAPP_FOLLOWUP.ENABLED_LABEL'
                    )
                  }}
                </span>
              </label>

              <div
                v-if="callRoutingForm.inbound.whatsapp_followup.enabled"
                class="grid grid-cols-1 gap-3 md:grid-cols-2"
              >
                <label
                  class="flex min-w-0 flex-col gap-1 text-sm text-n-slate-12"
                >
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WHATSAPP_FOLLOWUP.INBOX_LABEL'
                    )
                  }}
                  <select
                    v-model="callRoutingForm.inbound.whatsapp_followup.inbox_id"
                    data-testid="telephony-routing-whatsapp-inbox"
                    class="rounded-lg border border-n-weak py-2 text-sm"
                  >
                    <option value="">
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WHATSAPP_FOLLOWUP.INBOX_PLACEHOLDER'
                        )
                      }}
                    </option>
                    <option
                      v-for="waInbox in whatsappFollowupInboxes"
                      :key="waInbox.id"
                      :value="waInbox.id"
                    >
                      {{ waInbox.name }}
                    </option>
                  </select>
                </label>

                <label
                  class="flex min-w-0 flex-col gap-1 text-sm text-n-slate-12"
                >
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WHATSAPP_FOLLOWUP.COOLDOWN_LABEL'
                    )
                  }}
                  <input
                    v-model.number="
                      callRoutingForm.inbound.whatsapp_followup.cooldown_minutes
                    "
                    data-testid="telephony-routing-whatsapp-cooldown"
                    class="rounded-lg border border-n-weak py-2 text-sm"
                    type="number"
                    min="5"
                    max="1440"
                  />
                </label>

                <label
                  v-if="isSelectedWhatsappFollowupOfficial"
                  class="flex min-w-0 flex-col gap-1 text-sm text-n-slate-12 md:col-span-2"
                >
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WHATSAPP_FOLLOWUP.TEMPLATE_LABEL'
                    )
                  }}
                  <select
                    v-model="
                      callRoutingForm.inbound.whatsapp_followup.template_name
                    "
                    data-testid="telephony-routing-whatsapp-template"
                    class="rounded-lg border border-n-weak py-2 text-sm"
                  >
                    <option value="">
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WHATSAPP_FOLLOWUP.TEMPLATE_PLACEHOLDER'
                        )
                      }}
                    </option>
                    <option
                      v-for="tpl in selectedWhatsappFollowupTemplates"
                      :key="`${tpl.name}:${tpl.language || 'ru'}`"
                      :value="tpl.name"
                    >
                      {{ tpl.name }} ({{ tpl.language || 'ru' }})
                    </option>
                  </select>
                </label>

                <label
                  v-else-if="selectedWhatsappFollowupInbox"
                  class="flex min-w-0 flex-col gap-1 text-sm text-n-slate-12 md:col-span-2"
                >
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WHATSAPP_FOLLOWUP.CUSTOM_MESSAGE_LABEL'
                    )
                  }}
                  <input
                    v-model="
                      callRoutingForm.inbound.whatsapp_followup.custom_message
                    "
                    data-testid="telephony-routing-whatsapp-custom-message"
                    class="rounded-lg border border-n-weak py-2 text-sm"
                    type="text"
                    :placeholder="
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.WHATSAPP_FOLLOWUP.CUSTOM_MESSAGE_PLACEHOLDER'
                      )
                    "
                  />
                </label>
              </div>

              <label class="flex items-center gap-2 text-sm text-n-slate-12">
                <input
                  v-model="callRoutingForm.show_extended_call_card"
                  data-testid="telephony-routing-extended-card"
                  type="checkbox"
                />
                <span>
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.CALL_CARD.SHOW_EXTENDED_LABEL'
                    )
                  }}
                </span>
              </label>
            </div>
          </div>

          <div
            v-else
            data-testid="telephony-routing-outbound-panel"
            class="flex flex-col gap-4"
          >
            <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
              <label
                class="flex min-w-0 flex-col gap-1 text-sm text-n-slate-12"
              >
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.OUTBOUND.ACCESS_MODE_LABEL'
                  )
                }}
                <select
                  v-model="callRoutingForm.outbound.access_mode"
                  data-testid="telephony-routing-outbound-access-mode"
                  class="rounded-lg border border-n-weak py-2 text-sm"
                >
                  <option value="all_members">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.OUTBOUND.ALL_MEMBERS'
                      )
                    }}
                  </option>
                  <option value="selected_operators">
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.OUTBOUND.SELECTED_OPERATORS'
                      )
                    }}
                  </option>
                </select>
              </label>
            </div>

            <div
              v-if="
                callRoutingForm.outbound.access_mode === 'selected_operators'
              "
              class="rounded-xl bg-n-alpha-1 p-3.5"
            >
              <div class="mb-1.5 text-xs text-n-slate-11">
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.OUTBOUND.ALLOWED_OPERATORS_LABEL'
                  )
                }}
              </div>
              <div class="flex flex-wrap gap-2">
                <button
                  v-for="member in allEmployeeOptions"
                  :key="member.value"
                  type="button"
                  data-testid="telephony-routing-outbound-operator"
                  class="rounded-full border px-2.5 py-1 text-xs transition"
                  :class="
                    callRoutingForm.outbound.allowed_user_ids.includes(
                      member.value
                    )
                      ? 'border-n-brand bg-n-brand/10 font-medium text-n-brand'
                      : 'border-n-weak text-n-slate-11'
                  "
                  @click="toggleCallRoutingOutboundUser(member.value)"
                >
                  {{ member.label }}
                </button>
              </div>
            </div>
          </div>

          <div class="flex items-center gap-3 pt-1">
            <Button
              type="button"
              data-testid="telephony-save-routing"
              size="sm"
              :is-loading="isSavingUnifiedRouting"
              :label="$t('TELEPHONY_SETTINGS.SAVE_ROUTING_BUTTON')"
              @click="saveUnifiedRouting"
            />
          </div>
        </section>

        <div
          v-show="activeMainTab === 'lines'"
          data-testid="telephony-lines-section"
          class="flex flex-col gap-6"
        >
          <section
            v-for="inbox in voiceInboxes"
            :key="inbox.id"
            data-testid="telephony-phone-card"
            class="rounded-2xl border border-n-weak bg-n-solid-1 p-5 flex flex-col gap-4"
          >
            <div
              class="flex flex-col gap-1 border-b border-n-weak pb-3 sm:flex-row sm:items-center sm:justify-between"
            >
              <div>
                <h2 class="mb-0 text-base font-medium text-n-slate-12">
                  {{ inbox.name }}
                </h2>
                <p
                  v-if="
                    phoneStates[inbox.id]?.displayPhoneNumber ||
                    inbox.phone_number
                  "
                  class="mb-0 font-mono text-sm text-n-slate-11"
                >
                  {{
                    phoneStates[inbox.id]?.displayPhoneNumber ||
                    inbox.phone_number
                  }}
                </p>
              </div>
            </div>

            <div
              v-if="!isVirtualPbxInbox(inbox)"
              class="text-sm text-n-slate-11"
            >
              {{ $t('TELEPHONY_SETTINGS.NO_EMPLOYEE_LINES_NEEDED') }}
            </div>

            <div
              v-else-if="phoneStates[inbox.id]?.isLoading"
              class="text-sm text-n-slate-11"
            >
              {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.LOADING') }}
            </div>

            <div
              v-else-if="phoneStates[inbox.id]?.loadError"
              class="rounded-xl border border-n-ruby-4 bg-n-ruby-2/40 p-4 text-sm text-n-ruby-11"
            >
              {{ phoneStates[inbox.id].loadError }}
            </div>

            <form
              v-else
              class="flex flex-col gap-4"
              @submit.prevent="saveLines(inbox)"
            >
              <div class="space-y-1">
                <h3 class="mb-0 text-sm font-medium text-n-slate-12">
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.TITLE'
                    )
                  }}
                </h3>
                <p class="mb-0 text-sm text-n-slate-11">
                  {{ $t('TELEPHONY_SETTINGS.LINES_HINT') }}
                </p>
              </div>

              <div
                v-if="!(phoneStates[inbox.id]?.profiles || []).length"
                data-testid="telephony-no-lines"
                class="rounded-xl bg-n-alpha-1 px-4 py-3 text-sm text-n-slate-11"
              >
                {{ $t('TELEPHONY_SETTINGS.NO_LINES_ASSIGNED') }}
              </div>

              <div
                v-else
                class="flex flex-col divide-y divide-n-weak rounded-xl border border-n-weak px-4"
              >
                <div
                  v-for="(profile, index) in phoneStates[inbox.id].profiles"
                  :key="profile.clientId"
                  data-testid="telephony-profile-row"
                  class="grid grid-cols-1 gap-3 py-4 md:grid-cols-2"
                >
                  <label
                    class="flex min-w-0 flex-col gap-1 text-sm text-n-slate-12"
                  >
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.EMPLOYEE_LABEL'
                      )
                    }}
                    <select
                      v-model.number="profile.userId"
                      data-testid="telephony-profile-employee"
                      class="rounded-lg border border-n-weak py-2 text-sm"
                      :disabled="phoneStates[inbox.id]?.readOnly"
                    >
                      <option value="">
                        {{
                          $t(
                            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.EMPLOYEE_PLACEHOLDER'
                          )
                        }}
                      </option>
                      <option
                        v-for="member in getEmployeeOptions(
                          inbox,
                          phoneStates[inbox.id]
                        )"
                        :key="member.value"
                        :value="member.value"
                      >
                        {{ member.label }}
                      </option>
                    </select>
                  </label>

                  <label
                    class="flex min-w-0 flex-col gap-1 text-sm text-n-slate-12"
                  >
                    {{
                      $t(
                        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_EXTENSION.LABEL'
                      )
                    }}
                    <input
                      v-model="profile.internalExtension"
                      data-testid="telephony-profile-extension"
                      class="rounded-lg border border-n-weak py-2 text-sm"
                      :disabled="phoneStates[inbox.id]?.readOnly"
                      type="text"
                      :placeholder="
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_EXTENSION.PLACEHOLDER'
                        )
                      "
                    />
                  </label>

                  <template
                    v-if="requiresSipCredentials(inbox, phoneStates[inbox.id])"
                  >
                    <label
                      class="flex min-w-0 flex-col gap-1 text-sm text-n-slate-12"
                    >
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_USERNAME.LABEL'
                        )
                      }}
                      <input
                        v-model="profile.sipUsername"
                        data-testid="telephony-profile-sip-username"
                        class="rounded-lg border border-n-weak py-2 text-sm"
                        :disabled="phoneStates[inbox.id]?.readOnly"
                        type="text"
                        :placeholder="
                          $t(
                            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_USERNAME.PLACEHOLDER'
                          )
                        "
                      />
                    </label>

                    <label
                      class="flex min-w-0 flex-col gap-1 text-sm text-n-slate-12"
                    >
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_PASSWORD.LABEL'
                        )
                      }}
                      <input
                        v-model="profile.sipPassword"
                        data-testid="telephony-profile-sip-password"
                        class="rounded-lg border border-n-weak py-2 text-sm"
                        :disabled="phoneStates[inbox.id]?.readOnly"
                        type="password"
                        autocomplete="new-password"
                        :placeholder="
                          profile.sipPasswordConfigured
                            ? '********'
                            : $t(
                                'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_PASSWORD.PLACEHOLDER'
                              )
                        "
                      />
                    </label>
                  </template>

                  <div class="md:col-span-2">
                    <button
                      type="button"
                      data-testid="telephony-remove-profile"
                      class="p-0 text-sm text-n-ruby-10"
                      :disabled="phoneStates[inbox.id]?.readOnly"
                      @click="removeProfile(inbox.id, index)"
                    >
                      {{
                        $t(
                          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.REMOVE'
                        )
                      }}
                    </button>
                  </div>
                </div>
              </div>

              <div class="flex flex-wrap items-center gap-3">
                <Button
                  type="button"
                  data-testid="telephony-add-profile"
                  variant="outline"
                  color="slate"
                  size="sm"
                  :disabled="phoneStates[inbox.id]?.readOnly"
                  :label="
                    $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.ADD')
                  "
                  @click="addProfile(inbox.id)"
                />
                <Button
                  type="submit"
                  data-testid="telephony-save-lines"
                  size="sm"
                  :disabled="phoneStates[inbox.id]?.readOnly"
                  :is-loading="phoneStates[inbox.id]?.isSaving"
                  :label="$t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.UPDATE_BUTTON')"
                />
              </div>
            </form>
          </section>
        </div>
      </div>
    </template>
  </SettingsLayout>
</template>
