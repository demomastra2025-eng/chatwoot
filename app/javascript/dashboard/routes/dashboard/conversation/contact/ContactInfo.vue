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
import ToggleSwitch from 'dashboard/components-next/switch/Switch.vue';
import ContactPhonesManager from 'dashboard/components-next/Contacts/ContactPhonesManager.vue';
import FamilyPatientCardModal from 'dashboard/components/widgets/conversation/FamilyPatientCardModal.vue';
import CrmCustomFieldDescriptionHint from 'dashboard/components-next/CRM/CrmCustomFieldDescriptionHint.vue';
import { resolveOptionalPatientStore } from 'dashboard/composables/useConversationPatientContext';
import { copyTextToClipboard } from 'shared/helpers/clipboard';
import {
  maskedPatientIin,
  normalizePatientBirthDate,
  patientAgeLabel,
  patientDisplayName,
} from 'dashboard/stores/scheduling/patientContext';
import {
  formatClientLanguageSummary,
  normalizeClientLanguageCode,
} from 'dashboard/helper/appointmentTemplatePresets';

import {
  isAConversationRoute,
  isAInboxViewRoute,
  getConversationDashboardRoute,
} from '../../../../helper/routeHelpers';

const DOSSIER_EXCLUDED_CUSTOM_ATTRIBUTE_KEYS = new Set([
  'medelement_patient_code',
  'medelement_last_synced_at',
  'medelement_first_name',
  'medelement_last_name',
  'medelement_middle_name',
  'phone_conflict_comment',
  'birth_date',
  'iin',
  'gender',
  'secondary_phones',
  'address',
]);

