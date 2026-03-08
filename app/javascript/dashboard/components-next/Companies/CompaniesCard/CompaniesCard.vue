<script setup>
import { ref, computed, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { formatDistanceToNow } from 'date-fns';
import { useAlert } from 'dashboard/composables';

import CardLayout from 'dashboard/components-next/CardLayout.vue';
import CompanyForm from 'dashboard/components-next/Companies/CompanyForm/CompanyForm.vue';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Policy from 'dashboard/components/policy.vue';
import { useCompaniesStore } from 'dashboard/stores/companies';

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

const emit = defineEmits(['toggle', 'deleted']);

const { t } = useI18n();
const companiesStore = useCompaniesStore();

const companyFormRef = ref(null);
const deleteDialogRef = ref(null);
const companyData = ref({});

const uiFlags = computed(() => companiesStore.getUIFlags);
const isUpdating = computed(() => uiFlags.value.updatingItem);
const displayName = computed(() => props.name || t('COMPANIES.UNNAMED'));
const avatarSource = computed(() => props.avatarUrl || null);
const isFormInvalid = computed(() => companyFormRef.value?.isFormInvalid);

const getInitialCompanyData = () => ({
  id: props.id,
  name: props.name,
  domain: props.domain,
  description: props.description,
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
};

const updateCompany = async () => {
  try {
    await companiesStore.update(companyData.value);
    useAlert(t('COMPANIES.FORM.SUCCESS.UPDATE'));
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
</script>

<template>
  <div class="relative">
    <CardLayout layout="row">
      <div class="flex items-center justify-start flex-1 gap-4">
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

      <div class="flex items-center gap-2">
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
          @click="handleToggle"
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
              <CompanyForm
                ref="companyFormRef"
                :company-data="companyData"
                @update="handleFormUpdate"
              />
              <div>
                <Button
                  :label="t('COMPANIES.ACTIONS.SAVE')"
                  size="sm"
                  :is-loading="isUpdating"
                  :disabled="isUpdating || isFormInvalid"
                  @click="updateCompany"
                />
              </div>
            </div>

            <Policy :permissions="['administrator']">
              <div class="flex flex-col gap-4 p-6 border-t border-n-strong">
                <div class="flex flex-col gap-2">
                  <h6 class="text-base font-medium text-n-slate-12">
                    {{ t('COMPANIES.DETAILS.DELETE_SECTION.TITLE') }}
                  </h6>
                  <span class="text-sm text-n-slate-11">
                    {{ t('COMPANIES.DETAILS.DELETE_SECTION.DESCRIPTION') }}
                  </span>
                </div>
                <div>
                  <Button
                    :label="t('COMPANIES.ACTIONS.DELETE')"
                    color="ruby"
                    @click="openDeleteDialog"
                  />
                </div>
              </div>
            </Policy>
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
