<script setup>
import { ref, computed, watch } from 'vue';
import camelcaseKeys from 'camelcase-keys';
import { useI18n } from 'vue-i18n';
import { formatDistanceToNow } from 'date-fns';
import { useAlert } from 'dashboard/composables';
import { useMapGetter } from 'dashboard/composables/store';
import { useRoute, useRouter } from 'vue-router';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { CRM_DEAL_MANAGE_PERMISSION } from 'dashboard/constants/permissions';
import { usePolicy } from 'dashboard/composables/usePolicy';

import CardLayout from 'dashboard/components-next/CardLayout.vue';
import CompanyForm from 'dashboard/components-next/Companies/CompanyForm/CompanyForm.vue';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import { useCompaniesStore } from 'dashboard/stores/companies';
import CompanyAPI from 'dashboard/api/companies';

const props = defineProps({
  id: { type: Number, required: true },
  name: { type: String, default: '' },
  domain: { type: String, default: '' },
  contactsCount: { type: Number, default: 0 },
  description: { type: String, default: '' },
  avatarUrl: { type: String, default: '' },
  updatedAt: { type: [String, Number], default: null },
  isExpanded: { type: Boolean, default: false },
});

const emit = defineEmits(['toggle', 'deleted', 'updated']);

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const companiesStore = useCompaniesStore();
const { checkPermissions } = usePolicy();
const accountId = useMapGetter('getCurrentAccountId');
const isFeatureEnabledonAccount = useMapGetter(
  'accounts/isFeatureEnabledonAccount'
);

const companyFormRef = ref(null);
const deleteDialogRef = ref(null);
const companyData = ref({});
const companyDetails = ref(null);
const isLoadingContacts = ref(false);

const uiFlags = computed(() => companiesStore.getUIFlags);
const isUpdating = computed(() => uiFlags.value.updatingItem);
const displayName = computed(() => props.name || t('COMPANIES.UNNAMED'));
const avatarSource = computed(() => props.avatarUrl || null);
const isFormInvalid = computed(() => companyFormRef.value?.isFormInvalid);
const companyContacts = computed(() => companyDetails.value?.contacts || []);
const canDeleteCompany = computed(() => checkPermissions(['administrator']));
const canCreateCrmDeal = computed(() => {
  return (
    isFeatureEnabledonAccount.value(accountId.value, FEATURE_FLAGS.CRM_DEALS) &&
    checkPermissions(['administrator', CRM_DEAL_MANAGE_PERMISSION])
  );
});

const getInitialCompanyData = () => ({
  id: props.id,
  name: props.name,
  domain: props.domain,
  description: props.description,
  updatedAt: props.updatedAt,
});

watch(
  () => [
    props.id,
    props.name,
    props.domain,
    props.description,
    props.contactsCount,
    props.updatedAt,
  ],
  () => {
    companyData.value = getInitialCompanyData();
  },
  { immediate: true }
);

const formattedUpdatedAt = computed(() => {
  if (!props.updatedAt) return '';

  const date =
    typeof props.updatedAt === 'number'
      ? new Date(
          props.updatedAt > 9999999999
            ? props.updatedAt
            : props.updatedAt * 1000
        )
      : new Date(props.updatedAt);

  if (Number.isNaN(date.getTime())) return '';

  return formatDistanceToNow(date, { addSuffix: true });
});

const handleFormUpdate = updatedData => {
  Object.assign(companyData.value, updatedData);
};

const handleToggle = () => {
  emit('toggle');
  companyData.value = getInitialCompanyData();
  companyFormRef.value?.resetToCompany(companyData.value);
};

const contactSubtitle = contact => {
  return (
    contact.email ||
    contact.phoneNumber ||
    contact.identifier ||
    t('COMPANIES.DETAILS.CONTACTS.NO_DETAILS')
  );
};

const contactRoute = contact => ({
  name: 'contacts_edit',
  params: {
    accountId: route.params.accountId,
    contactId: contact.id,
  },
});

