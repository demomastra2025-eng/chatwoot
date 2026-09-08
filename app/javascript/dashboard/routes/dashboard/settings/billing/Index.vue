<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useMapGetter, useStore } from 'dashboard/composables/store.js';
import { useAccount } from 'dashboard/composables/useAccount';
import { useCaptain } from 'dashboard/composables/useCaptain';
import { useCamelCase } from 'dashboard/composables/useTransformKeys';
import { normalizeAccountLimit } from 'dashboard/helper/accountLimits';
import { format } from 'date-fns';
import sessionStorage from 'shared/helpers/sessionStorage';
import { formatBytes } from 'shared/helpers/FileHelper';

import BillingMeter from './components/BillingMeter.vue';
import BillingCard from './components/BillingCard.vue';
import BillingHeader from './components/BillingHeader.vue';
import BillingPlatformOverview from './components/BillingPlatformOverview.vue';
import DetailItem from './components/DetailItem.vue';
import PurchaseCreditsModal from './components/PurchaseCreditsModal.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';
import ButtonV4 from 'next/button/Button.vue';

const { t } = useI18n();
const { currentAccount, isOnChatwootCloud } = useAccount();
const {
  captainEnabled,
  captainLimits,
  documentLimits,
  responseLimits,
  tokenLimits,
  fetchLimits,
  isFetchingLimits,
} = useCaptain();

const uiFlags = useMapGetter('accounts/getUIFlags');
const store = useStore();

const BILLING_REFRESH_ATTEMPTED = 'billing_refresh_attempted';

// State for handling refresh attempts and loading
const isWaitingForBilling = ref(false);
const purchaseCreditsModalRef = ref(null);
const billingOverviewReady = ref(false);
const hasBillingPlatform = ref(false);
const pageTitle = computed(() =>
  hasBillingPlatform.value
    ? t('BILLING_SETTINGS.PLATFORM.TITLE')
    : t('BILLING_SETTINGS.TITLE')
);
const pageDescription = computed(() =>
  hasBillingPlatform.value
    ? t('BILLING_SETTINGS.PLATFORM.READ_ONLY')
    : t('BILLING_SETTINGS.DESCRIPTION')
);
const pricingLinkText = computed(() =>
  hasBillingPlatform.value ? '' : t('BILLING_SETTINGS.VIEW_PRICING')
);

const customAttributes = computed(() => {
  return currentAccount.value.custom_attributes || {};
});

const accountLimits = computed(() => {
  const limits = currentAccount.value?.limits;

  if (!limits?.conversation && !limits?.inboxes) {
    return {};
  }

  return useCamelCase(limits, { deep: true });
});

const decorateLimit = (limit, formatter = value => `${value}`) => {
  const normalized = normalizeAccountLimit(limit);

  if (!normalized) {
    return null;
  }

  return {
    ...normalized,
    displayConsumed: formatter(normalized.consumed),
    displayTotal: normalized.unlimited
      ? t('BILLING_SETTINGS.UNLIMITED')
      : formatter(normalized.totalCount),
  };
};

const accountUsageLimits = computed(() => {
  return {
    agents: decorateLimit(accountLimits.value.agents),
    inboxes: decorateLimit(accountLimits.value.inboxes),
    conversations: decorateLimit(accountLimits.value.conversation),
    nonWebInboxes: decorateLimit(accountLimits.value.nonWebInboxes),
    storage: decorateLimit(accountLimits.value.storage, value =>
      formatBytes(value)
    ),
  };
});

const hasAccountUsageLimits = computed(() => {
  return Object.values(accountUsageLimits.value).some(Boolean);
});

const captainUsageLimits = computed(() => {
  return {
    responses: decorateLimit(responseLimits.value),
    documents: decorateLimit(documentLimits.value),
    tokens: decorateLimit(tokenLimits.value),
  };
});

/**
 * Computed property for plan name
 * @returns {string|undefined}
 */
const planName = computed(() => {
  return customAttributes.value.plan_name;
});

const canPurchaseCredits = computed(() => {
  const plan = planName.value?.toLowerCase();
  return plan && plan !== 'hacker';
});

/**
 * Computed property for subscribed quantity
 * @returns {number|undefined}
 */
const subscribedQuantity = computed(() => {
  return customAttributes.value.subscribed_quantity;
});

const subscriptionRenewsOn = computed(() => {
  if (!customAttributes.value.subscription_ends_on) return '';
  const endDate = new Date(customAttributes.value.subscription_ends_on);
  // return date as 12 Jan, 2034
  return format(endDate, 'dd MMM, yyyy');
});

/**
 * Computed property indicating if user has a billing plan
 * @returns {boolean}
 */
const hasABillingPlan = computed(() => {
  return !!planName.value;
});

