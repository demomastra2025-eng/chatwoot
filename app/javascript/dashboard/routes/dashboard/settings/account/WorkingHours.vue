<script>
import { mapGetters } from 'vuex';
import { useAdmin } from 'dashboard/composables/useAdmin';
import { useAccount } from 'dashboard/composables/useAccount';
import WorkspaceWorkingHours from './components/WorkspaceWorkingHours.vue';

export default {
  components: {
    WorkspaceWorkingHours,
  },
  setup() {
    const { isAdmin } = useAdmin();
    const { accountId, currentAccount } = useAccount();

    return {
      isAdmin,
      accountId,
      currentAccount,
    };
  },
  computed: {
    ...mapGetters({
      getAccount: 'accounts/getAccount',
      uiFlags: 'accounts/getUIFlags',
    }),
    accountRecord() {
      return this.getAccount(this.accountId) || this.currentAccount || {};
    },
    isWorkspaceReadOnly() {
      return !this.isAdmin;
    },
  },
};
</script>

<template>
  <div class="flex flex-col max-w-2xl mx-auto w-full">
    <WorkspaceWorkingHours
      v-if="accountRecord?.id"
      :account="accountRecord"
      :read-only="isWorkspaceReadOnly"
    />
    <woot-loading-state v-if="uiFlags.isFetchingItem" />
  </div>
</template>
