<script>
/* eslint no-console: 0 */
import { mapGetters } from 'vuex';
import { useAlert } from 'dashboard/composables';

import InboxMembersAPI from '../../../../api/inboxMembers';
import VoiceAPI from 'dashboard/api/channel/voice/voiceAPIClient';
import NextButton from 'dashboard/components-next/button/Button.vue';
import TagInput from 'dashboard/components-next/taginput/TagInput.vue';
import router from '../../../index';
import PageHeader from '../SettingsSubPageHeader.vue';
import { useVuelidate } from '@vuelidate/core';
import { getInboxFlowRouteName } from './helpers/inboxFlowRoutes';

export default {
  components: {
    PageHeader,
    NextButton,
    TagInput,
  },
  validations: {
    selectedAgentIds: {
      isEmpty() {
        return !!this.selectedAgentIds.length;
      },
    },
  },
  setup() {
    return { v$: useVuelidate() };
  },
  data() {
    return {
      selectedAgentIds: [],
      virtualPbxStatusPayload: null,
      virtualPbxProfiles: {},
      isCreating: false,
      isLoadingVirtualPbx: false,
    };
  },
  computed: {
    ...mapGetters({
      agentList: 'agents/getAgents',
    }),
    selectedAgents() {
      const agentsById = new Map(
        this.agentList.map(agent => [Number(agent.id), agent])
      );

      return this.selectedAgentIds
        .map(id => {
          const numericId = Number(id);
          const agent = agentsById.get(numericId);
          return {
            id: numericId,
            name:
              agent?.name ||
              agent?.available_name ||
              agent?.email ||
              `#${numericId}`,
          };
        })
        .filter(agent => agent.id);
    },
    selectedAgentNames() {
      return this.selectedAgents.map(agent => agent.name);
    },
    selectedVirtualPbxAgents() {
      return this.selectedAgents.filter(
        agent => this.virtualPbxProfiles[agent.id]
      );
    },
    agentMenuItems() {
      return this.agentList
        .filter(({ id }) => !this.selectedAgentIds.includes(id))
        .map(({ id, name, thumbnail, avatar_url }) => ({
          label: name,
          value: id,
          action: 'select',
          thumbnail: { name, src: thumbnail || avatar_url || '' },
        }));
    },
    virtualPbxConfig() {
      return (
        this.virtualPbxStatusPayload?.ui_config ||
        this.virtualPbxStatusPayload?.config ||
        null
      );
    },
    virtualPbxProviderKind() {
      return (
        this.virtualPbxConfig?.channel?.provider_kind ||
        this.virtualPbxConfig?.connection?.provider_kind ||
        this.virtualPbxStatusPayload?.provider_kind ||
        ''
      );
    },
    isVirtualPbxProfileAssignmentInbox() {
      return ['sipuni', 'asterisk_analog'].includes(
        this.virtualPbxProviderKind
      );
    },
    isVirtualPbxSipCredentialsVisible() {
      return this.virtualPbxProviderKind === 'sipuni';
    },
    submitButtonLabel() {
      if (this.isVirtualPbxProfileAssignmentInbox) {
        return this.$t('INBOX_MGMT.AGENTS.SAVE_BUTTON_TEXT');
      }

      return this.$t('INBOX_MGMT.AGENTS.BUTTON_TEXT');
    },
  },
  watch: {
    selectedAgentIds() {
      this.ensureVirtualPbxProfilesForSelectedAgents();
    },
  },
  async mounted() {
    this.$store.dispatch('agents/get');
    await Promise.all([this.loadInboxMembers(), this.loadVirtualPbxStatus()]);
    this.ensureVirtualPbxProfilesForSelectedAgents();
  },
  methods: {
    handleAgentAdd({ value }) {
      if (!this.selectedAgentIds.includes(value)) {
        this.selectedAgentIds.push(value);
      }
      this.ensureVirtualPbxProfile(value);
    },
    handleAgentRemove(index) {
      this.selectedAgentIds.splice(index, 1);
    },
    normalizeMembers(members) {
      return (members || [])
        .map(member => Number(member.id || member.user_id))
        .filter(id => id);
    },
    async loadInboxMembers() {
      try {
        const response = await InboxMembersAPI.show(
          this.$route.params.inbox_id
        );
        this.selectedAgentIds = this.normalizeMembers(
          response?.data?.payload || response?.payload || []
        );
      } catch {
        this.selectedAgentIds = [];
      }
    },
    async loadVirtualPbxStatus() {
      this.isLoadingVirtualPbx = true;
      try {
        const response = await VoiceAPI.getVirtualPbxStatus(
          this.$route.params.inbox_id
        );
        this.virtualPbxStatusPayload = response?.payload || null;
        this.prefillVirtualPbxProfiles();
      } catch {
        this.virtualPbxStatusPayload = null;
      } finally {
        this.isLoadingVirtualPbx = false;
      }
    },
    prefillVirtualPbxProfiles() {
      const profiles =
        this.virtualPbxConfig?.employees ||
        this.virtualPbxConfig?.profiles ||
        [];

      profiles.forEach(profile => {
        const userId = Number(profile.user_id);
        if (!userId) return;

        this.virtualPbxProfiles[userId] = {
          userId,
          internalExtension: profile.internal_extension || '',
          sipUsername: profile.sip_username || '',
          originalSipUsername: profile.sip_username || '',
          sipPassword: '',
          sipPasswordConfigured: !!(
            profile.sip_password_configured || profile.access_configured
          ),
          enabled: profile.enabled !== false,
        };
      });
    },
    ensureVirtualPbxProfile(userId) {
      const numericId = Number(userId);
      if (!numericId || this.virtualPbxProfiles[numericId]) return;

      this.virtualPbxProfiles[numericId] = {
        userId: numericId,
        internalExtension: '',
        sipUsername: '',
        originalSipUsername: '',
        sipPassword: '',
        sipPasswordConfigured: false,
        enabled: true,
      };
    },
    ensureVirtualPbxProfilesForSelectedAgents() {
      this.selectedAgentIds.forEach(id => this.ensureVirtualPbxProfile(id));
    },
    profileHasAnySipAssignment(profile) {
      return [
        profile.internalExtension,
        profile.sipUsername,
        profile.sipPassword,
      ].some(value => String(value || '').trim());
    },
    profilePasswordPlaceholder(profile) {
      if (profile.sipPasswordConfigured) return '********';

      return this.$t(
        'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_PASSWORD.PLACEHOLDER'
      );
    },
    validateVirtualPbxProfiles() {
      if (!this.isVirtualPbxProfileAssignmentInbox) return true;

      const profiles = this.selectedVirtualPbxAgents.map(
        agent => this.virtualPbxProfiles[Number(agent.id)]
      );
      const invalidExtension = profiles.find(profile => {
        return !profile || !profile.internalExtension?.trim();
      });
      if (invalidExtension) {
        useAlert(
          this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.INTERNAL_EXTENSION.REQUIRED'
          )
        );
        return false;
      }

      if (!this.isVirtualPbxSipCredentialsVisible) return true;

      const invalidCredentials = profiles.find(profile => {
        if (!profile || !this.profileHasAnySipAssignment(profile)) return false;

        const hasUsername = !!profile.sipUsername?.trim();
        const hasPassword = !!profile.sipPassword?.trim();
        const usernameChanged =
          (profile.sipUsername || '').trim() !==
          (profile.originalSipUsername || '').trim();

        if (!hasUsername) return hasPassword;
        if (hasPassword) return false;

        return !profile.sipPasswordConfigured || usernameChanged;
      });
      if (invalidCredentials) {
        useAlert(
          this.$t(
            'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.SIP_PAIR_REQUIRED'
          )
        );
        return false;
      }

      return true;
    },
    virtualPbxProfilesPayload() {
      return this.selectedAgentIds
        .map(id => this.virtualPbxProfiles[Number(id)])
        .filter(profile => profile && this.profileHasAnySipAssignment(profile))
        .map(profile => {
          const payload = {
            user_id: profile.userId,
            internal_extension: profile.internalExtension.trim(),
            enabled: profile.enabled !== false,
          };
          const sipUsername = profile.sipUsername?.trim();
          const sipPassword = profile.sipPassword?.trim();
          if (this.isVirtualPbxSipCredentialsVisible && sipUsername) {
            payload.sip_username = sipUsername;
          }
          if (this.isVirtualPbxSipCredentialsVisible && sipPassword) {
            payload.sip_password = sipPassword;
          }
          return payload;
        });
    },
    formatVirtualPbxErrors(errors) {
      return errors.map(error => error.message || error.code).join(', ');
    },
    async updateVirtualPbxProfiles(inboxId) {
      const response = await VoiceAPI.updateVirtualPbxChannel(
        inboxId,
        {
          profiles: this.virtualPbxProfilesPayload(),
          metadata: {
            source: 'virtual_pbx_agents_step',
          },
        },
        { dryRun: false, remoteCommit: true }
      );
      const errors = response?.payload?.errors || [];
      if (errors.length) throw new Error(this.formatVirtualPbxErrors(errors));

      await this.loadVirtualPbxStatus();
    },
    finishRoute() {
      return {
        name: getInboxFlowRouteName(this.$route, 'finish'),
        params: {
          accountId: this.$route.params.accountId,
          inbox_id: this.$route.params.inbox_id,
        },
        query: this.$route.query,
      };
    },
    async addAgents() {
      const isValid = await this.v$.$validate();
      if (!isValid || !this.validateVirtualPbxProfiles()) return;

      this.isCreating = true;
      const inboxId = this.$route.params.inbox_id;

      try {
        await InboxMembersAPI.update({
          inboxId,
          agentList: this.selectedAgentIds,
        });
        if (this.isVirtualPbxProfileAssignmentInbox) {
          await this.updateVirtualPbxProfiles(inboxId);
          useAlert(this.$t('INBOX_MGMT.AGENTS.SAVE_SUCCESS'));
        }

        await (this.$router || router).replace(this.finishRoute());
      } catch (error) {
        useAlert(error.message);
      } finally {
        this.isCreating = false;
      }
    },
  },
};
</script>