const fetchAccountDetails = async () => {
  if (!hasABillingPlan.value) {
    await store.dispatch('accounts/subscription');
  }
  // Always fetch limits for billing page to show credit usage
  await fetchLimits();
};

const handleBillingPageLogic = async () => {
  if (!isOnChatwootCloud.value) return;

  // Check if we've already attempted a refresh for billing setup
  const billingRefreshAttempted = sessionStorage.get(BILLING_REFRESH_ATTEMPTED);

  // If cloud user, fetch account details first
  await fetchAccountDetails();

  // If still no billing plan after fetch
  if (!hasABillingPlan.value) {
    // If we haven't attempted refresh yet, do it once
    if (!billingRefreshAttempted) {
      isWaitingForBilling.value = true;
      sessionStorage.set(BILLING_REFRESH_ATTEMPTED, true);

      setTimeout(() => {
        fetchAccountDetails()
          .catch(() => undefined)
          .finally(() => {
            isWaitingForBilling.value = false;
            sessionStorage.remove(BILLING_REFRESH_ATTEMPTED);
          });
      }, 5000);
    } else {
      // We've already tried refreshing, so just show the no billing message
      // Clear the flag for future visits
      sessionStorage.remove(BILLING_REFRESH_ATTEMPTED);
    }
  } else {
    // Billing plan found, clear any existing refresh flag
    sessionStorage.remove(BILLING_REFRESH_ATTEMPTED);
  }
};

const onClickBillingPortal = () => {
  store.dispatch('accounts/checkout');
};

const onToggleChatWindow = () => {
  if (window.$chatwoot) {
    window.$chatwoot.toggle();
  }
};

const openPurchaseCreditsModal = () => {
  purchaseCreditsModalRef.value?.open();
};

const refreshLimits = () => {
  return fetchLimits({ silent: false });
};

const handleTopupSuccess = () => {
  // Refresh limits to show updated credit balance
  refreshLimits();
};

const onBillingOverviewLoaded = configured => {
  billingOverviewReady.value = true;
  hasBillingPlatform.value = configured;
  if (!configured) handleBillingPageLogic();
};
</script>

