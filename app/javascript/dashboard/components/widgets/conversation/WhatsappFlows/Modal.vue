<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';
import NextButton from 'dashboard/components-next/button/Button.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';

const props = defineProps({
  show: {
    type: Boolean,
    default: false,
  },
  inboxId: {
    type: Number,
    default: undefined,
  },
  conversationId: {
    type: Number,
    default: undefined,
  },
});

const emit = defineEmits(['onSend', 'cancel', 'update:show']);

const FLOW_MESSAGE_KIND = 'whatsapp_flow';

const { t } = useI18n();
const store = useStore();

const query = ref('');
const selectedFlowId = ref(null);
const bodyText = ref('');
const ctaText = ref('');
const headerText = ref('');
const footerText = ref('');
const isFetching = ref(false);
const isSending = ref(false);

const localShow = computed({
  get() {
    return props.show;
  },
  set(value) {
    emit('update:show', value);
  },
});

const whatsAppFlows = computed(() => {
  if (!props.inboxId) return [];
  return store.getters['inboxes/getSendableWhatsAppFlows'](props.inboxId) || [];
});

const filteredFlows = computed(() => {
  const search = query.value.trim().toLowerCase();
  if (!search) return whatsAppFlows.value;

  return whatsAppFlows.value.filter(flow => {
    return [
      flow.display_title,
      flow.displayTitle,
      flow.title,
      flow.name,
      flow.provider_flow_id,
      flow.providerFlowId,
      flow.category,
      flow.status,
    ]
      .filter(Boolean)
      .some(value => String(value).toLowerCase().includes(search));
  });
});

const selectedFlow = computed(() =>
  whatsAppFlows.value.find(
    flow => String(flow.id) === String(selectedFlowId.value)
  )
);

const flowLabel = flow =>
  flow?.display_title || flow?.displayTitle || flow?.title || flow?.name || '';
const flowProviderId = flow =>
  flow?.provider_flow_id || flow?.providerFlowId || '';
const flowJson = flow => flow?.flow_json || flow?.flowJson || {};
const flowMetadata = flow => flow?.metadata || {};
const firstScreenId = flow => flowJson(flow)?.screens?.[0]?.id;

const defaultCta = flow =>
  flowMetadata(flow).flow_cta ||
  flowMetadata(flow).cta ||
  t('WHATSAPP_FLOWS.MODAL.DEFAULT_CTA');

const resetComposer = () => {
  selectedFlowId.value = null;
  bodyText.value = '';
  ctaText.value = '';
  headerText.value = '';
  footerText.value = '';
};

const fetchFlows = async () => {
  if (!props.inboxId) return;
  isFetching.value = true;
  try {
    await store.dispatch('inboxes/fetchWhatsAppFlows', props.inboxId);
  } catch (error) {
    useAlert(error?.message || t('WHATSAPP_FLOWS.MODAL.LOAD_ERROR'));
  } finally {
    isFetching.value = false;
  }
};

const selectFlow = flow => {
  selectedFlowId.value = flow.id;
  ctaText.value = defaultCta(flow);
  bodyText.value = t('WHATSAPP_FLOWS.MODAL.DEFAULT_BODY', {
    flow: flowLabel(flow),
  });
  headerText.value = '';
  footerText.value = '';
};

const closeModal = () => {
  emit('cancel');
};

const compactObject = object => {
  return Object.fromEntries(
    Object.entries(object).filter(([, value]) => {
      if (value === undefined || value === null) return false;
      if (typeof value === 'string' && value.trim() === '') return false;
      if (typeof value === 'object' && Object.keys(value).length === 0) {
        return false;
      }
      return true;
    })
  );
};

