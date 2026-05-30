<script setup>
import { computed } from 'vue';
import { useRoute } from 'vue-router';
import { useAccount } from 'dashboard/composables/useAccount';
import { useMapGetter } from 'dashboard/composables/store';
import { useI18n } from 'vue-i18n';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import ButtonNext from 'next/button/Button.vue';
import Icon from 'next/icon/Icon.vue';
import Logo from 'next/icon/Logo.vue';
import { WORKSPACE_SETTINGS_ACTIVE_ROUTE_NAMES } from 'dashboard/routes/dashboard/settings/workspaceSettingsTabs';

import {
  DropdownContainer,
  DropdownBody,
  DropdownSection,
  DropdownItem,
} from 'next/dropdown-menu/base';

defineProps({
  isCollapsed: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['showCreateAccountModal']);

const { t } = useI18n();
const route = useRoute();
const { accountId, accountScopedRoute, currentAccount } = useAccount();
const currentUser = useMapGetter('getCurrentUser');
const globalConfig = useMapGetter('globalConfig/get');

const userAccounts = useMapGetter('getUserAccounts');

const showAccountSwitcher = computed(
  () => userAccounts.value.length > 1 && currentAccount.value.name
);

const workspaceSettingsRoute = computed(() =>
  accountScopedRoute('general_settings_index')
);

const isWorkspaceSettingsActive = computed(() =>
  WORKSPACE_SETTINGS_ACTIVE_ROUTE_NAMES.includes(route.name)
);

const sortedCurrentUserAccounts = computed(() => {
  return [...(currentUser.value.accounts || [])].sort((a, b) =>
    a.name.localeCompare(b.name)
  );
});

const onChangeAccount = newId => {
  const accountUrl = `/app/accounts/${newId}/dashboard`;
  window.location.href = accountUrl;
};

const emitNewAccount = () => {
  emit('showCreateAccountModal');
};
</script>

<template>
  <DropdownContainer>
    <template #trigger="{ toggle, isOpen }">
      <!-- Collapsed view: Logo trigger -->
      <button
        v-if="isCollapsed"
        class="grid flex-shrink-0 place-content-center p-2 rounded-lg cursor-pointer hover:bg-n-alpha-1"
        :class="{ 'bg-n-alpha-1': isOpen }"
        :title="currentAccount.name"
        @click="toggle"
      >
        <Avatar
          v-if="currentAccount.logo_url"
          :src="currentAccount.logo_url"
          :name="currentAccount.name"
          :size="28"
        />
        <Logo v-else class="size-7" />
      </button>
      <!-- Expanded view: Account name trigger -->
      <div v-else class="flex items-center gap-1 min-w-0 w-full">
        <button
          id="sidebar-account-switcher"
          :data-account-id="accountId"
          aria-haspopup="listbox"
          aria-controls="account-options"
          class="flex items-center gap-2 justify-between flex-1 rounded-lg px-2 min-w-0"
          :class="[
            isOpen && 'bg-n-alpha-1',
            showAccountSwitcher
              ? 'hover:bg-n-alpha-1 cursor-pointer'
              : 'cursor-default',
          ]"
          @click="() => showAccountSwitcher && toggle()"
        >
          <div class="flex items-center gap-2 min-w-0">
            <Avatar
              v-if="currentAccount.logo_url"
              :src="currentAccount.logo_url"
              :name="currentAccount.name"
              :size="24"
            />
            <span
              class="text-sm font-medium leading-5 text-n-slate-12 truncate"
              aria-live="polite"
            >
              {{ currentAccount.name }}
            </span>
          </div>

          <span
            v-if="showAccountSwitcher"
            aria-hidden="true"
            class="i-lucide-chevron-down size-4 text-n-slate-10 flex-shrink-0"
          />
        </button>
        <RouterLink
          :to="workspaceSettingsRoute"
          class="inline-flex items-center justify-center rounded-md size-7 flex-shrink-0 text-n-slate-10 hover:bg-n-alpha-2 hover:text-n-slate-12"
          :class="{
            'bg-n-alpha-2 text-n-slate-12': isWorkspaceSettingsActive,
          }"
          :title="t('SIDEBAR_ITEMS.WORKSPACE_SETTINGS')"
        >
          <Icon icon="i-lucide-briefcase-business" class="size-3.5" />
        </RouterLink>
      </div>
    </template>
    <DropdownBody
      v-if="showAccountSwitcher || isCollapsed"
      class="min-w-80 z-50"
    >
      <DropdownSection :title="t('SIDEBAR_ITEMS.SWITCH_ACCOUNT')">
        <DropdownItem
          v-for="account in sortedCurrentUserAccounts"
          :id="`account-${account.id}`"
          :key="account.id"
          class="cursor-pointer"
          @click="onChangeAccount(account.id)"
        >
          <template #label>
            <div
              :for="account.name"
              class="text-left rtl:text-right flex gap-2 items-center"
            >
              <Avatar
                v-if="account.logo_url"
                :src="account.logo_url"
                :name="account.name"
                :size="20"
              />
              <span
                class="text-n-slate-12 max-w-36 truncate min-w-0"
                :title="account.name"
              >
                {{ account.name }}
              </span>
              <div class="flex-shrink-0 w-px h-3 bg-n-strong" />
              <span
                class="text-n-slate-11 max-w-24 truncate capitalize"
                :title="account.name"
              >
                {{
                  account.custom_role_id
                    ? account.custom_role.name
                    : account.role
                }}
              </span>
            </div>
            <Icon
              v-show="account.id === accountId"
              icon="i-lucide-check"
              class="text-n-teal-11 size-5"
            />
          </template>
        </DropdownItem>
      </DropdownSection>
      <DropdownItem v-if="globalConfig.createNewAccountFromDashboard">
        <ButtonNext
          color="slate"
          variant="faded"
          class="w-full"
          size="sm"
          @click="emitNewAccount"
        >
          {{ t('CREATE_ACCOUNT.NEW_ACCOUNT') }}
        </ButtonNext>
      </DropdownItem>
    </DropdownBody>
  </DropdownContainer>
</template>
