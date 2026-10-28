<script>
import { mapGetters } from 'vuex';
import { useAlert } from 'dashboard/composables';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import {
  CRM_DEAL_MANAGE_PERMISSIONS,
  CRM_TASK_MANAGE_PERMISSIONS,
} from 'dashboard/constants/permissions';
import { hasPermissions } from 'dashboard/helper/permissionsHelper';
import {
  DuplicateContactException,
  ExceptionWithMessage,
} from 'shared/helpers/CustomErrors';
import { useAdmin } from 'dashboard/composables/useAdmin';
import ContactInfoRow from './ContactInfoRow.vue';
import Avatar from 'next/avatar/Avatar.vue';
import SocialIcons from './SocialIcons.vue';
import EditContact from './EditContact.vue';
import ContactChannelLabels from 'dashboard/components-next/Contacts/ContactChannelLabels.vue';
import ContactMergeModal from 'dashboard/modules/contact/ContactMergeModal.vue';
import CrmContactTaskDrawer from 'dashboard/components-next/CRM/CrmContactTaskDrawer.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import InlineInput from 'dashboard/components-next/inline-input/InlineInput.vue';
import SchedulingConversationAppointmentsSidebar from 'dashboard/components-next/Scheduling/SchedulingConversationAppointmentsSidebar.vue';
import CrmConversationDealsSidebar from 'dashboard/components-next/CRM/CrmConversationDealsSidebar.vue';

import {
  isAConversationRoute,
  isAInboxViewRoute,
  getConversationDashboardRoute,
} from '../../../../helper/routeHelpers';

