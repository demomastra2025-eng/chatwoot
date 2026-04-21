<script>
import { mapGetters } from 'vuex';
import { useAlert } from 'dashboard/composables';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import {
  CRM_DEAL_MANAGE_PERMISSION,
  CRM_TASK_MANAGE_PERMISSION,
} from 'dashboard/constants/permissions';
import { hasPermissions } from 'dashboard/helper/permissionsHelper';
import { dynamicTime } from 'shared/helpers/timeHelper';
import { useAdmin } from 'dashboard/composables/useAdmin';
import ContactInfoRow from './ContactInfoRow.vue';
import ContactIdentitySources from './ContactIdentitySources.vue';
import Avatar from 'next/avatar/Avatar.vue';
import SocialIcons from './SocialIcons.vue';
import EditContact from './EditContact.vue';
import ContactChannelLabels from 'dashboard/components-next/Contacts/ContactChannelLabels.vue';
import ContactMergeModal from 'dashboard/modules/contact/ContactMergeModal.vue';
import ComposeConversation from 'dashboard/components-next/NewConversation/ComposeConversation.vue';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import NextButton from 'dashboard/components-next/button/Button.vue';
import VoiceCallButton from 'dashboard/components-next/Contacts/VoiceCallButton.vue';

import {
  isAConversationRoute,
  isAInboxViewRoute,
  getConversationDashboardRoute,
} from '../../../../helper/routeHelpers';
import { emitter } from 'shared/helpers/mitt';