const sendFlow = async () => {
  if (!selectedFlow.value || !props.inboxId) return;

  if (!bodyText.value.trim() || !ctaText.value.trim()) {
    useAlert(t('WHATSAPP_FLOWS.MODAL.VALIDATION_ERROR'));
    return;
  }

  isSending.value = true;
  try {
    const session = await store.dispatch('inboxes/createWhatsAppFlowSession', {
      inboxId: props.inboxId,
      flowId: selectedFlow.value.id,
      session: {
        conversation_id: props.conversationId,
        request_payload: {
          provider_flow_id: flowProviderId(selectedFlow.value),
          name: selectedFlow.value.name,
        },
      },
    });

    const actionPayload = firstScreenId(selectedFlow.value)
      ? { screen: firstScreenId(selectedFlow.value) }
      : {};

    emit('onSend', {
      message: bodyText.value.trim(),
      contentAttributes: {
        data: compactObject({
          kind: FLOW_MESSAGE_KIND,
          flow_id: flowProviderId(selectedFlow.value),
          flow_name: selectedFlow.value.name,
          flow_session_id: session.id,
          flow_cta: ctaText.value.trim(),
          flow_action: 'navigate',
          flow_action_payload: actionPayload,
          mode: selectedFlow.value.mode || 'published',
          header_text: headerText.value.trim(),
          body_text: bodyText.value.trim(),
          footer_text: footerText.value.trim(),
          display_title: flowLabel(selectedFlow.value),
        }),
      },
    });
    resetComposer();
  } catch (error) {
    useAlert(error?.message || t('WHATSAPP_FLOWS.MODAL.SEND_ERROR'));
  } finally {
    isSending.value = false;
  }
};

watch(
  () => props.show,
  value => {
    if (value) {
      fetchFlows();
    } else {
      resetComposer();
      query.value = '';
    }
  }
);
</script>