export default {
  components: {
    ContactInfoRow,
    CrmCustomFieldDescriptionHint,
    EditContact,
    Avatar,
    SocialIcons,
    ContactMergeModal,
    ContactPhonesManager,
    FamilyPatientCardModal,
    InlineInput,
    NextButton,
    ToggleSwitch,
  },
  props: {
    contact: {
      type: Object,
      default: () => ({}),
    },
    communicationContact: {
      type: Object,
      default: null,
    },
    showAvatar: {
      type: Boolean,
      default: true,
    },
    selectedPatient: { type: Object, default: null },
    patientContextEnabled: { type: Boolean, default: false },
    patientContextKey: { type: String, default: '' },
    patientEntry: { type: Object, default: null },
    patientConversationDisplayId: { type: [Number, String], default: null },
  },
  emits: ['panelClose'],
  setup() {
    const { isAdmin } = useAdmin();
    return {
      isAdmin,
      optionalPatientStore: resolveOptionalPatientStore(),
    };
  },
  data() {
    return {
      showEditModal: false,
      showDeleteModal: false,
      showFamilyCardModal: false,
      isEditingName: false,
      editName: '',
      isSavingContactMute: false,
      isSavingPatientMute: false,
      localPatientMutedOverrides: {},
    };
  },
  computed: {
    isContactNotificationsMuted() {
      return Boolean(
        this.contact?.notifications_muted ?? this.contact?.notificationsMuted
      );
    },
    hasSeparateSelectedPatient() {
      return Boolean(
        this.patientContextEnabled &&
          this.selectedPatient?.id &&
          Number(this.selectedPatient.id) !== Number(this.contact?.id)
      );
    },
    selectedPatientStoreContact() {
      if (!this.hasSeparateSelectedPatient) return null;
      const getter = this.$store?.getters?.['contacts/getContact'];
      return typeof getter === 'function'
        ? getter(this.selectedPatient.id)
        : null;
    },
    selectedPatientName() {
      return (
        patientDisplayName(this.selectedPatient) ||
        this.selectedPatientStoreContact?.name ||
        ''
      );
    },
    isSelectedPatientNotificationsMuted() {
      if (!this.hasSeparateSelectedPatient) return false;
      const patientId = Number(this.selectedPatient.id);
      if (
        Object.prototype.hasOwnProperty.call(
          this.localPatientMutedOverrides,
          patientId
        )
      ) {
        return Boolean(this.localPatientMutedOverrides[patientId]);
      }
      const storeVal =
        this.selectedPatientStoreContact?.notifications_muted ??
        this.selectedPatientStoreContact?.notificationsMuted;
      if (storeVal !== undefined) return Boolean(storeVal);
      return Boolean(
        this.selectedPatient?.notifications_muted ??
          this.selectedPatient?.notificationsMuted
      );
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
    contactClientLanguageDisplay() {
      return (
        formatClientLanguageSummary(
          this.additionalAttributes,
          this.contactClientLanguage,
          'ru'
        ) || '—'
      );
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
    customAttributes() {
      return (
        this.contact.custom_attributes || this.contact.customAttributes || {}
      );
    },
    dossierBirthDateDisplay() {
      const raw =
        this.additionalAttributes?.birth_date ||
        this.customAttributes?.birth_date ||
        this.customAttributes?.medelement_birth_date ||
        '';
      const trimmed = String(raw || '').trim();
      if (!trimmed) return '';
      const normalized = normalizePatientBirthDate(trimmed);
      if (!normalized) return trimmed;
      const [yearStr, monthStr, dayStr] = normalized.split('-');
      const formattedDate = `${dayStr}.${monthStr}.${yearStr}`;
      const year = Number(yearStr);
      const month = Number(monthStr);
      const day = Number(dayStr);
      const today = new Date();
      let age = today.getFullYear() - year;
      if (
        today.getMonth() + 1 < month ||
        (today.getMonth() + 1 === month && today.getDate() < day)
      ) {
        age -= 1;
      }
      if (age >= 0 && age <= 130) {
        return `${formattedDate} (${age} ${this.formatAgeWordRu(age)})`;
      }
      return formattedDate;
    },
    dossierIin() {
      const candidates = [
        this.customAttributes?.iin,
        this.customAttributes?.medelement_iin,
        this.contact?.identifier,
      ]
        .map(val => String(val || '').trim())
        .filter(Boolean);
      const twelveDigit = candidates.find(val => /^\d{12}$/.test(val));
      if (twelveDigit) return twelveDigit;
      const maskedCandidate = candidates.find(val => /^[•*]{6,}$/.test(val));
      if (maskedCandidate) return maskedCandidate;
      return String(
        this.customAttributes?.iin ||
          this.customAttributes?.medelement_iin ||
          ''
      ).trim();
    },
    isDossierIinMasked() {
      return /^[•*]+$/.test(this.dossierIin);
    },
    dossierGender() {
      const raw =
        this.customAttributes?.gender ??
        this.customAttributes?.medelement_gender ??
        this.additionalAttributes?.gender;
      if (raw === undefined || raw === null) return '';
      const trimmed = String(raw).trim();
      if (!trimmed) return '';
      const normalized = trimmed.toLowerCase();
      if (['male', 'm', 'м', 'мужской', 'муж', '2'].includes(normalized)) {
        return 'Мужской';
      }
      if (['female', 'f', 'ж', 'женский', 'жен', '1'].includes(normalized)) {
        return 'Женский';
      }
      return trimmed;
    },
    hasStructuredPhoneNumbers() {
      const list = this.contact?.phone_numbers ?? this.contact?.phoneNumbers;
      return Array.isArray(list);
    },
    primaryHeaderPhone() {
      if (this.contact?.phone_number) return this.contact.phone_number;
      if (this.contact?.phoneNumber) return this.contact.phoneNumber;
      const list = this.contact?.phone_numbers ?? this.contact?.phoneNumbers;
      if (Array.isArray(list) && list.length > 0) {
        return list[0]?.phone_number || list[0]?.phoneNumber || '';
      }
      return '';
    },
    isPrimaryHeaderPhoneEditable() {
      return Boolean(this.contact?.phone_number || this.contact?.phoneNumber);
    },
    channelOwnerContactId() {
      return this.communicationContact?.id ?? this.contact?.id;
    },
    dossierSecondaryPhones() {
      if (this.hasStructuredPhoneNumbers) return '';
      const raw = this.customAttributes?.secondary_phones;
      if (raw === undefined || raw === null) return '';
      if (Array.isArray(raw)) {
        return raw
          .map(item => String(item || '').trim())
          .filter(Boolean)
          .join(', ');
      }
      return String(raw).trim();
    },
    dossierAddress() {
      const raw =
        this.customAttributes?.address ??
        this.customAttributes?.medelement_address ??
        this.additionalAttributes?.address;
      if (raw === undefined || raw === null) return '';
      return String(raw).trim();
    },
    contactAttributeDefinitionsByKey() {
      const getter = this.$store?.getters?.['attributes/getAttributesByModel'];
      const definitions =
        typeof getter === 'function' ? getter('contact_attribute') : [];
      return (Array.isArray(definitions) ? definitions : []).reduce(
        (acc, item) => {
          const attrKey = item?.attribute_key || item?.attributeKey;
          if (attrKey) acc[attrKey] = item;
          return acc;
        },
        {}
      );
    },
    extraCustomAttributes() {
      const attrs = this.customAttributes || {};
      const defs = this.contactAttributeDefinitionsByKey;
      return Object.entries(attrs)
        .filter(([key, value]) => {
          if (
            DOSSIER_EXCLUDED_CUSTOM_ATTRIBUTE_KEYS.has(key) ||
            key.startsWith('medelement_')
          ) {
            return false;
          }
          if (value === undefined || value === null) return false;
          if (Array.isArray(value)) return value.length > 0;
          if (typeof value === 'object') return false;
          return String(value).trim() !== '';
        })
        .map(([key, value]) => {
          const def = defs[key];
          return {
            key,
            label:
              def?.attribute_display_name || def?.attributeDisplayName || key,
            description: String(
              def?.attribute_description || def?.attributeDescription || ''
            ).trim(),
            value: Array.isArray(value)
              ? value.join(', ')
              : String(value).trim(),
          };
        });
    },
    socialProfiles() {
      const {
        social_profiles: socialProfiles,
        screen_name: twitterScreenName,
        social_telegram_user_name: telegramUsername,
        social_instagram_user_name: instagramUsername,
        social_tiktok_user_name: tiktokUsername,
      } = this.additionalAttributes;

      const rawChannelProfiles =
        this.contact.channel_profiles || this.contact.channelProfiles;
      const channelProfiles = Array.isArray(rawChannelProfiles)
        ? rawChannelProfiles
        : [];
      const fromChannelProfile = providers => {
        const match = channelProfiles.find(
          item =>
            providers.includes(item?.provider) &&
            String(item?.username || '').trim()
        );
        return match ? String(match.username).trim() : '';
      };

      const telegram =
        socialProfiles?.telegram ||
        telegramUsername ||
        fromChannelProfile(['telegram', 'telegram_personal']) ||
        '';
      const twitter =
        socialProfiles?.twitter ||
        twitterScreenName ||
        fromChannelProfile(['twitter', 'twitter_profile']) ||
        '';
      const instagram =
        socialProfiles?.instagram ||
        instagramUsername ||
        fromChannelProfile(['instagram']) ||
        '';
      const tiktok =
        socialProfiles?.tiktok ||
        tiktokUsername ||
        fromChannelProfile(['tiktok']) ||
        '';

      return {
        ...(socialProfiles || {}),
        twitter,
        telegram,
        instagram,
        tiktok,
      };
    },
    // Delete Modal
    confirmDeleteMessage() {
      return ` ${this.contact.name}?`;
    },
    contactConversations() {
      return this.$store.getters[
        'contactConversations/getAllConversationsByContactId'
      ](this.channelOwnerContactId);
    },
    contactConversationsLoaded() {
      const contactId = Number(this.channelOwnerContactId);

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
    channelOwnerContactId: {
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
    formatAgeWordRu(age) {
      const mod100 = age % 100;
      const mod10 = age % 10;
      if (mod100 >= 11 && mod100 <= 14) return 'лет';
      if (mod10 === 1) return 'год';
      if (mod10 >= 2 && mod10 <= 4) return 'года';
      return 'лет';
    },
    async copyIin() {
      if (!this.dossierIin) return;
      await copyTextToClipboard(this.dossierIin);
      useAlert(this.$t('CONTACT_PANEL.COPY_SUCCESSFUL'));
    },
    refreshPatientContextStore() {
      const store = this.optionalPatientStore;
      if (!store || !this.patientContextKey) return;
      const entry = store.contexts?.[this.patientContextKey];
      if (!entry?.contactId) return;
      store.load(this.patientContextKey, entry.contactId, { force: true });
    },
    async toggleContactNotificationsMuted(nextValue) {
      if (!this.contact?.id || this.isSavingContactMute) return;
      const muted = Boolean(nextValue);
      this.isSavingContactMute = true;
      try {
        await this.$store.dispatch('contacts/update', {
          id: this.contact.id,
          notifications_muted: muted,
        });
        this.refreshPatientContextStore();
        useAlert(
          muted
            ? this.$t('CONTACT_PANEL.NOTIFICATIONS_MUTED_SAVED')
            : this.$t('CONTACT_PANEL.NOTIFICATIONS_UNMUTED_SAVED')
        );
      } catch (error) {
        useAlert(error?.message || this.$t('CONTACT_FORM.ERROR_MESSAGE'));
      } finally {
        this.isSavingContactMute = false;
      }
    },
    async toggleSelectedPatientNotificationsMuted(nextValue) {
      if (!this.hasSeparateSelectedPatient || this.isSavingPatientMute) return;
      const patientId = Number(this.selectedPatient.id);
      const muted = Boolean(nextValue);
      this.isSavingPatientMute = true;
      try {
        const updated = await this.$store.dispatch('contacts/update', {
          id: patientId,
          notifications_muted: muted,
        });
        this.localPatientMutedOverrides = {
          ...this.localPatientMutedOverrides,
          [patientId]: Boolean(
            updated?.notifications_muted ?? updated?.notificationsMuted ?? muted
          ),
        };
        useAlert(
          muted
            ? this.$t('CONTACT_PANEL.NOTIFICATIONS_MUTED_SAVED')
            : this.$t('CONTACT_PANEL.NOTIFICATIONS_UNMUTED_SAVED')
        );
      } catch (error) {
        useAlert(error?.message || this.$t('CONTACT_FORM.ERROR_MESSAGE'));
      } finally {
        this.isSavingPatientMute = false;
      }
    },

    async updateContactField(attrs) {
      const contactId = this.contact.id;
      try {
        await this.$store.dispatch('contacts/update', {
          id: contactId,
          ...attrs,
        });
        this.refreshPatientContextStore();
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
              v-if="primaryHeaderPhone"
              :href="`tel:${primaryHeaderPhone}`"
              :value="primaryHeaderPhone"
              icon="call"
              emoji="📞"
              :title="$t('CONTACT_PANEL.PHONE_NUMBER')"
              show-copy
              :editable="isPrimaryHeaderPhoneEditable"
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
          <NextButton
            v-if="patientContextKey"
            v-tooltip.top-end="$t('PATIENT_TABS.ADD_FAMILY_CARD')"
            data-testid="contact-add-family-card-button"
            icon="i-lucide-user-plus"
            slate
            faded
            sm
            :disabled="
              Boolean(
                patientEntry && (!patientEntry.loaded || patientEntry.saving)
              )
            "
            :aria-label="$t('PATIENT_TABS.ADD_FAMILY_CARD')"
            @click="showFamilyCardModal = true"
          />
        </div>
        <ContactPhonesManager
          v-if="contact && contact.id"
          :contact="contact"
          :patient-context-key="patientContextKey"
          compact
        />
        <FamilyPatientCardModal
          v-if="patientContextKey"
          v-model:show="showFamilyCardModal"
          :context-key="patientContextKey"
          :contact-id="communicationContact?.id || contact?.id"
          :conversation-display-id="patientConversationDisplayId"
        />
        <div
          data-testid="contact-dossier"
          data-test="contact-dossier"
          class="mt-1 flex w-full flex-col gap-1 rounded-xl border border-n-weak bg-n-alpha-1 p-3"
        >
          <div
            class="mb-1 text-[11px] font-medium uppercase tracking-wide text-n-slate-11"
          >
            {{ 'Досье контакта' }}
          </div>
          <div
            v-if="dossierBirthDateDisplay"
            data-testid="contact-dossier-birth-date"
            class="flex items-center justify-between gap-2 py-1 text-xs"
          >
            <span class="text-n-slate-11">{{ 'Дата рождения' }}</span>
            <span class="font-medium text-n-slate-12">{{
              dossierBirthDateDisplay
            }}</span>
          </div>
          <div
            v-if="dossierIin"
            data-testid="contact-dossier-iin"
            class="flex items-center justify-between gap-2 py-1 text-xs"
          >
            <span class="text-n-slate-11">{{ 'ИИН' }}</span>
            <span
              class="inline-flex items-center gap-1.5 font-medium text-n-slate-12"
            >
              <span>{{ dossierIin }}</span>
              <button
                v-if="!isDossierIinMasked"
                type="button"
                data-testid="contact-dossier-iin-copy"
                data-test="contact-dossier-iin-copy"
                class="inline-flex items-center text-n-slate-10 hover:text-n-slate-12"
                :title="$t('CONTACT_PANEL.COPY_SUCCESSFUL')"
                @click="copyIin"
              >
                <span class="i-lucide-copy size-3" />
              </button>
            </span>
          </div>
          <div
            v-if="dossierGender"
            data-testid="contact-dossier-gender"
            class="flex items-center justify-between gap-2 py-1 text-xs"
          >
            <span class="text-n-slate-11">{{ 'Пол' }}</span>
            <span class="font-medium text-n-slate-12">{{ dossierGender }}</span>
          </div>
          <div
            v-if="dossierSecondaryPhones"
            data-testid="contact-dossier-secondary-phones"
            class="flex items-center justify-between gap-2 py-1 text-xs"
          >
            <span class="text-n-slate-11">{{ 'Доп. телефон' }}</span>
            <span class="font-medium text-n-slate-12">{{
              dossierSecondaryPhones
            }}</span>
          </div>
          <div
            v-if="dossierAddress"
            data-testid="contact-dossier-address"
            class="flex items-center justify-between gap-2 py-1 text-xs"
          >
            <span class="text-n-slate-11">{{ 'Адрес' }}</span>
            <span class="text-right font-medium text-n-slate-12">{{
              dossierAddress
            }}</span>
          </div>
          <div
            v-for="attr in extraCustomAttributes"
            :key="attr.key"
            :data-testid="`contact-dossier-attr-${attr.key}`"
            class="flex items-center justify-between gap-2 py-1 text-xs"
          >
            <span
              class="inline-flex min-w-0 items-center gap-1 text-n-slate-11"
            >
              <span class="truncate">{{ attr.label }}</span>
              <CrmCustomFieldDescriptionHint
                v-if="attr.description"
                :description="attr.description"
                :label="attr.label"
              />
            </span>
            <span class="text-right font-medium text-n-slate-12">{{
              attr.value
            }}</span>
          </div>
          <div
            class="flex items-center justify-between gap-2 py-1 text-xs"
            data-test="contact-client-language-row"
            data-testid="contact-client-language-row"
          >
            <span class="shrink-0 text-n-slate-11">{{ 'Язык' }}</span>
            <span
              class="text-right font-medium text-n-slate-12"
              data-test="contact-client-language-badge"
              data-testid="contact-client-language-badge"
            >
              {{ contactClientLanguageDisplay }}
            </span>
          </div>
          <div
            class="mt-1 flex items-center justify-between gap-2 border-t border-n-weak pt-2 text-xs"
            data-test="contact-notifications-muted-row"
            data-testid="contact-notifications-muted-row"
          >
            <div class="flex min-w-0 flex-col gap-0.5">
              <span
                v-tooltip.top="$t('CONTACT_PANEL.NOTIFICATIONS_MUTED_HINT')"
                class="inline-flex min-w-0 items-center gap-1 text-n-slate-11"
              >
                <span class="truncate">{{
                  $t('CONTACT_PANEL.NOTIFICATIONS_MUTED_LABEL')
                }}</span>
                <span
                  class="i-lucide-info size-3 shrink-0 text-n-slate-10"
                  aria-hidden="true"
                />
              </span>
              <span
                v-if="isContactNotificationsMuted"
                data-testid="contact-notifications-muted-status"
                class="text-[11px] font-medium text-n-amber-11"
              >
                {{ $t('CONTACT_PANEL.NOTIFICATIONS_MUTED_STATUS') }}
              </span>
            </div>
            <ToggleSwitch
              data-testid="contact-notifications-muted-toggle"
              data-test="contact-notifications-muted-toggle"
              :model-value="isContactNotificationsMuted"
              :disabled="isSavingContactMute"
              :aria-label="$t('CONTACT_PANEL.NOTIFICATIONS_MUTED_LABEL')"
              @change="toggleContactNotificationsMuted"
            />
          </div>
          <div
            v-if="hasSeparateSelectedPatient"
            class="flex items-center justify-between gap-2 pt-1 text-xs"
            data-test="patient-notifications-muted-row"
            data-testid="patient-notifications-muted-row"
          >
            <div class="flex min-w-0 flex-col gap-0.5">
              <span
                v-tooltip.top="$t('CONTACT_PANEL.NOTIFICATIONS_MUTED_HINT')"
                class="inline-flex min-w-0 items-center gap-1 text-n-slate-11"
              >
                <span class="truncate">{{
                  $t('CONTACT_PANEL.NOTIFICATIONS_MUTED_PATIENT_LABEL', {
                    name: selectedPatientName,
                  })
                }}</span>
              </span>
              <span
                v-if="isSelectedPatientNotificationsMuted"
                data-testid="patient-notifications-muted-status"
                class="text-[11px] font-medium text-n-amber-11"
              >
                {{ $t('CONTACT_PANEL.NOTIFICATIONS_MUTED_STATUS') }}
              </span>
            </div>
            <ToggleSwitch
              data-testid="patient-notifications-muted-toggle"
              data-test="patient-notifications-muted-toggle"
              :model-value="isSelectedPatientNotificationsMuted"
              :disabled="isSavingPatientMute"
              :aria-label="
                $t('CONTACT_PANEL.NOTIFICATIONS_MUTED_PATIENT_LABEL', {
                  name: selectedPatientName,
                })
              "
              @change="toggleSelectedPatientNotificationsMuted"
            />
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
