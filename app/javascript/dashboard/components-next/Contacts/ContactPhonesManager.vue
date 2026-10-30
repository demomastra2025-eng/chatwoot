<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import { useStore } from 'vuex';
import ContactPhonesAPI from 'dashboard/api/contactPhones';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import PhoneNumberInput from 'dashboard/components-next/phonenumberinput/PhoneNumberInput.vue';
import { useAlert } from 'dashboard/composables';
import { resolveOptionalPatientStore } from 'dashboard/composables/useConversationPatientContext';
import { copyTextToClipboard } from 'shared/helpers/clipboard';

const props = defineProps({
  contact: {
    type: Object,
    default: () => ({}),
  },
  compact: {
    type: Boolean,
    default: false,
  },
  patientContextKey: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['updated']);

const { t } = useI18n();
const route = useRoute();
const store = useStore();
const patientStore = resolveOptionalPatientStore();

const isAdding = ref(false);
const isSubmitting = ref(false);
const busyPhoneId = ref(null);
const newPhone = ref('');
const newLabel = ref('');
const errorMessage = ref('');
const conflictState = ref(null);

const contactId = computed(() => Number(props.contact?.id) || null);
const accountId = computed(
  () =>
    route?.params?.accountId ||
    store?.getters?.getCurrentAccountId ||
    props.contact?.account_id ||
    props.contact?.accountId ||
    ''
);

const contactUrl = targetContactId =>
  `/app/accounts/${accountId.value}/contacts/${targetContactId}`;

const phoneEntries = computed(() => {
  const rawList = props.contact?.phone_numbers ?? props.contact?.phoneNumbers;
  if (Array.isArray(rawList) && rawList.length > 0) {
    return rawList
      .map(entry => ({
        id: entry.id ?? null,
        phoneNumber: entry.phone_number || entry.phoneNumber || '',
        primary: Boolean(entry.primary),
        shared: Boolean(entry.shared),
        label: entry.label || '',
        ownerContactId: entry.owner_contact_id ?? entry.ownerContactId ?? null,
        ownerContact: entry.owner_contact || entry.ownerContact || null,
        sharedContacts: entry.shared_contacts || entry.sharedContacts || [],
      }))
      .filter(entry => Boolean(entry.phoneNumber));
  }

  const fallback = [];
  const primaryPhone =
    props.contact?.phone_number || props.contact?.phoneNumber || '';
  if (primaryPhone) {
    fallback.push({
      id: null,
      phoneNumber: primaryPhone,
      primary: true,
      shared: false,
      label: '',
      ownerContactId: null,
      ownerContact: null,
      sharedContacts: [],
    });
  }
  const attrs =
    props.contact?.custom_attributes || props.contact?.customAttributes || {};
  const sharedPhone = attrs.medelement_shared_phone_number || '';
  if (sharedPhone && sharedPhone !== primaryPhone) {
    fallback.push({
      id: null,
      phoneNumber: sharedPhone,
      primary: false,
      shared: true,
      label: '',
      ownerContactId: attrs.medelement_shared_phone_owner_contact_id || null,
      ownerContact: null,
      sharedContacts: [],
    });
  }
  return fallback;
});

const resetAddState = () => {
  isAdding.value = false;
  newPhone.value = '';
  newLabel.value = '';
  errorMessage.value = '';
  conflictState.value = null;
};

watch(contactId, () => {
  resetAddState();
});

const openAddForm = () => {
  errorMessage.value = '';
  conflictState.value = null;
  isAdding.value = true;
};

const syncAfterMutation = async (response, extraContactId = null) => {
  const payload = response?.data?.payload || response?.data;
  if (payload) {
    emit('updated', payload);
  }
  if (contactId.value && store?.dispatch) {
    await store.dispatch('contacts/show', { id: contactId.value });
  }
  if (extraContactId && store?.dispatch) {
    store.dispatch('contacts/show', { id: extraContactId });
  }
  if (patientStore) {
    const keys = props.patientContextKey
      ? [props.patientContextKey]
      : Object.keys(patientStore.contexts || {});
    await Promise.all(
      keys.map(key => {
        const entry = patientStore.contexts[key];
        if (!entry?.contactId) return Promise.resolve();
        return patientStore.load(key, entry.contactId, { force: true });
      })
    );
  }
};

const submitPhone = async ({ linkShared = false } = {}) => {
  const targetPhone =
    (linkShared && conflictState.value?.phoneNumber) || newPhone.value.trim();
  if (!contactId.value || !targetPhone || isSubmitting.value) return;

  isSubmitting.value = true;
  errorMessage.value = '';
  try {
    const ownerToRefresh = conflictState.value?.ownerContact?.id || null;
    const response = await ContactPhonesAPI.create(contactId.value, {
      phone_number: targetPhone,
      label: newLabel.value.trim() || undefined,
      ...(linkShared ? { link_shared: true } : {}),
    });
    await syncAfterMutation(response, ownerToRefresh);
    useAlert(
      linkShared
        ? t('CONTACT_PHONES.SHARED_LINKED_SUCCESS')
        : t('CONTACT_PHONES.ADDED_SUCCESS')
    );
    resetAddState();
  } catch (error) {
    const status = error?.response?.status;
    const data = error?.response?.data || {};
    if (status === 409 && data.code === 'PHONE_OWNED_BY_OTHER_CONTACT') {
      conflictState.value = {
        phoneNumber: data.phone_number || targetPhone,
        canLinkShared: Boolean(data.can_link_shared),
        ownerContact: data.owner_contact || null,
      };
      return;
    }
    errorMessage.value = data.error || t('CONTACT_PHONES.ERROR_GENERIC');
  } finally {
    isSubmitting.value = false;
  }
};

const promotePrimary = async entry => {
  if (!contactId.value || !entry?.id || busyPhoneId.value) return;
  busyPhoneId.value = entry.id;
  try {
    const response = await ContactPhonesAPI.setPrimary(
      contactId.value,
      entry.id
    );
    await syncAfterMutation(response);
    useAlert(t('CONTACT_PHONES.PRIMARY_UPDATED_SUCCESS'));
  } catch (error) {
    useAlert(error?.response?.data?.error || t('CONTACT_PHONES.ERROR_GENERIC'));
  } finally {
    busyPhoneId.value = null;
  }
};

const removePhone = async entry => {
  if (!contactId.value || !entry?.id || busyPhoneId.value) return;
  busyPhoneId.value = entry.id;
  try {
    const response = await ContactPhonesAPI.destroy(contactId.value, entry.id);
    await syncAfterMutation(response, entry.ownerContactId);
    useAlert(t('CONTACT_PHONES.REMOVED_SUCCESS'));
  } catch (error) {
    useAlert(error?.response?.data?.error || t('CONTACT_PHONES.ERROR_GENERIC'));
  } finally {
    busyPhoneId.value = null;
  }
};

const copyPhone = async phone => {
  if (!phone) return;
  await copyTextToClipboard(phone);
  useAlert(t('CONTACT_PANEL.COPY_SUCCESSFUL'));
};

const badgeText = entry => {
  if (entry.primary) return t('CONTACT_PHONES.BADGES.PRIMARY_SHORT');
  if (entry.shared) return t('CONTACT_PHONES.BADGES.SHARED_SHORT');
  return t('CONTACT_PHONES.BADGES.SECONDARY_SHORT');
};

const badgeClass = entry => {
  if (entry.primary) {
    return 'bg-n-teal-3/70 text-n-teal-11';
  }
  if (entry.shared) {
    return 'bg-n-amber-3/70 text-n-amber-11';
  }
  return 'bg-n-slate-3 text-n-slate-11';
};
</script>

<template>
  <div
    data-testid="contact-phones-manager"
    class="flex w-full flex-col gap-2 rounded-xl"
    :class="
      compact
        ? 'border border-n-weak bg-n-alpha-1 p-3'
        : 'bg-n-solid-2 px-4 py-3.5 outline outline-1 outline-n-container'
    "
  >
    <div class="flex items-center justify-between gap-2">
      <span
        class="font-medium text-n-slate-11"
        :class="
          compact
            ? 'text-[11px] uppercase tracking-wide'
            : 'text-sm text-n-slate-12'
        "
      >
        {{ t('CONTACT_PHONES.TITLE') }}
      </span>
      <button
        v-if="!isAdding"
        type="button"
        data-testid="contact-phones-add-trigger"
        class="inline-flex items-center gap-1 text-xs font-medium text-n-blue-11 hover:underline cursor-pointer"
        @click="openAddForm"
      >
        <span class="i-lucide-plus size-3.5" />
        <span>{{ t('CONTACT_PHONES.ADD_BUTTON') }}</span>
      </button>
    </div>

    <div
      v-if="phoneEntries.length > 0"
      class="flex flex-col divide-y divide-n-weak/70"
    >
      <div
        v-for="entry in phoneEntries"
        :key="entry.id || entry.phoneNumber"
        data-testid="contact-phone-row"
        class="flex flex-col gap-1 py-2 first:pt-0.5 last:pb-0.5"
      >
        <div class="flex items-center justify-between gap-2">
          <div class="flex min-w-0 flex-wrap items-center gap-1.5">
            <a
              :href="`tel:${entry.phoneNumber}`"
              class="truncate font-medium text-n-slate-12 tabular-nums hover:underline"
              :class="compact ? 'text-xs' : 'text-sm'"
            >
              {{ entry.phoneNumber }}
            </a>
            <span
              data-testid="contact-phone-badge"
              class="inline-flex shrink-0 items-center rounded-full px-1.5 py-0.5 text-[10px] font-medium leading-none"
              :class="badgeClass(entry)"
            >
              {{ badgeText(entry) }}
            </span>
            <span
              v-if="entry.label"
              class="truncate rounded bg-n-alpha-2 px-1.5 py-0.5 text-[10px] text-n-slate-11"
            >
              {{ entry.label }}
            </span>
          </div>

          <div class="flex shrink-0 items-center gap-1">
            <button
              type="button"
              data-testid="contact-phone-copy"
              class="inline-flex size-6 items-center justify-center rounded-md text-n-slate-10 hover:bg-n-alpha-2 hover:text-n-slate-12"
              :title="t('CONTACT_PHONES.COPY')"
              :aria-label="t('CONTACT_PHONES.COPY')"
              @click="copyPhone(entry.phoneNumber)"
            >
              <span class="i-lucide-copy size-3.5" />
            </button>
            <button
              v-if="!entry.primary && !entry.shared && entry.id"
              type="button"
              data-testid="contact-phone-set-primary"
              :disabled="Boolean(busyPhoneId)"
              class="inline-flex h-6 items-center gap-1 rounded-md px-1.5 text-[11px] font-medium text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12 disabled:opacity-50"
              :title="t('CONTACT_PHONES.SET_PRIMARY')"
              @click="promotePrimary(entry)"
            >
              <span class="i-lucide-star size-3" />
              <span v-if="!compact">{{ t('CONTACT_PHONES.SET_PRIMARY') }}</span>
            </button>
            <button
              v-if="entry.id"
              type="button"
              data-testid="contact-phone-remove"
              :disabled="Boolean(busyPhoneId)"
              class="inline-flex size-6 items-center justify-center rounded-md text-n-slate-10 hover:bg-n-ruby-3/40 hover:text-n-ruby-11 disabled:opacity-50"
              :title="
                entry.shared
                  ? t('CONTACT_PHONES.UNLINK_SHARED')
                  : t('CONTACT_PHONES.REMOVE')
              "
              :aria-label="
                entry.shared
                  ? t('CONTACT_PHONES.UNLINK_SHARED')
                  : t('CONTACT_PHONES.REMOVE')
              "
              @click="removePhone(entry)"
            >
              <span class="i-lucide-trash-2 size-3.5" />
            </button>
          </div>
        </div>

        <div
          v-if="entry.shared && entry.ownerContact?.id"
          data-testid="contact-phone-owner-info"
          class="flex flex-wrap items-center gap-1 text-xs text-n-slate-11"
        >
          <span>{{ t('CONTACT_PHONES.OWNER_PREFIX') }}</span>
          <router-link
            :to="contactUrl(entry.ownerContact.id)"
            data-testid="contact-phone-owner-link"
            class="font-medium text-n-blue-11 hover:underline"
          >
            {{ entry.ownerContact.name }}
          </router-link>
        </div>

        <div
          v-if="entry.sharedContacts && entry.sharedContacts.length > 0"
          data-testid="contact-phone-shared-peers"
          class="flex flex-wrap items-center gap-1 text-xs text-n-slate-11"
        >
          <span>{{ t('CONTACT_PHONES.SHARED_WITH_PREFIX') }}</span>
          <template v-for="(peer, idx) in entry.sharedContacts" :key="peer.id">
            <router-link
              :to="contactUrl(peer.id)"
              data-testid="contact-phone-shared-peer-link"
              class="font-medium text-n-blue-11 hover:underline"
            >
              {{ peer.name }}
            </router-link>
            <span v-if="idx < entry.sharedContacts.length - 1">{{ ',' }}</span>
          </template>
        </div>
      </div>
    </div>

    <form
      v-if="isAdding"
      data-testid="contact-phones-add-form"
      class="mt-1 flex flex-col gap-2 rounded-lg border border-n-weak bg-n-solid-1 p-2.5"
      @submit.prevent="submitPhone({ linkShared: false })"
    >
      <PhoneNumberInput
        v-model="newPhone"
        default-country="KZ"
        show-border
        :placeholder="t('CONTACT_PHONES.PHONE_PLACEHOLDER')"
      />
      <Input
        v-model="newLabel"
        size="sm"
        data-testid="contact-phones-label-input"
        :placeholder="t('CONTACT_PHONES.LABEL_PLACEHOLDER')"
        :disabled="isSubmitting"
      />

      <div
        v-if="conflictState"
        data-testid="contact-phone-conflict-banner"
        class="flex flex-col gap-2 rounded-lg border border-n-amber-6/40 bg-n-amber-2 p-2.5 text-xs text-n-slate-12"
      >
        <div class="flex flex-wrap items-center gap-1">
          <span>{{
            t('CONTACT_PHONES.CONFLICT_TITLE', {
              phone: conflictState.phoneNumber,
            })
          }}</span>
          <router-link
            v-if="conflictState.ownerContact?.id"
            :to="contactUrl(conflictState.ownerContact.id)"
            data-testid="contact-phone-conflict-owner-link"
            class="font-semibold text-n-blue-11 hover:underline"
          >
            {{ conflictState.ownerContact.name }}
          </router-link>
        </div>
        <p class="m-0 text-[11px] text-n-slate-11">
          {{ t('CONTACT_PHONES.CONFLICT_HINT') }}
        </p>
        <Button
          v-if="conflictState.canLinkShared"
          type="button"
          size="xs"
          color="blue"
          data-testid="contact-phone-link-shared-confirm"
          :is-loading="isSubmitting"
          :disabled="isSubmitting"
          :label="t('CONTACT_PHONES.LINK_SHARED_BUTTON')"
          @click="submitPhone({ linkShared: true })"
        />
      </div>

      <p
        v-if="errorMessage"
        data-testid="contact-phone-error"
        class="m-0 text-xs text-n-ruby-9"
        role="alert"
      >
        {{ errorMessage }}
      </p>

      <div class="flex justify-end gap-2">
        <Button
          type="button"
          size="xs"
          variant="ghost"
          :disabled="isSubmitting"
          :label="t('CONTACT_PHONES.CANCEL')"
          @click="resetAddState"
        />
        <Button
          type="submit"
          size="xs"
          data-testid="contact-phones-save-button"
          :disabled="!newPhone.trim() || isSubmitting"
          :is-loading="isSubmitting"
          :label="t('CONTACT_PHONES.SAVE')"
        />
      </div>
    </form>
  </div>
</template>
