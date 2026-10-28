<script>
import { useAlert } from 'dashboard/composables';
import {
  DuplicateContactException,
  ExceptionWithMessage,
} from 'shared/helpers/CustomErrors';
import { useAdmin } from 'dashboard/composables/useAdmin';
import ContactInfoRow from './ContactInfoRow.vue';
import Avatar from 'next/avatar/Avatar.vue';
import SocialIcons from './SocialIcons.vue';
import EditContact from './EditContact.vue';
import ContactMergeModal from 'dashboard/modules/contact/ContactMergeModal.vue';
import InlineInput from 'dashboard/components-next/inline-input/InlineInput.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import {
  maskedPatientIin,
  patientAgeLabel,
} from 'dashboard/stores/scheduling/patientContext';
import {
  WHATSAPP_SUPPORTED_CLIENT_LANGUAGES,
  getClientLanguageNativeName,
  normalizeClientLanguageCode,
} from 'dashboard/helper/appointmentTemplatePresets';

import {
  isAConversationRoute,
  isAInboxViewRoute,
  getConversationDashboardRoute,
} from '../../../../helper/routeHelpers';

export default {
  components: {
    ContactInfoRow,
    EditContact,
    Avatar,
    SocialIcons,
    ContactMergeModal,
    InlineInput,
    NextButton,
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
    patientContextEnabled: { type: Boolean, default: false },
  },
  emits: ['panelClose'],
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
    };
  },
  computed: {
    supportedClientLanguages() {
      return WHATSAPP_SUPPORTED_CLIENT_LANGUAGES;
    },
    contactClientLanguage() {
      const direct = normalizeClientLanguageCode(
        this.additionalAttributes.client_language ||
          this.additionalAttributes.patient_language
      );
      if (direct) return direct;

      const convLang = (this.contactConversations || [])
        .map(conv =>
          normalizeClientLanguageCode(
            conv?.additional_attributes?.captain_patient_language
          )
        )
        .find(Boolean);
      return convLang || '';
    },
    contactClientLanguageConfidence() {
      const raw = this.additionalAttributes.client_language_confidence;
      if (raw === undefined || raw === null || raw === '') return null;
      const num = Number(raw);
      return Number.isFinite(num) && num > 0 ? Math.round(num) : null;
    },
    contactClientLanguageDisplay() {
      if (!this.contactClientLanguage) return 'Не определён';
      const name = getClientLanguageNativeName(this.contactClientLanguage);
      if (
        this.additionalAttributes.client_language_source !== 'manual' &&
        this.contactClientLanguageConfidence
      ) {
        return `${name} (${this.contactClientLanguageConfidence}%)`;
      }
      return name;
    },
    contactProfileLink() {
      return `/app/accounts/${this.$route.params.accountId}/contacts/${this.contact.id}`;
    },
    headerMeta() {
      const patient = this.patientContextEnabled ? this.selectedPatient : null;
      const parts = [];
      if (patient) {
        parts.push(
          patientAgeLabel(patient, this.$t, this.$i18n?.locale || 'ru')
        );
        const iin = maskedPatientIin(patient);
        if (iin) parts.push(`${this.$t('SCHEDULING.CONTACT.IIN')} ${iin}`);
      }
      return parts.filter(Boolean).join(' · ');
    },
    additionalAttributes() {
      return this.contact.additional_attributes || {};
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
    openContactProfile() {
      window.open(this.contactProfileLink, '_blank', 'noopener,noreferrer');
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
    startEditingName() {
      this.editName = this.contact.name || '';
      this.isEditingName = true;
      this.$nextTick(() => {
        this.$refs.nameInput?.focus?.();
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
    onClientLanguageChange(event) {
      const nextLang = normalizeClientLanguageCode(event.target.value);
      const nextAttrs = {
        ...this.additionalAttributes,
        client_language: nextLang || null,
        client_language_source: nextLang ? 'manual' : null,
      };
      if (nextLang) {
        nextAttrs.client_language_confidence = 100;
      }
      this.updateContactField({
        client_language: nextLang || '',
        additional_attributes: nextAttrs,
      });
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
      <div class="flex flex-col flex-1 min-w-0 gap-2.5">
        <div
          class="flex w-full min-w-0 items-start gap-3"
          data-test="contact-header"
        >
          <Avatar
            v-if="showAvatar"
            :src="contact.thumbnail"
            :name="contact.name"
            :status="contact.availability_status"
            :size="48"
            hide-offline-status
            rounded-full
            class="shrink-0"
          />
          <div class="flex min-w-0 flex-1 flex-col gap-0.5">
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
              class="m-0 line-clamp-2 min-w-0 cursor-pointer text-base font-semibold text-n-slate-12 hover:text-n-slate-11"
              :title="$t('CONTACT_PANEL.CLICK_TO_EDIT')"
              @click="startEditingName"
            >
              {{ contact.name }}
            </h3>
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
              class="self-start text-sm text-n-blue-11"
              @click="openEditModal"
            >
              {{ $t('CONTACT_PANEL.ADD_PHONE') }}
            </button>
            <p
              v-if="headerMeta"
              class="m-0 truncate text-xs text-n-slate-11"
              :title="headerMeta"
              data-test="contact-header-meta"
            >
              {{ headerMeta }}
            </p>
          </div>
        </div>
        <div class="flex min-w-0 flex-col items-start gap-1.5">
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
            <div
              class="flex w-full items-center justify-between gap-2 text-xs text-n-slate-11"
              data-test="contact-client-language-row"
            >
              <span class="inline-flex items-center gap-1.5">
                <span class="i-lucide-languages size-3.5 text-n-slate-10" />
                <span>Язык клиента:</span>
                <strong
                  class="font-medium text-n-slate-12"
                  data-test="contact-client-language-badge"
                >
                  {{ contactClientLanguageDisplay }}
                </strong>
              </span>
              <select
                data-test="contact-client-language-select"
                :value="contactClientLanguage"
                class="rounded-md border border-n-weak bg-n-surface-1 px-1.5 py-0.5 text-xs text-n-slate-12"
                @change="onClientLanguageChange"
              >
                <option value="">Авто</option>
                <option
                  v-for="lang in supportedClientLanguages"
                  :key="lang.code"
                  :value="lang.code"
                >
                  {{ lang.name }} ({{ lang.code }})
                </option>
              </select>
            </div>
            <SocialIcons :social-profiles="socialProfiles" />
            <slot name="after-channels" />
          </div>
        </div>
        <div
          class="flex w-full items-center gap-2 mt-0.5"
          data-test="contact-panel-actions"
        >
          <NextButton
            v-tooltip.top-end="$t('EDIT_CONTACT.BUTTON_LABEL')"
            icon="i-ph-pencil-simple"
            slate
            faded
            sm
            :aria-label="$t('EDIT_CONTACT.BUTTON_LABEL')"
            @click="openEditModal"
          />
          <NextButton
            v-tooltip.top-end="$t('CONTACT_PANEL.MERGE_CONTACT')"
            icon="i-ph-arrows-merge"
            slate
            faded
            sm
            :aria-label="$t('CONTACT_PANEL.MERGE_CONTACT')"
            @click="openMergeModal"
          />
          <NextButton
            v-tooltip.top-end="$t('CONTACT_PANEL.OPEN_PROFILE')"
            icon="i-lucide-external-link"
            slate
            faded
            sm
            :aria-label="$t('CONTACT_PANEL.OPEN_PROFILE')"
            @click="openContactProfile"
          />
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
