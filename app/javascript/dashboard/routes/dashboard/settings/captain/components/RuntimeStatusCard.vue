<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { storeToRefs } from 'pinia';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';
import { useAlert } from 'dashboard/composables';
import NextButton from 'dashboard/components-next/button/Button.vue';

const { t, locale } = useI18n();

const captainConfigStore = useCaptainConfigStore();
const { runtimeMetadata, uiFlags } = storeToRefs(captainConfigStore);

const defaults = computed(() => runtimeMetadata.value.defaults || {});
const registry = computed(() => runtimeMetadata.value.registry || {});
const providers = computed(() => runtimeMetadata.value.providers || {});
const features = computed(() => runtimeMetadata.value.features || {});

const providerEntries = computed(() => Object.entries(providers.value));
const openRouterProvider = computed(() => providers.value.openrouter || null);
const openRouterCatalog = computed(
  () => openRouterProvider.value?.models_api || registry.value.openrouter || {}
);
const isRefreshingOpenRouterModels = computed(
  () => uiFlags.value.isRefreshingOpenRouterModels
);
const featureEntries = computed(() => Object.entries(features.value));

const formatDateTime = value => {
  if (!value) return t('CAPTAIN_SETTINGS.RUNTIME_STATUS.REGISTRY.NEVER');

  try {
    return new Intl.DateTimeFormat(locale.value || undefined, {
      dateStyle: 'medium',
      timeStyle: 'short',
    }).format(new Date(value));
  } catch {
    return value;
  }
};

const openRouterCatalogSourceLabel = computed(() => {
  if (openRouterCatalog.value.using_fallback) {
    return t('CAPTAIN_SETTINGS.RUNTIME_STATUS.OPENROUTER.FALLBACK_SOURCE', {
      count:
        openRouterCatalog.value.fallback_models ||
        openRouterCatalog.value.total_models ||
        0,
    });
  }

  return t('CAPTAIN_SETTINGS.RUNTIME_STATUS.OPENROUTER.API_SOURCE', {
    count: openRouterCatalog.value.total_models || 0,
  });
});

const refreshOpenRouterModels = async () => {
  try {
    await captainConfigStore.refreshOpenRouterModels();
    useAlert(t('CAPTAIN_SETTINGS.RUNTIME_STATUS.OPENROUTER.REFRESH_SUCCESS'));
  } catch (error) {
    useAlert(
      error?.response?.data?.error ||
        t('CAPTAIN_SETTINGS.RUNTIME_STATUS.OPENROUTER.REFRESH_ERROR')
    );
  }
};

const featureLabel = key => {
  switch (key) {
    case 'editor':
      return t('CAPTAIN_SETTINGS.RUNTIME_STATUS.FEATURE_LABELS.EDITOR');
    case 'assistant':
      return t('CAPTAIN_SETTINGS.RUNTIME_STATUS.FEATURE_LABELS.ASSISTANT');
    case 'copilot':
      return t('CAPTAIN_SETTINGS.RUNTIME_STATUS.FEATURE_LABELS.COPILOT');
    case 'label_suggestion':
      return t(
        'CAPTAIN_SETTINGS.RUNTIME_STATUS.FEATURE_LABELS.LABEL_SUGGESTION'
      );
    case 'audio_transcription':
      return t(
        'CAPTAIN_SETTINGS.RUNTIME_STATUS.FEATURE_LABELS.AUDIO_TRANSCRIPTION'
      );
    case 'help_center_search':
      return t(
        'CAPTAIN_SETTINGS.RUNTIME_STATUS.FEATURE_LABELS.HELP_CENTER_SEARCH'
      );
    default:
      return key;
  }
};
</script>