<template>
  <SettingsLayout
    :is-loading="
      !hasBillingPlatform && (uiFlags.isFetchingItem || isWaitingForBilling)
    "
    :loading-message="
      isWaitingForBilling
        ? $t('BILLING_SETTINGS.NO_BILLING_USER')
        : $t('ATTRIBUTES_MGMT.LOADING')
    "
    :no-records-found="
      billingOverviewReady &&
      isOnChatwootCloud &&
      !hasBillingPlatform &&
      !hasABillingPlan &&
      !isWaitingForBilling
    "
    :no-records-message="$t('BILLING_SETTINGS.NO_BILLING_USER')"
  >
    <template #header>
      <BaseSettingsHeader
        :title="pageTitle"
        :description="pageDescription"
        :link-text="pricingLinkText"
        feature-name="billing"
      />
    </template>
    <template #preBody>
      <BillingPlatformOverview @loaded="onBillingOverviewLoaded" />
    </template>
    <template #body>
      <section
        v-if="billingOverviewReady && isOnChatwootCloud && !hasBillingPlatform"
        class="grid gap-4"
      >
        <BillingCard
          :title="$t('BILLING_SETTINGS.MANAGE_SUBSCRIPTION.TITLE')"
          :description="$t('BILLING_SETTINGS.MANAGE_SUBSCRIPTION.DESCRIPTION')"
        >
          <template #action>
            <ButtonV4 sm solid blue @click="onClickBillingPortal">
              {{ $t('BILLING_SETTINGS.MANAGE_SUBSCRIPTION.BUTTON_TXT') }}
            </ButtonV4>
          </template>
          <div
            v-if="planName || subscribedQuantity || subscriptionRenewsOn"
            class="grid lg:grid-cols-4 sm:grid-cols-3 grid-cols-1 gap-2 divide-x divide-n-weak"
          >
            <DetailItem
              :label="$t('BILLING_SETTINGS.CURRENT_PLAN.TITLE')"
              :value="planName"
            />
            <DetailItem
              v-if="subscribedQuantity"
              :label="$t('BILLING_SETTINGS.CURRENT_PLAN.SEAT_COUNT')"
              :value="subscribedQuantity"
            />
            <DetailItem
              v-if="subscriptionRenewsOn"
              :label="$t('BILLING_SETTINGS.CURRENT_PLAN.RENEWS_ON')"
              :value="subscriptionRenewsOn"
            />
          </div>
        </BillingCard>
        <BillingCard
          v-if="hasAccountUsageLimits"
          :title="$t('BILLING_SETTINGS.ACCOUNT_USAGE.TITLE')"
          :description="$t('BILLING_SETTINGS.ACCOUNT_USAGE.DESCRIPTION')"
        >
          <template #action>
            <ButtonV4
              sm
              flushed
              slate
              icon="i-lucide-refresh-cw"
              :is-loading="isFetchingLimits"
              @click="refreshLimits"
            >
              {{ $t('BILLING_SETTINGS.CAPTAIN.REFRESH_CREDITS') }}
            </ButtonV4>
          </template>
          <div v-if="accountUsageLimits.agents" class="px-5">
            <BillingMeter
              :title="$t('SIDEBAR.AGENTS')"
              v-bind="accountUsageLimits.agents"
            />
          </div>
          <div v-if="accountUsageLimits.inboxes" class="px-5">
            <BillingMeter
              :title="$t('SIDEBAR.INBOXES')"
              v-bind="accountUsageLimits.inboxes"
            />
          </div>
          <div v-if="accountUsageLimits.conversations" class="px-5">
            <BillingMeter
              :title="$t('SIDEBAR.CONVERSATIONS')"
              v-bind="accountUsageLimits.conversations"
            />
          </div>
          <div v-if="accountUsageLimits.nonWebInboxes" class="px-5">
            <BillingMeter
              :title="$t('BILLING_SETTINGS.ACCOUNT_USAGE.NON_WEB_INBOXES')"
              v-bind="accountUsageLimits.nonWebInboxes"
            />
          </div>
          <div v-if="accountUsageLimits.storage" class="px-5">
            <BillingMeter
              :title="$t('BILLING_SETTINGS.ACCOUNT_USAGE.STORAGE')"
              v-bind="accountUsageLimits.storage"
            />
          </div>
        </BillingCard>
        <BillingCard
          v-if="captainEnabled"
          :title="$t('BILLING_SETTINGS.CAPTAIN.TITLE')"
          :description="$t('BILLING_SETTINGS.CAPTAIN.DESCRIPTION')"
        >
          <template #action>
            <div class="flex gap-2">
              <ButtonV4
                sm
                flushed
                slate
                icon="i-lucide-refresh-cw"
                :is-loading="isFetchingLimits"
                @click="refreshLimits"
              >
                {{ $t('BILLING_SETTINGS.CAPTAIN.REFRESH_CREDITS') }}
              </ButtonV4>
              <ButtonV4
                v-if="canPurchaseCredits"
                sm
                solid
                blue
                @click="openPurchaseCreditsModal"
              >
                {{ $t('BILLING_SETTINGS.TOPUP.BUY_CREDITS') }}
              </ButtonV4>
            </div>
          </template>
          <div
            v-if="captainLimits && captainUsageLimits.responses"
            class="px-5"
          >
            <BillingMeter
              :title="$t('BILLING_SETTINGS.CAPTAIN.RESPONSES')"
              v-bind="captainUsageLimits.responses"
            />
          </div>
          <div
            v-if="captainLimits && captainUsageLimits.documents"
            class="px-5"
          >
            <BillingMeter
              :title="$t('BILLING_SETTINGS.CAPTAIN.DOCUMENTS')"
              v-bind="captainUsageLimits.documents"
            />
          </div>
          <div v-if="captainLimits && captainUsageLimits.tokens" class="px-5">
            <BillingMeter
              :title="$t('BILLING_SETTINGS.CAPTAIN.TOKENS')"
              v-bind="captainUsageLimits.tokens"
            />
          </div>
        </BillingCard>
        <BillingCard
          v-else
          :title="$t('BILLING_SETTINGS.CAPTAIN.TITLE')"
          :description="$t('BILLING_SETTINGS.CAPTAIN.UPGRADE')"
        >
          <template #action>
            <ButtonV4 sm solid slate @click="onClickBillingPortal">
              {{ $t('CAPTAIN.PAYWALL.UPGRADE_NOW') }}
            </ButtonV4>
          </template>
        </BillingCard>

        <BillingHeader
          class="px-1 mt-5"
          :title="$t('BILLING_SETTINGS.CHAT_WITH_US.TITLE')"
          :description="$t('BILLING_SETTINGS.CHAT_WITH_US.DESCRIPTION')"
        >
          <ButtonV4
            sm
            solid
            slate
            icon="i-lucide-life-buoy"
            @click="onToggleChatWindow"
          >
            {{ $t('BILLING_SETTINGS.CHAT_WITH_US.BUTTON_TXT') }}
          </ButtonV4>
        </BillingHeader>
      </section>
      <PurchaseCreditsModal
        v-if="billingOverviewReady && isOnChatwootCloud && !hasBillingPlatform"
        ref="purchaseCreditsModalRef"
        @success="handleTopupSuccess"
      />
    </template>
  </SettingsLayout>
</template>
