<script setup>
import { useAlert } from 'dashboard/composables';
import SettingsLayout from '../SettingsLayout.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import AccessRoleMatrix from './component/AccessRoleMatrix.vue';
import AccessRoleModal from './component/AccessRoleModal.vue';
import CustomRoleModal from './component/CustomRoleModal.vue';
import CustomRoleTableBody from './component/CustomRoleTableBody.vue';
import CustomRolePaywall from './component/CustomRolePaywall.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { picoSearch } from '@scmmishra/pico-search';
import { BaseTable } from 'dashboard/components-next/table';

const store = useStore();
const { t } = useI18n();

const showCustomRoleModal = ref(false);
const customRoleModalMode = ref('add');
const selectedRole = ref(null);
const loading = ref({});
const showDeleteConfirmationPopup = ref(false);
const activeResponse = ref({});
const searchQuery = ref('');

const records = useMapGetter('customRole/getCustomRoles');
const accessRoleCatalog = useMapGetter('customRole/getAccessRoleCatalog');
const mutationsEnabled = computed(
  () => accessRoleCatalog.value.mutationsEnabled
);
const legacyMutationsEnabled = computed(
  () => accessRoleCatalog.value.legacyMutationsEnabled
);
const canMutateRoles = computed(
  () => mutationsEnabled.value || legacyMutationsEnabled.value
);

const filteredRecords = computed(() => {
  const query = searchQuery.value.trim();
  if (!query) return records.value;
  return picoSearch(records.value, query, ['name', 'description']);
});
const uiFlags = useMapGetter('customRole/getUIFlags');

const deleteConfirmText = computed(
  () => `${t('CUSTOM_ROLE.DELETE.CONFIRM.YES')} ${activeResponse.value.name}`
);

const deleteRejectText = computed(
  () => `${t('CUSTOM_ROLE.DELETE.CONFIRM.NO')} ${activeResponse.value.name}`
);

const deleteMessage = computed(() => {
  return ` ${activeResponse.value.name} ? `;
});

const isFeatureEnabledOnAccount = useMapGetter(
  'accounts/isFeatureEnabledonAccount'
);

const currentAccountId = useMapGetter('getCurrentAccountId');

const isBehindAPaywall = computed(() => {
  return !isFeatureEnabledOnAccount.value(
    currentAccountId.value,
    'custom_roles'
  );
});

const fetchCustomRoles = async () => {
  try {
    await store.dispatch('customRole/getCustomRole');
  } catch (error) {
    // Ignore Error
  }
};

const fetchAccessRoleCatalog = () =>
  store.dispatch('customRole/fetchAccessRoleCatalog');

onMounted(() => {
  fetchCustomRoles();
  fetchAccessRoleCatalog();
});

const tableHeaders = computed(() => {
  return [
    t('CUSTOM_ROLE.LIST.TABLE_HEADER.NAME'),
    t('CUSTOM_ROLE.LIST.TABLE_HEADER.DESCRIPTION'),
    t('CUSTOM_ROLE.LIST.TABLE_HEADER.PERMISSIONS'),
    t('CUSTOM_ROLE.LIST.TABLE_HEADER.ACTIONS'),
  ];
});

const showAlertMessage = message => useAlert(message);

const openAddModal = () => {
  if (
    isBehindAPaywall.value ||
    !accessRoleCatalog.value.loaded ||
    !canMutateRoles.value
  ) {
    return;
  }
  customRoleModalMode.value = 'add';
  selectedRole.value = null;
  showCustomRoleModal.value = true;
};

const openEditModal = role => {
  customRoleModalMode.value = 'edit';
  selectedRole.value = role;
  showCustomRoleModal.value = true;
};

const hideCustomRoleModal = () => {
  selectedRole.value = null;
  showCustomRoleModal.value = false;
};

const openDeletePopup = response => {
  showDeleteConfirmationPopup.value = true;
  activeResponse.value = response;
};

const closeDeletePopup = () => {
  showDeleteConfirmationPopup.value = false;
};

const deleteCustomRole = async roleSnapshot => {
  const { id } = roleSnapshot;
  try {
    if (mutationsEnabled.value) {
      await store.dispatch('customRole/deleteAccessRole', {
        id,
        lockVersion: roleSnapshot.lock_version,
      });
    } else {
      await store.dispatch('customRole/deleteCustomRole', id);
    }
    showAlertMessage(t('CUSTOM_ROLE.DELETE.API.SUCCESS_MESSAGE'));
  } catch (error) {
    const errorMessage =
      error?.message || t('CUSTOM_ROLE.DELETE.API.ERROR_MESSAGE');
    showAlertMessage(errorMessage);
  } finally {
    loading.value[id] = false;
  }
};