<template>
  <div class="h-full w-full p-6 col-span-6">
    <form class="flex flex-wrap flex-col mx-0" @submit.prevent="addAgents()">
      <div class="w-full">
        <PageHeader :header-title="$t('INBOX_MGMT.ADD.AGENTS.TITLE')">
          <template #content>
            <div class="text-sm w-full text-n-slate-11 space-y-2">
              <p>{{ $t('INBOX_MGMT.ADD.AGENTS.DESC') }}</p>
              <p>
                <strong>{{
                  $t('INBOX_MGMT.ADD.AGENTS.ADMIN_NOTE_LABEL')
                }}</strong>
                {{ ' ' }}
                {{ $t('INBOX_MGMT.ADD.AGENTS.ADMIN_NOTE') }}
              </p>
            </div>
          </template>
        </PageHeader>
      </div>
      <div>
        <div class="w-full mb-4">
          <label :class="{ error: v$.selectedAgentIds.$error }">
            {{ $t('INBOX_MGMT.ADD.AGENTS.TITLE') }}
            <div
              class="rounded-xl outline outline-1 -outline-offset-1 outline-n-weak hover:outline-n-strong px-2 py-2"
            >
              <TagInput
                :model-value="selectedAgentNames"
                :placeholder="$t('INBOX_MGMT.ADD.AGENTS.PICK_AGENTS')"
                :menu-items="agentMenuItems"
                show-dropdown
                skip-label-dedup
                @add="handleAgentAdd"
                @remove="handleAgentRemove"
              />
            </div>
            <span v-if="v$.selectedAgentIds.$error" class="message">
              {{ $t('INBOX_MGMT.ADD.AGENTS.VALIDATION_ERROR') }}
            </span>
          </label>
        </div>

        <div
          v-if="
            isVirtualPbxProfileAssignmentInbox &&
            selectedVirtualPbxAgents.length
          "
          class="w-full mb-4 rounded-xl border border-n-weak p-4"
        >
          <div class="mb-3 space-y-1">
            <h3 class="text-sm font-medium text-n-slate-12">
              {{
                $t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.TITLE')
              }}
            </h3>
            <p class="text-sm text-n-slate-11">
              {{
                $t(
                  'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.CREATE_HINT'
                )
              }}
            </p>
          </div>

          <div class="flex flex-col gap-3">
            <div
              v-for="agent in selectedVirtualPbxAgents"
              :key="agent.id"
              class="grid grid-cols-1 gap-3 rounded-lg border border-n-weak p-3 md:grid-cols-4"
            >
              <div class="flex flex-col gap-1 text-sm text-n-slate-12">
                <span class="font-medium">
                  {{
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.EMPLOYEE_LABEL'
                    )
                  }}
                </span>
                <span class="min-h-[38px] rounded-lg bg-n-slate-2 px-3 py-2">
                  {{ agent.name }}
                </span>
              </div>

              <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.INTERNAL_EXTENSION.LABEL'
                  )
                }}
                <input
                  v-model="virtualPbxProfiles[agent.id].internalExtension"
                  class="rounded-lg border border-n-weak px-3 py-2 text-sm"
                  :disabled="isCreating || isLoadingVirtualPbx"
                  type="text"
                  :placeholder="
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.INTERNAL_EXTENSION.PLACEHOLDER'
                    )
                  "
                />
              </label>

              <label
                v-if="isVirtualPbxSipCredentialsVisible"
                class="flex flex-col gap-1 text-sm text-n-slate-12"
              >
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_USERNAME.LABEL'
                  )
                }}
                <input
                  v-model="virtualPbxProfiles[agent.id].sipUsername"
                  class="rounded-lg border border-n-weak px-3 py-2 text-sm"
                  :disabled="isCreating || isLoadingVirtualPbx"
                  type="text"
                  :placeholder="
                    $t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_USERNAME.PLACEHOLDER'
                    )
                  "
                />
              </label>

              <label
                v-if="isVirtualPbxSipCredentialsVisible"
                class="flex flex-col gap-1 text-sm text-n-slate-12"
              >
                {{
                  $t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_PASSWORD.LABEL'
                  )
                }}
                <input
                  v-model="virtualPbxProfiles[agent.id].sipPassword"
                  class="rounded-lg border border-n-weak px-3 py-2 text-sm"
                  :disabled="isCreating || isLoadingVirtualPbx"
                  type="password"
                  autocomplete="new-password"
                  :placeholder="
                    profilePasswordPlaceholder(virtualPbxProfiles[agent.id])
                  "
                />
              </label>
            </div>
          </div>
        </div>

        <div class="w-full">
          <NextButton
            type="submit"
            :is-loading="isCreating"
            solid
            blue
            :label="submitButtonLabel"
          />
        </div>
      </div>
    </form>
  </div>
</template>