const loadCompanyDetails = async () => {
  if (!props.isExpanded) return;

  isLoadingContacts.value = true;
  try {
    const {
      data: { payload },
    } = await CompanyAPI.show(props.id);
    companyDetails.value = camelcaseKeys(payload, { deep: true });
  } catch {
    useAlert(t('COMPANIES.DETAILS.CONTACTS.ERROR'));
  } finally {
    isLoadingContacts.value = false;
  }
};

const updateCompany = async () => {
  try {
    await companiesStore.update(companyData.value);
    useAlert(t('COMPANIES.FORM.SUCCESS.UPDATE'));
    emit('updated', props.id);
  } catch {
    useAlert(t('COMPANIES.FORM.ERROR.UPDATE'));
  }
};

const openDeleteDialog = () => {
  deleteDialogRef.value?.open();
};

const deleteCompany = async () => {
  try {
    await companiesStore.delete(props.id);
    useAlert(t('COMPANIES.FORM.SUCCESS.DELETE'));
    emit('deleted', props.id);
    deleteDialogRef.value?.close();
  } catch {
    useAlert(t('COMPANIES.FORM.ERROR.DELETE'));
  }
};

const createDealForCompany = () => {
  router.push({
    name: 'crm_deals_index',
    params: { accountId: route.params.accountId },
    query: {
      action: 'new',
      companyId: props.id,
      companyName: props.name || undefined,
      source: 'company',
    },
  });
};

watch(
  () => [props.isExpanded, props.id, props.updatedAt],
  ([isExpanded]) => {
    if (isExpanded) {
      loadCompanyDetails();
    }
  },
  { immediate: true }
);
</script>

