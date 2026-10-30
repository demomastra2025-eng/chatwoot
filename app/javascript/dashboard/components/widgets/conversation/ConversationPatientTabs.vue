<script setup>
import { computed, onBeforeUnmount, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { resolveOptionalPatientStore } from 'dashboard/composables/useConversationPatientContext';
import FamilyPatientCardModal from './FamilyPatientCardModal.vue';
import {
  maskedPatientIin,
  patientAgeLabel,
  patientDisplayName,
} from 'dashboard/stores/scheduling/patientContext';

const props = defineProps({
  contextKey: { type: String, required: true },
  entry: { type: Object, default: null },
  conversationDisplayId: { type: [Number, String], default: null },
});

const MAX_VISIBLE_TABS = 3;

const { t, locale } = useI18n();
const patientStore = resolveOptionalPatientStore();

const isOverflowOpen = ref(false);
const showCreateModal = ref(false);
const overflowRootRef = ref(null);

const patients = computed(() => props.entry?.patients || []);
const selectedId = computed(() => Number(props.entry?.selectedId || 0));
const ownerContactId = computed(() => Number(props.entry?.contactId || 0));

const isPrimaryHolder = patient =>
  Boolean(
    patient?.is_primary_holder || Number(patient?.id) === ownerContactId.value
  );

const isSelected = patient => Number(patient?.id) === selectedId.value;

const visiblePatients = computed(() => {
  const list = patients.value;
  if (list.length <= MAX_VISIBLE_TABS) return list;

  const base = list.slice(0, MAX_VISIBLE_TABS);
  if (base.some(item => isSelected(item))) return base;

  const active = list.find(item => isSelected(item));
  if (!active) return base;
  return [list[0], list[1], active];
});

const overflowCount = computed(() =>
  Math.max(patients.value.length - visiblePatients.value.length, 0)
);

const tabDisplayName = patient =>
  patientDisplayName(patient) || `#${patient?.id || ''}`;

const tabSubtitle = patient => {
  const activeLocale =
    (typeof locale === 'string' ? locale : locale?.value) || 'ru';
  const parts = [
    patientAgeLabel(patient, t, activeLocale),
    maskedPatientIin(patient),
  ].filter(Boolean);
  return parts.join(' · ');
};

const selectCard = patientId => {
  if (!patientStore || !props.contextKey || props.entry?.saving) return;
  patientStore.select(props.contextKey, patientId);
  isOverflowOpen.value = false;
};

const toggleOverflow = () => {
  isOverflowOpen.value = !isOverflowOpen.value;
};

const handleOutsideClick = event => {
  if (!isOverflowOpen.value) return;
  if (overflowRootRef.value && !overflowRootRef.value.contains(event.target)) {
    isOverflowOpen.value = false;
  }
};

onMounted(() => {
  document.addEventListener('mousedown', handleOutsideClick);
});

onBeforeUnmount(() => {
  document.removeEventListener('mousedown', handleOutsideClick);
});
</script>

<template>
  <div
    v-if="patients.length > 1"
    data-test-id="conversation-patient-tabs"
    class="flex w-full min-w-0 items-center gap-1.5 border-t border-n-weak/60 px-3 py-1.5"
  >
    <span
      class="i-lucide-users size-3.5 shrink-0 text-n-slate-10"
      aria-hidden="true"
    />

    <div role="tablist" class="flex min-w-0 flex-wrap items-center gap-1.5">
      <button
        v-for="patient in visiblePatients"
        :key="patient.id"
        type="button"
        role="tab"
        :aria-selected="isSelected(patient)"
        :data-test-id="`conversation-patient-tab-${patient.id}`"
        :title="
          tabSubtitle(patient)
            ? `${tabDisplayName(patient)} (${tabSubtitle(patient)})`
            : tabDisplayName(patient)
        "
        class="inline-flex h-6 max-w-[13rem] items-center gap-1 rounded-full px-2.5 text-xs transition-colors duration-150 cursor-pointer"
        :class="
          isSelected(patient)
            ? 'bg-n-teal-3/70 font-medium text-n-teal-11 ring-1 ring-inset ring-n-teal-7/30'
            : 'bg-n-alpha-1 text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12'
        "
        @click="selectCard(patient.id)"
      >
        <span class="truncate">{{ tabDisplayName(patient) }}</span>
        <span
          v-if="isPrimaryHolder(patient)"
          class="shrink-0 text-[11px] font-normal opacity-75"
        >
          {{ `· ${t('PATIENT_TABS.PRIMARY_SUFFIX')}` }}
        </span>
        <span
          v-if="patient.notifications_muted"
          class="i-lucide-bell-off size-3 shrink-0 text-n-amber-11"
          aria-hidden="true"
        />
      </button>
    </div>

    <div
      v-if="overflowCount > 0"
      ref="overflowRootRef"
      class="relative shrink-0"
    >
      <button
        type="button"
        data-test-id="patient-tabs-overflow-trigger"
        :aria-expanded="isOverflowOpen"
        class="inline-flex h-6 items-center gap-1 rounded-full bg-n-alpha-1 px-2 text-xs text-n-slate-11 transition-colors hover:bg-n-alpha-2 hover:text-n-slate-12 cursor-pointer"
        @click="toggleOverflow"
      >
        <span>{{
          t('PATIENT_TABS.OVERFLOW_MORE', { count: overflowCount })
        }}</span>
        <span
          class="i-lucide-chevron-down size-3 transition-transform"
          :class="{ 'rotate-180': isOverflowOpen }"
        />
      </button>

      <div
        v-if="isOverflowOpen"
        data-test-id="patient-tabs-overflow-menu"
        role="listbox"
        class="absolute left-0 top-full z-40 mt-1 flex min-w-[14rem] max-w-[18rem] max-h-64 flex-col gap-0.5 overflow-y-auto rounded-xl border border-n-weak bg-n-solid-2 p-1 shadow-lg"
      >
        <button
          v-for="patient in patients"
          :key="`overflow-${patient.id}`"
          type="button"
          role="option"
          :aria-selected="isSelected(patient)"
          :data-test-id="`patient-tabs-overflow-option-${patient.id}`"
          class="flex w-full items-center justify-between gap-2 rounded-lg px-2.5 py-1.5 text-left text-xs transition-colors hover:bg-n-alpha-2"
          :class="
            isSelected(patient)
              ? 'bg-n-teal-3/50 font-medium text-n-teal-11'
              : 'text-n-slate-12'
          "
          @click="selectCard(patient.id)"
        >
          <span class="flex min-w-0 flex-1 flex-col">
            <span class="truncate">
              {{ tabDisplayName(patient) }}
              <span
                v-if="isPrimaryHolder(patient)"
                class="text-[11px] font-normal opacity-75"
              >
                {{ `· ${t('PATIENT_TABS.PRIMARY_SUFFIX')}` }}
              </span>
            </span>
            <span
              v-if="tabSubtitle(patient)"
              class="truncate text-[11px] font-normal text-n-slate-10"
            >
              {{ tabSubtitle(patient) }}
            </span>
          </span>
          <span
            v-if="isSelected(patient)"
            class="i-lucide-check size-3.5 shrink-0 text-n-teal-11"
          />
        </button>
      </div>
    </div>

    <button
      type="button"
      data-test-id="patient-tabs-add-button"
      :title="t('PATIENT_TABS.ADD_FAMILY_CARD')"
      :aria-label="t('PATIENT_TABS.ADD_FAMILY_CARD')"
      class="inline-flex size-6 shrink-0 items-center justify-center rounded-full bg-n-alpha-1 text-n-slate-11 transition-colors hover:bg-n-alpha-2 hover:text-n-slate-12 cursor-pointer"
      @click="showCreateModal = true"
    >
      <span class="i-lucide-plus size-3.5" />
    </button>

    <FamilyPatientCardModal
      v-model:show="showCreateModal"
      :context-key="contextKey"
      :contact-id="entry?.contactId"
      :conversation-display-id="conversationDisplayId"
    />
  </div>
</template>
