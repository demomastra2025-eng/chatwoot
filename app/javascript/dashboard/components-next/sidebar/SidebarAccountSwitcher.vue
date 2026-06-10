<script setup>
import { computed } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useAccount } from 'dashboard/composables/useAccount';
import { useMapGetter } from 'dashboard/composables/store';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import ButtonNext from 'next/button/Button.vue';
import Icon from 'next/icon/Icon.vue';
import Logo from 'next/icon/Logo.vue';

import {
  DropdownContainer,
  DropdownBody,
  DropdownSection,
  DropdownItem,
} from 'next/dropdown-menu/base';

const props = defineProps({
  isCollapsed: {
    type: Boolean,
    default: false,
  },
  companyMenuItem: {
    type: Object,
    default: null,
  },
});

const emit = defineEmits(['showCreateAccountModal']);

const { accountId, currentAccount } = useAccount();
const { t } = useI18n();
const route = useRoute();
const currentUser = useMapGetter('getCurrentUser');
const globalConfig = useMapGetter('globalConfig/get');

const userAccounts = useMapGetter('getUserAccounts');

const showAccountSwitcher = computed(
  () => userAccounts.value.length > 1 && currentAccount.value.name
);

const sortedCurrentUserAccounts = computed(() => {
  return [...(currentUser.value.accounts || [])].sort((a, b) =>
    a.name.localeCompare(b.name)
  );
});

const companyMenuItems = computed(() => props.companyMenuItem?.children || []);
const showCompanyMenu = computed(() => companyMenuItems.value.length > 0);

const routeMatchesItem = item => {
  const activeRouteNames = new Set([...(item?.activeOn || []), item?.to?.name]);
  return activeRouteNames.has(route.name);
};

const isCompanyMenuActive = computed(() => {
  return (
    routeMatchesItem(props.companyMenuItem) ||
    companyMenuItems.value.some(item => routeMatchesItem(item))
  );
});

const onChangeAccount = newId => {
  const accountUrl = `/app/accounts/${newId}`;
  window.location.href = accountUrl;
};

const emitNewAccount = () => {
  emit('showCreateAccountModal');
};
</script>

<template>
  <div
    class="flex min-w-0 items-center gap-1"
    :class="isCollapsed ? 'flex-col justify-center' : 'w-full'"
  >
    <DropdownContainer :class="isCollapsed ? '' : 'min-w-0 flex-1'">
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
        <button
          v-else
          id="sidebar-account-switcher"
          :data-account-id="accountId"
          aria-haspopup="listbox"
          aria-controls="account-options"
          class="flex items-center gap-2 justify-between w-full rounded-lg px-2 min-w-0"
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
            <Logo v-else class="size-5 flex-shrink-0" />
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
                <Logo v-else class="size-5 flex-shrink-0" />
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

    <DropdownContainer
      v-if="showCompanyMenu"
      menu-class="ltr:left-full rtl:right-full top-0 ltr:ml-2 rtl:mr-2 !mt-0"
    >
      <template #trigger="{ toggle, isOpen }">
        <button
          class="grid flex-shrink-0 place-content-center rounded-lg cursor-pointer text-n-slate-11 hover:bg-n-alpha-1 hover:text-n-slate-12"
          :class="[
            isCollapsed ? 'size-8' : 'size-7',
            (isOpen || isCompanyMenuActive) && 'bg-n-alpha-1 text-n-slate-12',
          ]"
          :title="t('SIDEBAR.MY_COMPANY')"
          :aria-label="t('SIDEBAR.MY_COMPANY')"
          @click="toggle"
        >
          <Icon icon="i-lucide-briefcase-business" class="size-4" />
        </button>
      </template>
      <DropdownBody class="min-w-64 z-50">
        <DropdownSection :title="t('SIDEBAR.MY_COMPANY')">
          <DropdownItem
            v-for="item in companyMenuItems"
            :key="item.name"
            :label="item.label"
            :icon="item.icon"
            :link="item.to"
            class="cursor-pointer"
            :class="{ 'bg-n-alpha-2 rounded-lg': routeMatchesItem(item) }"
          />
        </DropdownSection>
      </DropdownBody>
    </DropdownContainer>
  </div>
</template>