<template>
  <div class="relative">
    <CardLayout layout="row">
      <div
        class="flex items-center justify-start flex-1 gap-4 min-w-0 cursor-pointer"
        @click="handleToggle"
      >
        <Avatar
          :username="displayName"
          :src="avatarSource"
          class="shrink-0"
          :name="name"
          :size="48"
          hide-offline-status
          rounded-full
        />
        <div class="flex flex-col gap-0.5 flex-1 min-w-0">
          <div class="flex flex-wrap items-center gap-x-4 gap-y-1 min-w-0">
            <span class="text-base font-medium truncate text-n-slate-12">
              {{ displayName }}
            </span>
            <span
              v-if="domain && description"
              class="inline-flex items-center gap-1.5 text-sm text-n-slate-11 truncate"
            >
              <Icon icon="i-lucide-globe" size="size-3.5 text-n-slate-11" />
              <span class="truncate">{{ domain }}</span>
            </span>
          </div>
          <div
            class="flex flex-wrap items-center justify-start gap-x-3 gap-y-1"
          >
            <span
              v-if="domain && !description"
              class="inline-flex items-center gap-1.5 text-sm text-n-slate-11 truncate"
            >
              <Icon icon="i-lucide-globe" size="size-3.5 text-n-slate-11" />
              <span class="truncate">{{ domain }}</span>
            </span>
            <span v-if="description" class="text-sm text-n-slate-11 truncate">
              {{ description }}
            </span>
            <div
              v-if="(description || domain) && contactsCount"
              class="w-px h-3 bg-n-slate-6"
            />
            <span
              v-if="contactsCount"
              class="inline-flex items-center gap-1.5 text-sm text-n-slate-11 truncate"
            >
              <Icon icon="i-lucide-contact" size="size-3.5 text-n-slate-11" />
              {{ t('COMPANIES.CONTACTS_COUNT', { n: contactsCount }) }}
            </span>
          </div>
        </div>
      </div>

      <div class="flex items-center gap-2 cursor-pointer" @click="handleToggle">
        <span
          v-if="formattedUpdatedAt"
          class="inline-flex items-center gap-1.5 text-sm text-n-slate-11 flex-shrink-0"
        >
          {{ formattedUpdatedAt }}
        </span>
        <Button
          icon="i-lucide-chevron-down"
          variant="ghost"
          color="slate"
          size="xs"
          :class="{ 'rotate-180': isExpanded }"
          @click.stop="handleToggle"
        />
      </div>

      <template #after>
        <div
          class="transition-all duration-500 ease-in-out grid overflow-hidden"
          :class="
            isExpanded
              ? 'grid-rows-[1fr] opacity-100'
              : 'grid-rows-[0fr] opacity-0'
          "
        >
          <div class="overflow-hidden">
            <div class="flex flex-col gap-6 p-6 border-t border-n-strong">
              <div class="flex flex-col gap-3">
                <div class="flex items-center justify-between gap-3">
                  <div class="flex items-center gap-2">
                    <Icon icon="i-lucide-users" size="size-4 text-n-slate-11" />
                    <span class="text-sm font-medium text-n-slate-12">
                      {{
                        t('COMPANIES.DETAILS.CONTACTS.TITLE', {
                          n: contactsCount,
                        })
                      }}
                    </span>
                  </div>
                </div>

                <div
                  v-if="isLoadingContacts"
                  class="flex items-center gap-2 text-sm text-n-slate-11"
                >
                  <Spinner :size="16" />
                  <span>{{ t('COMPANIES.DETAILS.CONTACTS.LOADING') }}</span>
                </div>

                <div
                  v-else-if="companyContacts.length"
                  class="grid gap-2 max-h-60 overflow-auto pr-1"
                >
                  <router-link
                    v-for="contact in companyContacts"
                    :key="contact.id"
                    :to="contactRoute(contact)"
                    class="flex items-center gap-3 rounded-xl border border-n-weak bg-n-alpha-2 px-3 py-2 transition-colors hover:bg-n-alpha-3"
                  >
                    <Avatar
                      :username="
                        contact.name || contact.identifier || `#${contact.id}`
                      "
                      :src="contact.thumbnail || null"
                      :name="
                        contact.name || contact.identifier || `#${contact.id}`
                      "
                      :size="32"
                      hide-offline-status
                      rounded-full
                      class="shrink-0"
                    />
                    <div class="min-w-0 flex-1">
                      <p
                        class="mb-0 truncate text-sm font-medium text-n-slate-12"
                      >
                        {{
                          contact.name || contact.identifier || `#${contact.id}`
                        }}
                      </p>
                      <p class="mb-0 truncate text-xs text-n-slate-11">
                        {{ contactSubtitle(contact) }}
                      </p>
                    </div>
                    <Icon
                      icon="i-lucide-chevron-right"
                      size="size-4 text-n-slate-10"
                    />
                  </router-link>
                </div>

                <p v-else class="mb-0 text-sm text-n-slate-11">
                  {{ t('COMPANIES.DETAILS.CONTACTS.EMPTY') }}
                </p>
              </div>

              <CompanyForm
                ref="companyFormRef"
                :company-data="companyData"
                @update="handleFormUpdate"
              />
              <div class="flex flex-wrap items-center justify-between gap-3">
                <Button
                  v-if="canCreateCrmDeal"
                  :label="t('CRM.DEALS.NEW_DEAL')"
                  size="sm"
                  color="slate"
                  @click="createDealForCompany"
                />
                <div class="flex items-center gap-2 ml-auto">
                  <Button
                    :label="t('COMPANIES.ACTIONS.SAVE')"
                    size="sm"
                    :is-loading="isUpdating"
                    :disabled="isUpdating || isFormInvalid"
                    @click="updateCompany"
                  />
                  <Button
                    v-if="canDeleteCompany"
                    icon="i-lucide-trash"
                    variant="ghost"
                    color="ruby"
                    size="sm"
                    :title="t('COMPANIES.ACTIONS.DELETE')"
                    :aria-label="t('COMPANIES.ACTIONS.DELETE')"
                    @click="openDeleteDialog"
                  />
                </div>
              </div>
            </div>
          </div>
        </div>
      </template>
    </CardLayout>

    <Dialog
      ref="deleteDialogRef"
      type="alert"
      :title="t('COMPANIES.DETAILS.DELETE_DIALOG.TITLE')"
      :description="t('COMPANIES.DETAILS.DELETE_DIALOG.DESCRIPTION')"
      :confirm-button-label="t('COMPANIES.DETAILS.DELETE_DIALOG.CONFIRM')"
      @confirm="deleteCompany"
    />
  </div>
</template>