<template>
  <woot-modal v-model:show="localShow" size="modal-big" @close="closeModal">
    <woot-modal-header
      :header-title="$t('WHATSAPP_FLOWS.MODAL.TITLE')"
      :header-content="$t('WHATSAPP_FLOWS.MODAL.SUBTITLE')"
    />

    <div class="row modal-content">
      <div class="flex flex-col gap-4 w-full">
        <div class="flex gap-2">
          <div
            class="flex flex-1 gap-1 items-center px-2.5 rounded-lg bg-n-alpha-black2 outline outline-1 outline-n-weak focus-within:outline-n-brand"
          >
            <input
              v-model="query"
              type="search"
              :placeholder="$t('WHATSAPP_FLOWS.MODAL.SEARCH_PLACEHOLDER')"
              class="reset-base h-9 w-full bg-transparent text-sm text-n-slate-12 outline-0"
            />
            <Icon icon="i-lucide-search" class="size-4 text-n-slate-11" />
          </div>
          <NextButton
            slate
            faded
            sm
            icon="i-lucide-refresh-ccw"
            :is-loading="isFetching"
            :label="$t('WHATSAPP_FLOWS.MODAL.REFRESH')"
            @click="fetchFlows"
          />
        </div>

        <div v-if="isFetching" class="py-8 text-center text-sm text-n-slate-11">
          {{ $t('WHATSAPP_FLOWS.MODAL.LOADING') }}
        </div>

        <div
          v-else-if="!whatsAppFlows.length"
          class="rounded-xl border border-dashed border-n-weak p-6 text-center"
        >
          <p class="text-sm font-medium text-n-slate-12">
            {{ $t('WHATSAPP_FLOWS.MODAL.EMPTY_TITLE') }}
          </p>
          <p class="mt-1 text-sm text-n-slate-11">
            {{ $t('WHATSAPP_FLOWS.MODAL.EMPTY_DESCRIPTION') }}
          </p>
        </div>

        <div
          v-else
          class="grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)]"
        >
          <div
            class="max-h-[24rem] overflow-y-auto rounded-xl border border-n-weak bg-n-background p-2"
          >
            <button
              v-for="flow in filteredFlows"
              :key="flow.id"
              type="button"
              class="block w-full rounded-lg p-3 text-left hover:bg-n-alpha-2 focus-visible:bg-n-alpha-2 focus-visible:outline-none"
              :class="{
                'bg-n-alpha-2 outline outline-1 outline-n-brand':
                  String(selectedFlowId) === String(flow.id),
              }"
              data-testid="whatsapp-flow-option"
              @click="selectFlow(flow)"
            >
              <div class="flex items-start justify-between gap-2">
                <div class="min-w-0">
                  <p class="truncate text-sm font-medium text-n-slate-12">
                    {{ flowLabel(flow) }}
                  </p>
                  <p class="truncate text-xs text-n-slate-11">
                    {{ flowProviderId(flow) || flow.name }}
                  </p>
                </div>
                <span
                  class="rounded-full bg-n-alpha-2 px-2 py-0.5 text-xs text-n-slate-11"
                >
                  {{ flow.status || flow.mode }}
                </span>
              </div>
            </button>

            <p
              v-if="!filteredFlows.length"
              class="p-4 text-center text-sm text-n-slate-11"
            >
              {{ $t('WHATSAPP_FLOWS.MODAL.NO_RESULTS') }}
            </p>
          </div>

          <div class="rounded-xl border border-n-weak bg-n-alpha-black2 p-4">
            <template v-if="selectedFlow">
              <div class="mb-4">
                <p class="text-sm font-medium text-n-slate-12">
                  {{ flowLabel(selectedFlow) }}
                </p>
                <p class="text-xs text-n-slate-11">
                  {{ $t('WHATSAPP_FLOWS.MODAL.CONFIGURE_HINT') }}
                </p>
              </div>

              <label class="mb-3 block">
                <span class="mb-1 block text-xs font-medium text-n-slate-11">
                  {{ $t('WHATSAPP_FLOWS.MODAL.FIELDS.HEADER') }}
                </span>
                <input
                  v-model="headerText"
                  type="text"
                  class="reset-base w-full rounded-lg border border-n-weak bg-n-background px-3 py-2 text-sm text-n-slate-12 outline-0 focus:border-n-brand"
                />
              </label>

              <label class="mb-3 block">
                <span class="mb-1 block text-xs font-medium text-n-slate-11">
                  {{ $t('WHATSAPP_FLOWS.MODAL.FIELDS.BODY') }}
                </span>
                <textarea
                  v-model="bodyText"
                  rows="4"
                  class="reset-base w-full rounded-lg border border-n-weak bg-n-background px-3 py-2 text-sm text-n-slate-12 outline-0 focus:border-n-brand"
                />
              </label>

              <div class="grid gap-3 md:grid-cols-2">
                <label class="block">
                  <span class="mb-1 block text-xs font-medium text-n-slate-11">
                    {{ $t('WHATSAPP_FLOWS.MODAL.FIELDS.CTA') }}
                  </span>
                  <input
                    v-model="ctaText"
                    type="text"
                    class="reset-base w-full rounded-lg border border-n-weak bg-n-background px-3 py-2 text-sm text-n-slate-12 outline-0 focus:border-n-brand"
                  />
                </label>

                <label class="block">
                  <span class="mb-1 block text-xs font-medium text-n-slate-11">
                    {{ $t('WHATSAPP_FLOWS.MODAL.FIELDS.FOOTER') }}
                  </span>
                  <input
                    v-model="footerText"
                    type="text"
                    class="reset-base w-full rounded-lg border border-n-weak bg-n-background px-3 py-2 text-sm text-n-slate-12 outline-0 focus:border-n-brand"
                  />
                </label>
              </div>

              <div class="mt-5 flex justify-end gap-2">
                <NextButton
                  slate
                  faded
                  :label="$t('WHATSAPP_FLOWS.MODAL.CANCEL')"
                  @click="resetComposer"
                />
                <NextButton
                  color="blue"
                  :is-loading="isSending"
                  :disabled="isSending"
                  :label="$t('WHATSAPP_FLOWS.MODAL.SEND')"
                  @click="sendFlow"
                />
              </div>
            </template>
            <div v-else class="py-12 text-center text-sm text-n-slate-11">
              {{ $t('WHATSAPP_FLOWS.MODAL.SELECT_PROMPT') }}
            </div>
          </div>
        </div>
      </div>
    </div>
  </woot-modal>
</template>

<style scoped>
.modal-content {
  padding: 1.5625rem 2rem;
}
</style>