export default {
  components: {
    NextButton,
    ContactInfoRow,
    ContactIdentitySources,
    EditContact,
    Avatar,
    ComposeConversation,
    SocialIcons,
    ContactChannelLabels,
    ContactMergeModal,
    VoiceCallButton,
  },
  props: {
    contact: {
      type: Object,
      default: () => ({}),
    },
    showAvatar: {
      type: Boolean,
      default: true,
    },
  },
  emits: ['panelClose'],
  setup() {
    const { isAdmin } = useAdmin();
    const { updateUISettings } = useUISettings();
    return {
      isAdmin,
      updateUISettings,
    };
  },
  data() {
    return {
      showEditModal: false,
      showDeleteModal: false,
    };
  },
  computed: {
    ...mapGetters({
      currentAccountId: 'getCurrentAccountId',
      currentUser: 'getCurrentUser',
      isFeatureEnabledonAccount: 'accounts/isFeatureEnabledonAccount',
      uiFlags: 'contacts/getUIFlags',
    }),
    contactProfileLink() {
      return `/app/accounts/${this.$route.params.accountId}/contacts/${this.contact.id}`;
    },
    currentAccountPermissions() {
      const currentAccount = this.currentUser.accounts.find(
        account => Number(account.id) === Number(this.currentAccountId)
      );
      return currentAccount?.permissions || [];
    },
    canCreateCrmDeal() {
      return (
        this.isFeatureEnabledonAccount(
          this.currentAccountId,
          FEATURE_FLAGS.CRM_DEALS
        ) &&
        hasPermissions(
          ['administrator', CRM_DEAL_MANAGE_PERMISSION],
          this.currentAccountPermissions
        )
      );
    },
    canCreateCrmTask() {
      return (
        this.isFeatureEnabledonAccount(
          this.currentAccountId,
          FEATURE_FLAGS.CRM_TASKS
        ) &&
        hasPermissions(
          ['administrator', CRM_TASK_MANAGE_PERMISSION],
          this.currentAccountPermissions
        )
      );
    },
    canCreateSchedulingAppointment() {
      return this.isFeatureEnabledonAccount(
        this.currentAccountId,
        FEATURE_FLAGS.SCHEDULING
      );
    },
    additionalAttributes() {
      return this.contact.additional_attributes || {};
    },
    primaryNameSource() {
      return this.contact.primary_name_source || this.contact.primaryNameSource;
    },
    primaryAvatarSource() {
      return (
        this.contact.primary_avatar_source || this.contact.primaryAvatarSource
      );
    },
    primaryNameSourceLabel() {
      return this.displaySourceLabel(this.primaryNameSource);
    },
    primaryAvatarSourceLabel() {
      return this.displaySourceLabel(this.primaryAvatarSource);
    },
    location() {
      const {
        country = '',
        city = '',
        country_code: countryCode,
      } = this.additionalAttributes;
      const cityAndCountry = [city, country].filter(item => !!item).join(', ');

      if (!cityAndCountry) {
        return '';
      }
      return this.findCountryFlag(countryCode, cityAndCountry);
    },
    socialProfiles() {
      const {
        social_profiles: socialProfiles,
        screen_name: twitterScreenName,
        social_telegram_user_name: telegramUsername,
      } = this.additionalAttributes;

      const telegram = socialProfiles?.telegram || telegramUsername || '';
      const twitter = socialProfiles?.twitter || twitterScreenName || '';

      return {
        ...(socialProfiles || {}),
        twitter,
        telegram,
      };
    },
    // Delete Modal
    confirmDeleteMessage() {
      return ` ${this.contact.name}?`;
    },
    contactConversations() {
      return this.$store.getters[
        'contactConversations/getAllConversationsByContactId'
      ](this.contact.id);
    },
    contactConversationsLoaded() {
      const contactId = Number(this.contact?.id);

      if (!contactId) {
        return false;
      }

      return Object.prototype.hasOwnProperty.call(
        this.$store.state.contactConversations.records,
        contactId
      );
    },
    existingConversationInboxIds() {
      if (!this.contactConversationsLoaded) {
        return null;
      }

      return [
        ...new Set(
          (this.contactConversations || [])
            .map(conversation =>
              Number(conversation.inboxId || conversation.inbox_id)
            )
            .filter(Boolean)
        ),
      ];
    },
  },
  watch: {
    'contact.id': {
      handler(id) {
        this.$store.dispatch('contacts/fetchContactableInbox', id);
        this.$store.dispatch('contactConversations/get', id);
      },
      immediate: true,
    },
  },
  methods: {
    dynamicTime,
    toggleEditModal() {
      this.showEditModal = !this.showEditModal;
    },
    openComposeConversationModal(toggleFn) {
      toggleFn();
      // Flag to prevent triggering drag n drop,
      // When compose modal is active
      emitter.emit(BUS_EVENTS.NEW_CONVERSATION_MODAL, true);
    },
    closeComposeConversationModal() {
      // Flag to enable drag n drop,
      // When compose modal is closed
      emitter.emit(BUS_EVENTS.NEW_CONVERSATION_MODAL, false);
    },
    toggleDeleteModal() {
      this.showDeleteModal = !this.showDeleteModal;
    },
    confirmDeletion() {
      this.deleteContact(this.contact);
      this.closeDelete();
    },
    closeDelete() {
      this.showDeleteModal = false;
      this.showEditModal = false;
    },
    sourceValue(source, camelKey, snakeKey = null) {
      if (!source) {
        return undefined;
      }

      const resolvedSnakeKey =
        snakeKey ||
        camelKey.replace(/[A-Z]/g, letter => `_${letter.toLowerCase()}`);

      return source[camelKey] ?? source[resolvedSnakeKey];
    },
    humanizeSourceName(value) {
      const rawValue = value?.replace('Channel::', '') || '';
      if (!rawValue) {
        return this.$t('CONTACT_PANEL.SOURCE_IDENTITIES.UNKNOWN');
      }

      return rawValue
        .replace(/_/g, ' ')
        .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
        .split(' ')
        .filter(Boolean)
        .map(chunk => chunk.charAt(0).toUpperCase() + chunk.slice(1))
        .join(' ');
    },
    displaySourceLabel(source) {
      const kind = this.sourceValue(source, 'kind');

      if (kind === 'manual') {
        return this.$t('CONTACT_PANEL.SOURCE_IDENTITIES.MANUAL_NAME');
      }

      if (kind === 'contact_avatar') {
        return this.$t('CONTACT_PANEL.SOURCE_IDENTITIES.CONTACT_PHOTO');
      }

      const provider =
        this.sourceValue(source, 'provider') ||
        this.sourceValue(source, 'channelType');

      return this.humanizeSourceName(provider);
    },
    buildSourcePreference(source, preferenceType = 'name') {
      const resolvedSource =
        preferenceType === 'avatar'
          ? source.avatarSource || source
          : source.nameSource || source;

      return {
        kind: this.sourceValue(resolvedSource, 'kind') || 'channel_profile',
        contactInboxId: this.sourceValue(resolvedSource, 'contactInboxId'),
        inboxId: this.sourceValue(resolvedSource, 'inboxId'),
        channelType: this.sourceValue(resolvedSource, 'channelType'),
        provider: this.sourceValue(resolvedSource, 'provider'),
        sourceId: this.sourceValue(resolvedSource, 'sourceId'),
        identifier: this.sourceValue(resolvedSource, 'identifier'),
      };
    },
    async setPrimaryNameSource(source) {
      try {
        await this.$store.dispatch('contacts/update', {
          id: this.contact.id,
          name: this.sourceValue(source, 'displayName'),
          additionalAttributes: {
            displayPreferences: {
              primaryNameSource: this.buildSourcePreference(source, 'name'),
            },
          },
        });
      } catch (error) {
        useAlert(this.$t('CONTACT_FORM.ERROR_MESSAGE'));
      }
    },
    async setPrimaryAvatarSource(source) {
      try {
        await this.$store.dispatch('contacts/update', {
          id: this.contact.id,
          additionalAttributes: {
            displayPreferences: {
              primaryAvatarSource: this.buildSourcePreference(source, 'avatar'),
            },
          },
        });
      } catch (error) {
        useAlert(this.$t('CONTACT_FORM.ERROR_MESSAGE'));
      }
    },
    findCountryFlag(countryCode, cityAndCountry) {
      try {
        if (!countryCode) {
          return `${cityAndCountry} 🌎`;
        }

        const code = countryCode?.toLowerCase();
        return `${cityAndCountry} <span class="fi fi-${code} size-3.5"></span>`;
      } catch (error) {
        return '';
      }
    },
    async deleteContact({ id }) {
      try {
        await this.$store.dispatch('contacts/delete', id);
        this.$emit('panelClose');
        useAlert(this.$t('DELETE_CONTACT.API.SUCCESS_MESSAGE'));

        if (isAConversationRoute(this.$route.name)) {
          this.$router.push({
            name: getConversationDashboardRoute(this.$route.name),
          });
        } else if (isAInboxViewRoute(this.$route.name)) {
          this.$router.push({
            name: 'inbox_view',
          });
        } else if (this.$route.name !== 'contacts_dashboard') {
          this.$router.push({
            name: 'contacts_dashboard',
          });
        }
      } catch (error) {
        useAlert(
          error.message
            ? error.message
            : this.$t('DELETE_CONTACT.API.ERROR_MESSAGE')
        );
      }
    },
    openMergeModal() {
      this.$refs.mergeModal?.open();
    },
    openCrmRoute(name, query) {
      this.$router.push({
        name,
        params: { accountId: this.currentAccountId },
        query,
      });
    },
    onCreateDeal() {
      if (
        isAConversationRoute(this.$route.name) ||
        isAInboxViewRoute(this.$route.name)
      ) {
        this.updateUISettings({
          is_contact_sidebar_open: false,
          is_crm_deal_panel_open: true,
          is_copilot_panel_open: false,
          is_touch_sidebar_open: false,
        });
        return;
      }

      this.openCrmRoute('crm_deals_index', {
        action: 'new',
        contactId: this.contact.id,
        contactName: this.contact.name || undefined,
        source: 'contact',
      });
    },
    onCreateTask() {
      this.openCrmRoute('crm_tasks_index', {
        action: 'new',
        contactName: this.contact.name || undefined,
        source: 'contact',
      });
    },
    onCreateAppointment() {
      const conversationId = Number(this.$route.params.id);

      this.openCrmRoute('scheduling_calendar', {
        action: 'new',
        contactId: this.contact.id,
        contactName: this.contact.name || undefined,
        contactPhone: this.contact.phone_number || undefined,
        conversationId:
          Number.isFinite(conversationId) && conversationId > 0
            ? conversationId
            : undefined,
        source: 'contact',
      });
    },
    openChannelConversation(channelIdentity) {
      const targetConversation = (this.contactConversations || []).find(
        conversation =>
          Number(conversation.inboxId || conversation.inbox_id) ===
          Number(channelIdentity.inboxId)
      );

      if (!targetConversation) {
        this.$refs.composeConversation?.openWithChannel({
          contact: this.contact,
          channelIdentity,
        });
        return;
      }

      this.$router.push({
        name: 'inbox_view_conversation',
        params: {
          accountId: this.$route.params.accountId,
          type: 'conversation',
          id: targetConversation.id,
        },
      });
    },
  },
};
</script>

