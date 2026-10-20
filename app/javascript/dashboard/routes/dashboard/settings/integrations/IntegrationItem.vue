<script setup>
import { computed } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { frontendURL } from 'dashboard/helper/URLHelper';
import { useBranding } from 'shared/composables/useBranding';

const props = defineProps({
  id: {
    type: [String, Number],
    required: true,
  },
  name: {
    type: String,
    default: '',
  },
  description: {
    type: String,
    default: '',
  },
  logo: {
    type: String,
    default: '',
  },
  enabled: {
    type: Boolean,
    default: false,
  },
});

const route = useRoute();
const { t } = useI18n();
const { replaceInstallationName } = useBranding();

const accountId = computed(() => route.params.accountId);

const statusBadgeText = computed(() =>
  props.enabled
    ? t('INTEGRATION_SETTINGS.STATUS.ACTIVE')
    : t('INTEGRATION_SETTINGS.STATUS.INACTIVE')
);

const statusBadgeClass = computed(() =>
  props.enabled
    ? 'bg-n-teal-3 text-n-teal-11 border-n-teal-6'
    : 'bg-n-alpha-2 text-n-slate-11 border-n-weak'
);

const statusDotClass = computed(() =>
  props.enabled ? 'bg-n-teal-9' : 'bg-n-slate-8'
);

const actionURL = computed(() =>
  frontendURL(
    `accounts/${accountId.value}/settings/integrations/` +
      (props.id === 'dashboard_apps' ? 'dashboard_apps' : props.id)
  )
);

const hasCustomLogo = computed(
  () => Boolean(props.logo) && props.logo !== `${props.id}.png`
);

const lightLogoSource = computed(() =>
  props.logo
    ? `/dashboard/images/integrations/${props.logo}`
    : `/dashboard/images/integrations/${props.id}.png`
);

const darkLogoSource = computed(() =>
  hasCustomLogo.value
    ? lightLogoSource.value
    : `/dashboard/images/integrations/${props.id}-dark.png`
);
</script>

<template>
  <router-link
    :to="actionURL"
    class="group flex flex-col justify-between p-5 rounded-xl border border-n-weak bg-n-solid-2 shadow-sm transition-all duration-150 hover:border-n-slate-7 hover:bg-n-solid-3 focus:outline-none"
  >
    <div>
      <div class="flex items-start justify-between gap-3">
        <div class="flex items-center gap-3.5 min-w-0">
          <div
            class="flex h-12 w-12 shrink-0 items-center justify-center rounded-xl border border-n-weak bg-n-solid-1 p-2 shadow-xs"
          >
            <img
              :src="lightLogoSource"
              :alt="name"
              class="max-w-full max-h-full rounded-md block dark:hidden"
            />
            <img
              :src="darkLogoSource"
              :alt="name"
              class="max-w-full max-h-full rounded-md hidden dark:block"
            />
          </div>
          <div class="min-w-0">
            <h3
              class="truncate text-base font-semibold text-n-slate-12 transition-colors group-hover:text-n-brand"
            >
              {{ name }}
            </h3>
          </div>
        </div>
        <span
          class="inline-flex shrink-0 items-center gap-1.5 rounded-full border px-2.5 py-1 text-xs font-medium"
          :class="statusBadgeClass"
        >
          <span class="h-1.5 w-1.5 rounded-full" :class="statusDotClass" />
          {{ statusBadgeText }}
        </span>
      </div>

      <p class="mt-3 line-clamp-2 text-sm leading-relaxed text-n-slate-11">
        {{ replaceInstallationName(description) }}
      </p>
    </div>

    <div
      class="mt-5 flex items-center justify-between border-t border-n-weak pt-3.5"
    >
      <span class="text-xs text-n-slate-10">
        {{
          enabled
            ? $t('INTEGRATION_APPS.STATUS.ENABLED')
            : $t('INTEGRATION_APPS.STATUS.DISABLED')
        }}
      </span>
      <span
        class="inline-flex items-center gap-1.5 rounded-lg bg-n-alpha-2 px-3 py-1.5 text-xs font-medium text-n-slate-12 transition-colors group-hover:bg-n-brand group-hover:text-white"
      >
        <span class="i-lucide-sliders-horizontal size-3.5" />
        {{ $t('INTEGRATION_APPS.CONFIGURE') }}
      </span>
    </div>
  </router-link>
</template>