<template>
  <div class="rounded-xl border border-n-weak bg-n-solid-1 p-4 grid gap-4">
    <div>
      <h4 class="text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN_SETTINGS.RUNTIME_STATUS.TITLE') }}
      </h4>
      <p class="text-sm text-n-slate-11 mt-0.5">
        {{ t('CAPTAIN_SETTINGS.RUNTIME_STATUS.DESCRIPTION') }}
      </p>
    </div>

    <div
      class="rounded-xl border border-n-weak bg-n-alpha-2 divide-y divide-n-weak"
    >
      <div class="p-3 grid gap-2">
        <div class="flex items-center justify-between gap-4">
          <span class="text-sm text-n-slate-11">
            {{ t('CAPTAIN_SETTINGS.RUNTIME_STATUS.DEFAULT_MODEL') }}
          </span>
          <span class="text-sm font-medium text-n-slate-12">
            {{ defaults.installation_default_model || t('GENERAL.NONE') }}
          </span>
        </div>
        <div class="flex items-center justify-between gap-4">
          <span class="text-sm text-n-slate-11">
            {{ t('CAPTAIN_SETTINGS.RUNTIME_STATUS.MODERATION_MODEL') }}
          </span>
          <span class="text-sm font-medium text-n-slate-12">
            {{ defaults.moderation_model || t('GENERAL.NONE') }}
          </span>
        </div>
        <div class="flex items-center justify-between gap-4">
          <span class="text-sm text-n-slate-11">
            {{ t('CAPTAIN_SETTINGS.RUNTIME_STATUS.OPENROUTER.PRIMARY') }}
          </span>
          <span class="text-sm font-medium text-n-slate-12">
            {{
              defaults.openrouter_primary
                ? t('CAPTAIN_SETTINGS.RUNTIME_STATUS.OPENROUTER.PRIMARY_ACTIVE')
                : t(
                    'CAPTAIN_SETTINGS.RUNTIME_STATUS.OPENROUTER.PRIMARY_INACTIVE'
                  )
            }}
          </span>
        </div>
      </div>

      <div class="p-3 grid gap-2">
        <div class="flex items-center justify-between gap-4">
          <span class="text-sm text-n-slate-11">
            {{ t('CAPTAIN_SETTINGS.RUNTIME_STATUS.REGISTRY.TITLE') }}
          </span>
          <span class="text-sm font-medium text-n-slate-12">
            {{
              t('CAPTAIN_SETTINGS.RUNTIME_STATUS.REGISTRY.COUNTS', {
                resolved: registry.resolved_models || 0,
                configured: registry.configured_models || 0,
                total: registry.total_models || 0,
              })
            }}
          </span>
        </div>
        <div class="flex items-center justify-between gap-4">
          <span class="text-sm text-n-slate-11">
            {{ t('CAPTAIN_SETTINGS.RUNTIME_STATUS.REGISTRY.LAST_REFRESH') }}
          </span>
          <span class="text-sm font-medium text-n-slate-12">
            {{ formatDateTime(registry.last_refreshed_at) }}
          </span>
        </div>
        <p
          v-if="registry.last_refresh_error"
          class="text-xs text-n-ruby-11 break-words"
        >
          {{
            t('CAPTAIN_SETTINGS.RUNTIME_STATUS.REGISTRY.ERROR', {
              error: registry.last_refresh_error,
            })
          }}
        </p>
      </div>

      <div v-if="openRouterProvider" class="p-3 grid gap-3">
        <div
          class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between"
        >
          <div class="min-w-0">
            <div class="text-sm font-medium text-n-slate-12">
              {{ t('CAPTAIN_SETTINGS.RUNTIME_STATUS.OPENROUTER.TITLE') }}
            </div>
            <p class="text-xs text-n-slate-11 mt-0.5">
              {{ t('CAPTAIN_SETTINGS.RUNTIME_STATUS.OPENROUTER.DESCRIPTION') }}
            </p>
          </div>
          <NextButton
            sm
            outline
            blue
            type="button"
            icon="i-lucide-refresh-cw"
            :disabled="
              !openRouterProvider.configured || isRefreshingOpenRouterModels
            "
            :is-loading="isRefreshingOpenRouterModels"
            @click="refreshOpenRouterModels"
          >
            {{ t('CAPTAIN_SETTINGS.RUNTIME_STATUS.OPENROUTER.REFRESH') }}
          </NextButton>
        </div>
        <div
          class="grid gap-2 rounded-lg border border-n-weak bg-n-solid-1 p-3"
        >
          <div class="flex items-center justify-between gap-4">
            <span class="text-sm text-n-slate-11">
              {{ t('CAPTAIN_SETTINGS.RUNTIME_STATUS.OPENROUTER.SOURCE') }}
            </span>
            <span
              class="text-sm font-medium text-n-slate-12 text-right break-words min-w-0"
            >
              {{ openRouterCatalogSourceLabel }}
            </span>
          </div>
          <div class="flex items-center justify-between gap-4">
            <span class="text-sm text-n-slate-11">
              {{ t('CAPTAIN_SETTINGS.RUNTIME_STATUS.OPENROUTER.LAST_REFRESH') }}
            </span>
            <span
              class="text-sm font-medium text-n-slate-12 text-right break-words min-w-0"
            >
              {{ formatDateTime(openRouterCatalog.last_refreshed_at) }}
            </span>
          </div>
          <p
            v-if="!openRouterProvider.configured"
            class="text-xs text-n-ruby-11 break-words"
          >
            {{ t('CAPTAIN_SETTINGS.RUNTIME_STATUS.OPENROUTER.MISSING_KEY') }}
          </p>
          <p
            v-if="openRouterCatalog.last_refresh_error"
            class="text-xs text-n-ruby-11 break-words"
          >
            {{
              t('CAPTAIN_SETTINGS.RUNTIME_STATUS.OPENROUTER.ERROR', {
                error: openRouterCatalog.last_refresh_error,
              })
            }}
          </p>
        </div>
      </div>

      <div class="p-3 grid gap-3">
        <div class="text-sm font-medium text-n-slate-12">
          {{ t('CAPTAIN_SETTINGS.RUNTIME_STATUS.PROVIDERS.TITLE') }}
        </div>
        <div class="grid gap-2">
          <div
            v-for="[providerKey, provider] in providerEntries"
            :key="providerKey"
            class="flex items-center justify-between gap-4"
          >
            <div class="min-w-0">
              <div class="text-sm text-n-slate-12">
                {{ provider.display_name }}
              </div>
              <div class="text-xs text-n-slate-11">
                {{
                  provider.custom_endpoint
                    ? t(
                        'CAPTAIN_SETTINGS.RUNTIME_STATUS.PROVIDERS.CUSTOM_ENDPOINT'
                      )
                    : t(
                        'CAPTAIN_SETTINGS.RUNTIME_STATUS.PROVIDERS.DEFAULT_ENDPOINT'
                      )
                }}
              </div>
            </div>
            <span
              class="text-xs font-medium rounded-full px-2 py-1"
              :class="
                provider.configured
                  ? 'bg-n-teal-3 text-n-teal-11'
                  : 'bg-n-ruby-3 text-n-ruby-11'
              "
            >
              {{
                provider.configured
                  ? t('CAPTAIN_SETTINGS.RUNTIME_STATUS.PROVIDERS.CONFIGURED')
                  : t(
                      'CAPTAIN_SETTINGS.RUNTIME_STATUS.PROVIDERS.NOT_CONFIGURED'
                    )
              }}
            </span>
          </div>
        </div>
      </div>

      <div class="p-3 grid gap-3">
        <div class="text-sm font-medium text-n-slate-12">
          {{ t('CAPTAIN_SETTINGS.RUNTIME_STATUS.FEATURES.TITLE') }}
        </div>
        <div class="grid gap-2">
          <div
            v-for="[featureKey, feature] in featureEntries"
            :key="featureKey"
            class="rounded-lg border border-n-weak bg-n-solid-1 p-3 grid gap-2"
          >
            <div class="flex items-start justify-between gap-4">
              <div class="min-w-0">
                <div class="text-sm font-medium text-n-slate-12">
                  {{ featureLabel(featureKey) }}
                </div>
                <div class="text-xs text-n-slate-11 mt-0.5 break-all">
                  <span>{{ feature.selected_model }}</span>
                  <span class="px-1" aria-hidden="true">
                    {{ t('CAPTAIN_SETTINGS.RUNTIME_STATUS.SEPARATOR') }}
                  </span>
                  <span>{{ feature.provider_display_name }}</span>
                </div>
              </div>
              <div class="flex flex-wrap justify-end gap-1">
                <span
                  class="text-xs font-medium rounded-full px-2 py-1"
                  :class="
                    feature.provider_configured
                      ? 'bg-n-teal-3 text-n-teal-11'
                      : 'bg-n-ruby-3 text-n-ruby-11'
                  "
                >
                  {{
                    feature.provider_configured
                      ? t(
                          'CAPTAIN_SETTINGS.RUNTIME_STATUS.FEATURES.PROVIDER_READY'
                        )
                      : t(
                          'CAPTAIN_SETTINGS.RUNTIME_STATUS.FEATURES.PROVIDER_MISSING'
                        )
                  }}
                </span>
                <span
                  class="text-xs font-medium rounded-full px-2 py-1"
                  :class="
                    feature.known_to_registry
                      ? 'bg-n-sky-3 text-n-sky-11'
                      : 'bg-n-amber-3 text-n-amber-11'
                  "
                >
                  {{
                    feature.known_to_registry
                      ? t(
                          'CAPTAIN_SETTINGS.RUNTIME_STATUS.FEATURES.REGISTRY_READY'
                        )
                      : t(
                          'CAPTAIN_SETTINGS.RUNTIME_STATUS.FEATURES.REGISTRY_MISSING'
                        )
                  }}
                </span>
                <span
                  v-if="feature.supports_thinking"
                  class="text-xs font-medium rounded-full px-2 py-1 bg-n-iris-3 text-n-iris-11"
                >
                  {{
                    t('CAPTAIN_SETTINGS.RUNTIME_STATUS.FEATURES.THINKING_READY')
                  }}
                </span>
              </div>
            </div>
            <div
              v-if="feature.capabilities?.length"
              class="text-xs text-n-slate-11"
            >
              {{
                t('CAPTAIN_SETTINGS.RUNTIME_STATUS.FEATURES.CAPABILITIES', {
                  capabilities: feature.capabilities.join(', '),
                })
              }}
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
