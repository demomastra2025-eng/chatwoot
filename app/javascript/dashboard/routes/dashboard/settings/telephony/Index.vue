<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import VoiceAPI from 'dashboard/api/channel/voice/voiceAPIClient';
import InboxMembersAPI from 'dashboard/api/inboxMembers';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import { VIRTUAL_PBX_PROVIDERS } from '../inbox/helpers/virtualPbx';
import Button from 'dashboard/components-next/button/Button.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';

const { t } = useI18n();
const store = useStore();

const inboxes = useMapGetter('inboxes/getInboxes');
const agents = useMapGetter('agents/getAgents');

const isBootstrapping = ref(false);
const phoneStates = reactive({});
let profileClientIdCounter = 0;

const nextClientId = () => {
  profileClientIdCounter += 1;
  return `telephony-profile-${profileClientIdCounter}`;
};

const voiceInboxes = computed(() =>
  (inboxes.value || []).filter(
    inbox => inbox?.channel_type === INBOX_TYPES.VOICE
  )
);

const isVirtualPbxInbox = inbox =>
  VIRTUAL_PBX_PROVIDERS.includes(
    String(
      inbox?.provider || inbox?.provider_config?.provider_kind || ''
    ).toLowerCase()
  );

const getProviderKind = (inbox, phoneState) =>
  String(
    phoneState?.providerKind ||
      inbox?.provider ||
      inbox?.provider_config?.provider_kind ||
      ''
  ).toLowerCase();

const isWazoInbox = (inbox, phoneState) =>
  getProviderKind(inbox, phoneState) === 'wazo';

const requiresSipCredentials = (inbox, phoneState) =>
  isVirtualPbxInbox(inbox) && !isWazoInbox(inbox, phoneState);

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
      members: [],
      profiles: [],
    };
  }
  return phoneStates[inboxId];
};

const mapServerProfile = profile => ({
  clientId: nextClientId(),
  id: profile.id || null,
  profileKind: profile.profile_kind || 'human_operator',
  userId: profile.user_id ? Number(profile.user_id) : '',
  userName: profile.user_name || '',
  internalExtension: String(profile.internal_extension || ''),
  sipUsername: String(profile.sip_username || ''),
  originalSipUsername: String(profile.sip_username || ''),
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

const loadPhoneStatus = async inbox => {
  if (!inbox?.id || !isVirtualPbxInbox(inbox)) return;
  const state = ensurePhoneState(inbox.id);
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
    state.members = membersResponse?.data?.payload || [];
    const serverProfiles = uiConfig.employees || uiConfig.profiles || [];
    state.profiles = serverProfiles
      .filter(profile => profile?.profile_kind !== 'voice_agent')
      .map(mapServerProfile);
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
  await Promise.all(voiceInboxes.value.map(inbox => loadPhoneStatus(inbox)));
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
  () => voiceInboxes.value.map(inbox => inbox.id).join(','),
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
  <SettingsLayout :is-loading="isBootstrapping && !voiceInboxes.length">
    <template #header>
      <BaseSettingsHeader
        :title="$t('TELEPHONY_SETTINGS.TITLE')"
        :description="$t('TELEPHONY_SETTINGS.DESCRIPTION')"
        icon-name="call"
      />
    </template>

    <template #body>
      <div
        v-if="!voiceInboxes.length"
        data-testid="telephony-empty-state"
        class="rounded-2xl border border-n-weak bg-n-solid-2 p-8 text-center"
      >
        <p class="mb-1 text-base font-medium text-n-slate-12">
          {{ $t('TELEPHONY_SETTINGS.EMPTY_TITLE') }}
        </p>
        <p class="mb-0 text-sm text-n-slate-11">
          {{ $t('TELEPHONY_SETTINGS.EMPTY_DESCRIPTION') }}
        </p>
      </div>

      <div v-else class="flex flex-col gap-6 pb-12">
        <section
          v-for="inbox in voiceInboxes"
          :key="inbox.id"
          data-testid="telephony-phone-card"
          class="rounded-2xl border border-n-weak bg-n-solid-2 p-5"
        >
          <div
            class="mb-4 flex flex-wrap items-center justify-between gap-3 border-b border-n-weak pb-4"
          >
            <div class="min-w-0 space-y-1">
              <div class="flex flex-wrap items-center gap-2">
                <h2 class="mb-0 text-base font-semibold text-n-slate-12">
                  {{ inbox.name }}
                </h2>
                <span
                  v-if="phoneStates[inbox.id]?.providerLabel || inbox.provider"
                  class="rounded-full bg-n-alpha-2 px-2.5 py-0.5 text-xs font-medium text-n-slate-11"
                >
                  {{ phoneStates[inbox.id]?.providerLabel || inbox.provider }}
                </span>
              </div>
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

          <div v-if="!isVirtualPbxInbox(inbox)" class="text-sm text-n-slate-11">
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
                  $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.TITLE')
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
    </template>
  </SettingsLayout>
</template>