const rebaseSelectedRole = id => {
  const freshRole = accessRoleCatalog.value.records.find(
    role => role.id === id
  );
  if (!freshRole) {
    hideCustomRoleModal();
    showAlertMessage(t('CUSTOM_ROLE.ACCESS_EDITOR.NOT_FOUND_ERROR'));
    return;
  }

  selectedRole.value = freshRole;
  showAlertMessage(t('CUSTOM_ROLE.ACCESS_EDITOR.STALE_ERROR'));
};

const confirmDeletion = () => {
  const roleSnapshot = activeResponse.value;
  const { id } = roleSnapshot;
  closeDeletePopup();
  activeResponse.value = {};
  if (id === undefined || id === null || loading.value[id]) return;

  loading.value[id] = true;
  deleteCustomRole(roleSnapshot);
};
</script>

<template>
  <SettingsLayout
    :is-loading="uiFlags.fetchingList"
    :loading-message="$t('CUSTOM_ROLE.LOADING')"
    :no-records-found="
      !records.length &&
      !accessRoleCatalog.records.length &&
      !uiFlags.fetchingAccessRoleCatalog &&
      !accessRoleCatalog.error &&
      !isBehindAPaywall
    "
    :no-records-message="$t('CUSTOM_ROLE.LIST.404')"
  >
    <template #header>
      <BaseSettingsHeader
        v-model:search-query="searchQuery"
        :title="$t('CUSTOM_ROLE.HEADER')"
        :description="$t('CUSTOM_ROLE.DESCRIPTION')"
        :link-text="$t('CUSTOM_ROLE.LEARN_MORE')"
        :search-placeholder="$t('CUSTOM_ROLE.SEARCH_PLACEHOLDER')"
        feature-name="canned_responses"
      >
        <template v-if="records?.length" #count>
          <span class="text-body-main text-n-slate-11">
            {{ $t('CUSTOM_ROLE.COUNT', { n: records.length }) }}
          </span>
        </template>
        <template #actions>
          <Button
            :label="$t('CUSTOM_ROLE.HEADER_BTN_TXT')"
            size="sm"
            :disabled="
              isBehindAPaywall || !accessRoleCatalog.loaded || !canMutateRoles
            "
            @click="openAddModal"
          />
        </template>
      </BaseSettingsHeader>
    </template>

    <template #body>
      <CustomRolePaywall v-if="isBehindAPaywall" />
      <div v-else class="flex flex-col gap-6">
        <AccessRoleMatrix
          :roles="accessRoleCatalog.records"
          :resources="accessRoleCatalog.resources"
          :is-loading="uiFlags.fetchingAccessRoleCatalog"
          :has-error="accessRoleCatalog.error"
          :search-query="searchQuery"
          :mutations-enabled="mutationsEnabled"
          :deleting-roles="loading"
          @retry="fetchAccessRoleCatalog"
          @edit="openEditModal"
          @delete="openDeletePopup"
        />

        <BaseTable
          v-if="
            accessRoleCatalog.loaded &&
            !mutationsEnabled &&
            legacyMutationsEnabled
          "
          :headers="tableHeaders"
          :items="filteredRecords"
          :no-data-message="
            searchQuery
              ? $t('CUSTOM_ROLE.NO_RESULTS')
              : $t('CUSTOM_ROLE.LIST.404')
          "
        >
          <template #row="{ items }">
            <CustomRoleTableBody
              :roles="items"
              :loading="loading"
              @edit="openEditModal"
              @delete="openDeletePopup"
            />
          </template>
        </BaseTable>
      </div>
    </template>

    <woot-modal v-model:show="showCustomRoleModal" @close="hideCustomRoleModal">
      <AccessRoleModal
        v-if="mutationsEnabled"
        :mode="customRoleModalMode"
        :selected-role="selectedRole"
        :resources="accessRoleCatalog.resources"
        :access-scopes="accessRoleCatalog.accessScopes"
        @close="hideCustomRoleModal"
        @stale="rebaseSelectedRole"
      />
      <CustomRoleModal
        v-else-if="legacyMutationsEnabled"
        :mode="customRoleModalMode"
        :selected-role="selectedRole"
        @close="hideCustomRoleModal"
      />
    </woot-modal>

    <woot-delete-modal
      v-model:show="showDeleteConfirmationPopup"
      :on-close="closeDeletePopup"
      :on-confirm="confirmDeletion"
      :title="$t('CUSTOM_ROLE.DELETE.CONFIRM.TITLE')"
      :message="$t('CUSTOM_ROLE.DELETE.CONFIRM.MESSAGE')"
      :message-value="deleteMessage"
      :confirm-text="deleteConfirmText"
      :reject-text="deleteRejectText"
    />
  </SettingsLayout>
</template>