export default {
  components: {
    NextButton,
    ContactInfoRow,
    EditContact,
    Avatar,
    SocialIcons,
    ContactChannelLabels,
    ContactMergeModal,
    CrmContactTaskDrawer,
    InlineInput,
    SchedulingConversationAppointmentsSidebar,
    CrmConversationDealsSidebar,
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
    selectedPatient: { type: Object, default: null },
    patientContextKey: { type: String, default: '' },
    patientContextEnabled: { type: Boolean, default: false },
    canAddFamilyMember: { type: Boolean, default: false },
  },
  emits: ['panelClose', 'addFamilyMember'],
  setup() {
    const { isAdmin } = useAdmin();
    return {
      isAdmin,
    };
  },
  data() {
    return {
      showEditModal: false,
      showDeleteModal: false,
      isEditingName: false,
      editName: '',
      moreOpen: false,
      appointmentOpen: false,
      dealOpen: false,
      taskOpen: false,
    };
  },
  computed: {
    ...mapGetters({
      currentAccountId: 'getCurrentAccountId',
      currentUser: 'getCurrentUser',
      isFeatureEnabledonAccount: 'accounts/isFeatureEnabledonAccount',
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
          CRM_DEAL_MANAGE_PERMISSIONS,
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
          CRM_TASK_MANAGE_PERMISSIONS,
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
    currentChat() {
      return this.$store.getters.getSelectedChat || {};
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
            .filter(conversation => conversation.status !== 'resolved')
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
        if (!id) return;
        this.$store.dispatch('contacts/fetchContactableInbox', id);
        this.$store.dispatch('contactConversations/get', id);
      },
      immediate: true,
    },
  },
  methods: {
    openEditModal() {
      this.showEditModal = true;
    },
    closeEditModal() {
      this.showEditModal = false;
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
        this.dealOpen = true;
        this.$nextTick(() => {
          this.$refs.dealSidebar?.startCreateDeal?.();
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
      this.taskOpen = true;
    },
    onCreateAppointment() {
      this.appointmentOpen = true;
      this.$nextTick(() => {
        this.$refs.appointmentSidebar?.startCreateAppointment?.();
      });
    },
    startEditingName() {
      this.editName = this.contact.name || '';
      this.isEditingName = true;
      this.$nextTick(() => {
        this.$refs.nameInput?.focus();
      });
    },
    saveNameEdit() {
      if (!this.isEditingName) return;
      this.isEditingName = false;
      const trimmed = this.editName.trim();
      if (trimmed && trimmed !== this.contact.name) {
        this.updateContactField({ name: trimmed });
      }
    },
    cancelNameEdit() {
      this.isEditingName = false;
    },
    onFieldUpdate(field, value) {
      this.updateContactField({ [field]: value });
    },
    async updateContactField(attrs) {
      const contactId = this.contact.id;
      try {
        await this.$store.dispatch('contacts/update', {
          id: contactId,
          ...attrs,
        });
        useAlert(this.$t('CONTACT_FORM.SUCCESS_MESSAGE'));
        await this.$store.dispatch('contacts/fetchContactableInbox', contactId);
      } catch (error) {
        if (error instanceof DuplicateContactException) {
          const detail = error.contactErrorDetail;
          if (detail) {
            useAlert(detail);
          } else {
            const invalidAttrs = Array.isArray(error.data) ? error.data : [];
            if (invalidAttrs.includes('email')) {
              useAlert(this.$t('CONTACT_FORM.FORM.EMAIL_ADDRESS.DUPLICATE'));
            } else if (invalidAttrs.includes('phone_number')) {
              useAlert(this.$t('CONTACT_FORM.FORM.PHONE_NUMBER.DUPLICATE'));
            } else {
              useAlert(this.$t('CONTACT_FORM.ERROR_MESSAGE'));
            }
          }
        } else if (error instanceof ExceptionWithMessage) {
          useAlert(error.data);
        } else {
          useAlert(error.message || this.$t('CONTACT_FORM.ERROR_MESSAGE'));
        }
      }
    },
  },
};
</script>

<template>
  <div class="relative items-center w-full p-4">
    <div class="flex flex-col w-full gap-4 text-left rtl:text-right">
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
        </div>

        <div class="flex flex-col items-start gap-1.5 min-w-0 w-full">
          <div v-if="showAvatar" class="flex items-center w-full min-w-0 gap-3">
            <InlineInput
              v-if="isEditingName"
              ref="nameInput"
              v-model="editName"
              custom-input-class="!text-base !font-medium"
              class="!w-fit"
              @enter-press="saveNameEdit"
              @escape-press="cancelNameEdit"
              @blur="saveNameEdit"
            />
            <h3
              v-else
              class="group/name line-clamp-2 min-w-0 my-0 text-base font-semibold text-n-slate-12 cursor-pointer hover:text-n-slate-11"
              :title="$t('CONTACT_PANEL.CLICK_TO_EDIT')"
              @click="startEditingName"
            >
              {{ contact.name }}
              <span
                class="i-lucide-pencil text-xs text-n-slate-10 opacity-0 group-hover/name:opacity-100 transition-opacity ml-1 align-middle"
              />
            </h3>
          </div>
          <slot name="patient-summary" />

          <p v-if="additionalAttributes.description" class="break-words mb-0.5">
            {{ additionalAttributes.description }}
          </p>
          <div class="flex flex-col items-start w-full gap-2">
            <ContactInfoRow
              v-if="contact.email"
              :href="contact.email ? `mailto:${contact.email}` : ''"
              :value="contact.email"
              icon="mail"
              emoji="✉️"
              :title="$t('CONTACT_PANEL.EMAIL_ADDRESS')"
              show-copy
              editable
              @update="value => onFieldUpdate('email', value)"
            />
            <ContactInfoRow
              v-if="contact.phone_number"
              :href="`tel:${contact.phone_number}`"
              :value="contact.phone_number"
              icon="call"
              emoji="📞"
              :title="$t('CONTACT_PANEL.PHONE_NUMBER')"
              show-copy
              editable
              @update="value => onFieldUpdate('phone_number', value)"
            />
            <button
              v-else
              type="button"
              class="text-sm text-n-blue-11"
              @click="openEditModal"
            >
              {{ $t('CONTACT_PANEL.ADD_PHONE') }}
            </button>
            <ContactInfoRow
              v-if="additionalAttributes.company_name"
              :value="additionalAttributes.company_name"
              icon="building-bank"
              emoji="🏢"
              :title="$t('CONTACT_PANEL.COMPANY')"
              editable
              @update="
                value =>
                  updateContactField({
                    additional_attributes: {
                      ...additionalAttributes,
                      company_name: value,
                    },
                  })
              "
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
              icon-only
            />
            <slot name="after-channels" />
          </div>
        </div>
        <div
          class="grid w-full grid-cols-4 gap-1 pt-2"
          data-test="contact-panel-actions"
        >
          <NextButton
            v-if="canCreateCrmDeal"
            icon="i-lucide-briefcase-business"
            :label="$t('CONTACT_PANEL.ACTION_DEAL')"
            slate
            faded
            sm
            class="contact-panel-action"
            @click="onCreateDeal"
          />
          <NextButton
            v-if="canCreateCrmTask"
            icon="i-lucide-list-checks"
            :label="$t('CONTACT_PANEL.ACTION_TASK')"
            slate
            faded
            sm
            class="contact-panel-action"
            @click="onCreateTask"
          />
          <NextButton
            v-if="canCreateSchedulingAppointment"
            icon="i-lucide-calendar-clock"
            :label="$t('CONTACT_PANEL.ACTION_APPOINTMENT')"
            slate
            faded
            sm
            class="contact-panel-action"
            @click="onCreateAppointment"
          />
          <div class="relative min-w-0">
            <NextButton
              icon="i-lucide-ellipsis"
              :label="$t('CONTACT_PANEL.ACTION_MORE')"
              slate
              faded
              sm
              class="contact-panel-action"
              @click="moreOpen = !moreOpen"
            />
            <div
              v-if="moreOpen"
              class="absolute right-0 z-30 mt-1 min-w-52 rounded-lg border border-n-weak bg-n-solid-2 p-1 shadow-lg"
            >
              <button
                type="button"
                class="block w-full rounded px-3 py-2 text-left text-sm text-n-slate-12 hover:bg-n-alpha-2"
                @click="
                  moreOpen = false;
                  openEditModal();
                "
              >
                {{ $t('EDIT_CONTACT.BUTTON_LABEL') }}
              </button>
              <button
                type="button"
                class="block w-full rounded px-3 py-2 text-left text-sm text-n-slate-12 hover:bg-n-alpha-2"
                @click="
                  moreOpen = false;
                  openMergeModal();
                "
              >
                {{ $t('CONTACT_PANEL.MERGE_CONTACT') }}
              </button>
              <a
                :href="contactProfileLink"
                target="_blank"
                rel="noopener noreferrer"
                class="block rounded px-3 py-2 text-sm text-n-slate-12 hover:bg-n-alpha-2"
                >{{ $t('CONTACT_PANEL.OPEN_PROFILE') }}</a
              >
              <button
                v-if="canAddFamilyMember"
                type="button"
                class="block w-full rounded px-3 py-2 text-left text-sm text-n-slate-12 hover:bg-n-alpha-2"
                @click="
                  moreOpen = false;
                  $emit('addFamilyMember');
                "
              >
                {{ $t('SCHEDULING.PATIENT_CONTEXT.ADD_FAMILY_MEMBER') }}
              </button>
              <button
                v-if="isAdmin"
                type="button"
                class="block w-full rounded px-3 py-2 text-left text-sm text-n-ruby-11 hover:bg-n-alpha-2"
                @click="
                  moreOpen = false;
                  toggleDeleteModal();
                "
              >
                {{ $t('DELETE_CONTACT.BUTTON_LABEL') }}
              </button>
            </div>
          </div>
        </div>
        <slot />
      </div>

      <EditContact
        v-if="showEditModal"
        v-model:show="showEditModal"
        :contact="contact"
        @cancel="closeEditModal"
      />
      <ContactMergeModal ref="mergeModal" :primary-contact="contact" />
      <CrmContactTaskDrawer
        v-if="taskOpen"
        v-model="taskOpen"
        :contact="contact"
        :current-chat="currentChat"
      />
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
    <div
      v-if="appointmentOpen"
      class="fixed inset-0 z-[140] flex justify-end bg-black/35"
      role="dialog"
      :aria-label="$t('CONTACT_PANEL.ACTION_APPOINTMENT')"
    >
      <div class="h-full w-full max-w-[32rem] bg-n-solid-2 shadow-xl">
        <SchedulingConversationAppointmentsSidebar
          ref="appointmentSidebar"
          :current-chat="currentChat"
          :selected-patient="selectedPatient"
          :patient-context-key="patientContextKey"
          :patient-context-enabled="patientContextEnabled"
          @close="appointmentOpen = false"
        />
      </div>
    </div>
    <div
      v-if="dealOpen"
      class="fixed inset-0 z-[140] flex items-center justify-center bg-black/35 p-3"
      role="dialog"
      :aria-label="$t('CONTACT_PANEL.ACTION_DEAL')"
    >
      <div
        class="h-[min(90vh,48rem)] w-full max-w-[36rem] overflow-hidden rounded-xl bg-n-solid-2 shadow-xl"
      >
        <CrmConversationDealsSidebar
          ref="dealSidebar"
          :current-chat="currentChat"
          @close="dealOpen = false"
        />
      </div>
    </div>
  </div>
</template>

<style scoped>
.contact-panel-action {
  width: 100%;
  height: 3.25rem;
  flex-direction: column;
  gap: 0.125rem;
  padding: 0.375rem 0;
  font-size: 0.6875rem;
  line-height: 1rem;
}

.contact-panel-action :deep(> span:last-child) {
  overflow: visible;
  text-overflow: clip;
}
</style>