<template>
  <div class="relative items-center w-full p-4">
    <div
      class="flex flex-col w-full gap-4 text-left rtl:text-right md:flex-row md:items-start"
    >
      <div class="flex flex-col flex-1 min-w-0 gap-2">
        <div class="flex flex-row items-start justify-between w-full">
          <Avatar
            v-if="showAvatar"
            :src="contact.thumbnail"
            :name="contact.name"
            :status="contact.availability_status"
            :size="48"
            hide-offline-status
            rounded-full
          />
          <NextButton
            v-if="isAdmin"
            v-tooltip.top-end="$t('DELETE_CONTACT.BUTTON_LABEL')"
            icon="i-ph-trash"
            slate
            faded
            sm
            ruby
            :disabled="uiFlags.isDeleting"
            @click="toggleDeleteModal"
          />
        </div>

        <div class="flex flex-col items-start gap-1.5 min-w-0 w-full">
          <div v-if="showAvatar" class="flex items-center w-full min-w-0 gap-3">
            <h3
              class="flex-shrink max-w-full min-w-0 my-0 text-base capitalize break-words text-n-slate-12"
            >
              {{ contact.name }}
            </h3>
            <div class="flex flex-row items-center gap-2">
              <span
                v-if="contact.created_at"
                v-tooltip.left="
                  `${$t('CONTACT_PANEL.CREATED_AT_LABEL')} ${dynamicTime(
                    contact.created_at
                  )}`
                "
                class="i-lucide-info text-sm text-n-slate-10"
              />
              <a
                :href="contactProfileLink"
                target="_blank"
                rel="noopener nofollow noreferrer"
                class="leading-3"
              >
                <span class="i-lucide-external-link text-sm text-n-slate-10" />
              </a>
            </div>
          </div>

          <div
            class="flex flex-wrap items-center gap-2 text-xs text-n-slate-11"
          >
            <span
              class="inline-flex items-center gap-1 px-2.5 py-1 rounded-full bg-n-alpha-2 text-n-slate-11"
            >
              <span class="font-medium">{{
                $t('CONTACT_PANEL.SOURCE_IDENTITIES.PRIMARY_NAME')
              }}</span>
              <span>{{ primaryNameSourceLabel }}</span>
            </span>
            <span
              class="inline-flex items-center gap-1 px-2.5 py-1 rounded-full bg-n-alpha-2 text-n-slate-11"
            >
              <span class="font-medium">{{
                $t('CONTACT_PANEL.SOURCE_IDENTITIES.PRIMARY_PHOTO')
              }}</span>
              <span>{{ primaryAvatarSourceLabel }}</span>
            </span>
          </div>

          <p v-if="additionalAttributes.description" class="break-words mb-0.5">
            {{ additionalAttributes.description }}
          </p>
          <div class="flex flex-col items-start w-full gap-2">
            <ContactInfoRow
              :href="contact.email ? `mailto:${contact.email}` : ''"
              :value="contact.email"
              icon="mail"
              emoji="✉️"
              :title="$t('CONTACT_PANEL.EMAIL_ADDRESS')"
              show-copy
            />
            <ContactInfoRow
              :href="contact.phone_number ? `tel:${contact.phone_number}` : ''"
              :value="contact.phone_number"
              icon="call"
              emoji="📞"
              :title="$t('CONTACT_PANEL.PHONE_NUMBER')"
              show-copy
            />
            <ContactInfoRow
              v-if="contact.identifier"
              :value="contact.identifier"
              icon="contact-identify"
              emoji="🪪"
              :title="$t('CONTACT_PANEL.IDENTIFIER')"
            />
            <ContactInfoRow
              :value="additionalAttributes.company_name"
              icon="building-bank"
              emoji="🏢"
              :title="$t('CONTACT_PANEL.COMPANY')"
            />
            <ContactInfoRow
              v-if="location || additionalAttributes.location"
              :value="location || additionalAttributes.location"
              icon="map"
              emoji="🌍"
              :title="$t('CONTACT_PANEL.LOCATION')"
            />
            <SocialIcons :social-profiles="socialProfiles" />
            <ContactChannelLabels
              :contact-inboxes="
                contact.contactInboxes || contact.contact_inboxes || []
              "
              :existing-conversation-inbox-ids="existingConversationInboxIds"
              :title="$t('CONTACT_PANEL.CHANNEL_IDENTITIES')"
              :copy-on-click="false"
              @select="openChannelConversation"
            />
          </div>
        </div>
        <div class="flex items-center w-full mt-0.5 gap-2">
          <ComposeConversation
            ref="composeConversation"
            :contact-id="String(contact.id)"
            is-modal
            @close="closeComposeConversationModal"
          >
            <template #trigger="{ toggle }">
              <NextButton
                v-tooltip.top-end="$t('CONTACT_PANEL.NEW_MESSAGE')"
                icon="i-ph-chat-circle-dots"
                slate
                faded
                sm
                @click="openComposeConversationModal(toggle)"
              />
            </template>
          </ComposeConversation>
          <VoiceCallButton
            :phone="contact.phone_number"
            :contact-id="contact.id"
            icon="i-ri-phone-fill"
            size="sm"
            :tooltip-label="$t('CONTACT_PANEL.CALL')"
            slate
            faded
          />
          <NextButton
            v-if="canCreateCrmDeal"
            v-tooltip.top-end="$t('CRM.DEALS.NEW_DEAL')"
            icon="i-lucide-briefcase-business"
            slate
            faded
            sm
            @click="onCreateDeal"
          />
          <NextButton
            v-if="canCreateCrmTask"
            v-tooltip.top-end="$t('CRM.TASKS.NEW_TASK')"
            icon="i-lucide-list-checks"
            slate
            faded
            sm
            @click="onCreateTask"
          />
          <NextButton
            v-if="canCreateSchedulingAppointment"
            v-tooltip.top-end="$t('SCHEDULING.CALENDAR.NEW_APPOINTMENT')"
            icon="i-lucide-calendar-clock"
            slate
            faded
            sm
            @click="onCreateAppointment"
          />
          <NextButton
            v-tooltip.top-end="$t('EDIT_CONTACT.BUTTON_LABEL')"
            icon="i-ph-pencil-simple"
            slate
            faded
            sm
            @click="toggleEditModal"
          />
          <NextButton
            v-tooltip.top-end="$t('CONTACT_PANEL.MERGE_CONTACT')"
            icon="i-ph-arrows-merge"
            slate
            faded
            sm
            :disabled="uiFlags.isMerging"
            @click="openMergeModal"
          />
        </div>
      </div>

      <ContactIdentitySources
        :contact="contact"
        :is-updating="uiFlags.isUpdating"
        @select-name-source="setPrimaryNameSource"
        @select-avatar-source="setPrimaryAvatarSource"
      />

      <EditContact
        v-if="showEditModal"
        :show="showEditModal"
        :contact="contact"
        @cancel="toggleEditModal"
      />
      <ContactMergeModal ref="mergeModal" :primary-contact="contact" />
    </div>
    <woot-delete-modal
      v-if="showDeleteModal"
      v-model:show="showDeleteModal"
      :on-close="closeDelete"
      :on-confirm="confirmDeletion"
      :title="$t('DELETE_CONTACT.CONFIRM.TITLE')"
      :message="$t('DELETE_CONTACT.CONFIRM.MESSAGE')"
      :message-value="confirmDeleteMessage"
      :confirm-text="$t('DELETE_CONTACT.CONFIRM.YES')"
      :reject-text="$t('DELETE_CONTACT.CONFIRM.NO')"
    />
  </div>
</template>
