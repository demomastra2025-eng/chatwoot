<script setup>
import { ref, reactive, computed, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import { useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import ContactAPI from 'dashboard/api/contacts';

import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const store = useStore();

const isLoading = ref(false);
const activePairId = ref(null);
const searchQuery = ref('');
const duplicatePairs = ref([]);
const swappedPairIds = reactive({});

const fetchDuplicates = async () => {
  isLoading.value = true;
  try {
    const { data } = await ContactAPI.getDuplicates();
    duplicatePairs.value = data?.payload || [];
  } catch (error) {
    useAlert(t('CONTACTS_DUPLICATES.ACTIONS.MERGE_ERROR'));
  } finally {
    isLoading.value = false;
  }
};

const matchesContactQuery = (contact, query) => {
  if (!contact) return false;
  const values = [
    contact.name,
    contact.phone_number,
    contact.email,
    contact.identifier_masked,
    contact.patient_code,
    contact.birth_date,
    ...(contact.secondary_phones || []),
  ];
  return values.some(val =>
    String(val || '')
      .toLowerCase()
      .includes(query)
  );
};

const filteredPairs = computed(() => {
  const query = searchQuery.value.trim().toLowerCase();
  if (!query) return duplicatePairs.value;

  return duplicatePairs.value.filter(
    pair =>
      matchesContactQuery(pair.primary_contact, query) ||
      matchesContactQuery(pair.conflicting_contact, query)
  );
});

const reasonLabel = reason => t(`CONTACTS_DUPLICATES.REASONS.${reason}`);

const contactTitle = contact => {
  if (!contact) return '';
  return contact.name || `#${contact.id}`;
};

const isRightSelected = pairId => Boolean(swappedPairIds[pairId]);

const selectPrimarySide = (pairId, side) => {
  swappedPairIds[pairId] = side === 'right';
};

const togglePrimarySide = pairId => {
  swappedPairIds[pairId] = !swappedPairIds[pairId];
};

const resolvePairContacts = pair => {
  if (isRightSelected(pair.id)) {
    return {
      baseContact: pair.conflicting_contact,
      mergeeContact: pair.primary_contact,
    };
  }
  return {
    baseContact: pair.primary_contact,
    mergeeContact: pair.conflicting_contact,
  };
};

const buildActivitySummary = contact => {
  if (!contact) return '';
  const items = [
    {
      count: Number(contact.conversations_count || 0),
      label: t('CONTACTS_DUPLICATES.FIELDS.CONVERSATIONS'),
    },
    {
      count: Number(contact.appointments_count || 0),
      label: t('CONTACTS_DUPLICATES.FIELDS.APPOINTMENTS'),
    },
    {
      count: Number(contact.deals_count || 0),
      label: t('CONTACTS_DUPLICATES.FIELDS.DEALS'),
    },
    {
      count: Number(contact.call_sessions_count || 0),
      label: t('CONTACTS_DUPLICATES.FIELDS.CALLS'),
    },
  ].filter(item => item.count > 0);

  return items.map(item => `${item.label}: ${item.count}`).join(' · ');
};

const buildSecondaryMeta = contact => {
  if (!contact) return [];
  const meta = [];
  if (contact.identifier_masked) {
    meta.push(
      `${t('CONTACTS_DUPLICATES.FIELDS.IIN')}: ${contact.identifier_masked}`
    );
  }
  if (contact.patient_code) {
    meta.push(
      `${t('CONTACTS_DUPLICATES.FIELDS.PATIENT_CODE')}: ${contact.patient_code}`
    );
  }
  if (contact.birth_date) {
    meta.push(contact.birth_date);
  }
  if (contact.email) {
    meta.push(contact.email);
  }
  if (contact.secondary_phones?.length) {
    meta.push(contact.secondary_phones.join(', '));
  }
  return meta;
};

const openContact = contact => {
  if (!contact?.id) return;
  router.push({
    name: 'contacts_edit',
    params: {
      accountId: route.params.accountId,
      contactId: contact.id,
    },
  });
};

const mergePair = async pair => {
  const { baseContact, mergeeContact } = resolvePairContacts(pair);
  if (!baseContact?.id || !mergeeContact?.id) return;
  activePairId.value = pair.id;
  try {
    await store.dispatch('contacts/merge', {
      parentId: baseContact.id,
      childId: mergeeContact.id,
    });
    duplicatePairs.value = duplicatePairs.value.filter(
      item =>
        item.id !== pair.id &&
        item.primary_contact?.id !== mergeeContact.id &&
        item.conflicting_contact?.id !== mergeeContact.id
    );
    useAlert(t('CONTACTS_DUPLICATES.ACTIONS.MERGE_SUCCESS'));
  } catch (error) {
    const message =
      error?.response?.data?.error ||
      error?.message ||
      t('CONTACTS_DUPLICATES.ACTIONS.MERGE_ERROR');
    useAlert(message);
  } finally {
    activePairId.value = null;
  }
};

const dismissPair = async pair => {
  const firstId = pair.primary_contact?.id;
  const secondId = pair.conflicting_contact?.id;
  if (!firstId || !secondId) return;

  activePairId.value = pair.id;
  try {
    await ContactAPI.dismissDuplicate(firstId, secondId);
    duplicatePairs.value = duplicatePairs.value.filter(
      item => item.id !== pair.id
    );
    useAlert(t('CONTACTS_DUPLICATES.ACTIONS.DISMISS_SUCCESS'));
  } catch (error) {
    useAlert(t('CONTACTS_DUPLICATES.ACTIONS.DISMISS_ERROR'));
  } finally {
    activePairId.value = null;
  }
};

onMounted(fetchDuplicates);
</script>

<template>
  <section class="flex h-full w-full flex-col overflow-hidden bg-n-background">
    <header
      class="flex flex-wrap items-center justify-between gap-4 border-b border-n-weak px-6 py-3.5"
    >
      <div>
        <div class="flex items-center gap-2">
          <h1 class="text-base font-semibold text-n-slate-12">
            {{ t('CONTACTS_DUPLICATES.TITLE') }}
          </h1>
          <span
            class="rounded-full bg-n-alpha-2 px-2 py-0.5 text-xs font-medium text-n-slate-11"
          >
            {{ filteredPairs.length }}
          </span>
        </div>
        <p class="mt-0.5 text-xs text-n-slate-11">
          {{ t('CONTACTS_DUPLICATES.DESCRIPTION') }}
        </p>
      </div>

      <div class="flex items-center gap-2.5">
        <input
          v-model="searchQuery"
          type="search"
          :placeholder="t('CONTACTS_DUPLICATES.SEARCH_PLACEHOLDER')"
          class="h-8 w-64 rounded-lg border border-n-weak bg-n-alpha-1 px-3 text-xs text-n-slate-12 placeholder:text-n-slate-10 focus:border-n-brand focus:outline-none"
        />
        <Button
          variant="faded"
          color="slate"
          size="xs"
          icon="i-lucide-refresh-cw"
          :label="t('CONTACTS_DUPLICATES.REFRESH')"
          :is-loading="isLoading"
          @click="fetchDuplicates"
        />
      </div>
    </header>

    <div class="flex-1 overflow-y-auto px-6 py-4">
      <div
        v-if="isLoading && !duplicatePairs.length"
        class="flex h-64 items-center justify-center"
      >
        <Spinner class="text-n-brand" />
      </div>

      <div
        v-else-if="!filteredPairs.length"
        class="flex h-56 flex-col items-center justify-center rounded-xl border border-dashed border-n-weak bg-n-alpha-1 p-6 text-center"
      >
        <p class="text-sm font-medium text-n-slate-12">
          {{ t('CONTACTS_DUPLICATES.EMPTY_TITLE') }}
        </p>
        <p class="mt-1 max-w-md text-xs text-n-slate-11">
          {{ t('CONTACTS_DUPLICATES.EMPTY_DESCRIPTION') }}
        </p>
      </div>

      <div v-else class="flex flex-col gap-2">
        <article
          v-for="pair in filteredPairs"
          :key="pair.id"
          data-testid="duplicate-pair-row"
          class="flex flex-col gap-2.5 rounded-xl border border-n-weak bg-n-solid-2 px-3.5 py-2.5 transition-colors hover:border-n-slate-6 lg:flex-row lg:items-center lg:justify-between"
        >
          <!-- Left + Center + Right contacts in one compact horizontal strip -->
          <div
            class="grid flex-1 grid-cols-1 items-center gap-2 lg:grid-cols-[1fr_auto_1fr]"
          >
            <!-- Left Contact -->
            <div
              data-testid="duplicate-contact-left"
              role="button"
              tabindex="0"
              class="flex items-center justify-between gap-2 rounded-lg border px-3 py-2 text-left transition-colors cursor-pointer"
              :class="
                !isRightSelected(pair.id)
                  ? 'border-n-teal-9/40 bg-n-teal-9/5'
                  : 'border-n-weak bg-n-alpha-1 opacity-80 hover:opacity-100'
              "
              @click="selectPrimarySide(pair.id, 'left')"
              @keydown.enter.prevent="selectPrimarySide(pair.id, 'left')"
            >
              <div class="min-w-0 flex-1">
                <div class="flex flex-wrap items-center gap-1.5">
                  <span
                    class="rounded px-1.5 py-0.5 text-[10px] font-medium"
                    :class="
                      !isRightSelected(pair.id)
                        ? 'bg-n-teal-9/15 text-n-teal-11'
                        : 'bg-n-alpha-2 text-n-slate-10'
                    "
                  >
                    {{
                      !isRightSelected(pair.id)
                        ? t('CONTACTS_DUPLICATES.KEEP_BADGE')
                        : t('CONTACTS_DUPLICATES.MERGE_INTO_BADGE')
                    }}
                  </span>
                  <span class="truncate text-xs font-semibold text-n-slate-12">
                    {{ contactTitle(pair.primary_contact) }}
                  </span>
                  <span class="font-mono text-xs text-n-slate-11">
                    {{ pair.primary_contact?.phone_number || '—' }}
                  </span>
                </div>

                <div
                  v-if="
                    buildActivitySummary(pair.primary_contact) ||
                    buildSecondaryMeta(pair.primary_contact).length
                  "
                  class="mt-1 flex flex-wrap items-center gap-1.5 text-[11px] text-n-slate-11"
                >
                  <span
                    v-if="buildActivitySummary(pair.primary_contact)"
                    data-testid="contact-activity-pill"
                    class="rounded bg-n-alpha-2 px-1.5 py-0.5 font-medium text-n-slate-12"
                  >
                    {{ buildActivitySummary(pair.primary_contact) }}
                  </span>
                  <span
                    v-for="metaItem in buildSecondaryMeta(pair.primary_contact)"
                    :key="metaItem"
                    class="truncate text-n-slate-10"
                  >
                    {{ metaItem }}
                  </span>
                </div>
              </div>

              <button
                type="button"
                class="shrink-0 rounded p-1 text-n-slate-10 hover:bg-n-alpha-2 hover:text-n-slate-12"
                :title="t('CONTACTS_DUPLICATES.ACTIONS.OPEN_CONTACT')"
                @click.stop="openContact(pair.primary_contact)"
              >
                <span class="i-lucide-external-link size-3.5 block" />
              </button>
            </div>

            <!-- Center: match reason + 1-click direction toggle -->
            <div class="flex flex-row items-center justify-center gap-1.5 px-1 lg:flex-col">
              <div class="flex flex-wrap justify-center gap-1">
                <span
                  v-for="reason in pair.match_reasons"
                  :key="reason"
                  class="rounded-full bg-n-amber-3 px-2 py-0.5 text-[10px] font-medium text-n-amber-11 whitespace-nowrap"
                >
                  {{ reasonLabel(reason) }}
                </span>
              </div>
              <button
                type="button"
                data-testid="swap-primary-btn"
                class="inline-flex items-center gap-1 rounded-md border border-n-weak bg-n-alpha-1 px-1.5 py-0.5 text-[11px] text-n-slate-11 transition-colors hover:border-n-brand hover:text-n-brand"
                :title="t('CONTACTS_DUPLICATES.SWAP_DIRECTION')"
                @click="togglePrimarySide(pair.id)"
              >
                <span
                  :class="
                    isRightSelected(pair.id)
                      ? 'i-lucide-arrow-right size-3'
                      : 'i-lucide-arrow-left size-3'
                  "
                />
                <span class="i-lucide-arrow-left-right size-3 opacity-70" />
              </button>
            </div>

            <!-- Right Contact -->
            <div
              data-testid="duplicate-contact-right"
              role="button"
              tabindex="0"
              class="flex items-center justify-between gap-2 rounded-lg border px-3 py-2 text-left transition-colors cursor-pointer"
              :class="
                isRightSelected(pair.id)
                  ? 'border-n-teal-9/40 bg-n-teal-9/5'
                  : 'border-n-weak bg-n-alpha-1 opacity-80 hover:opacity-100'
              "
              @click="selectPrimarySide(pair.id, 'right')"
              @keydown.enter.prevent="selectPrimarySide(pair.id, 'right')"
            >
              <div class="min-w-0 flex-1">
                <div class="flex flex-wrap items-center gap-1.5">
                  <span
                    class="rounded px-1.5 py-0.5 text-[10px] font-medium"
                    :class="
                      isRightSelected(pair.id)
                        ? 'bg-n-teal-9/15 text-n-teal-11'
                        : 'bg-n-alpha-2 text-n-slate-10'
                    "
                  >
                    {{
                      isRightSelected(pair.id)
                        ? t('CONTACTS_DUPLICATES.KEEP_BADGE')
                        : t('CONTACTS_DUPLICATES.MERGE_INTO_BADGE')
                    }}
                  </span>
                  <span class="truncate text-xs font-semibold text-n-slate-12">
                    {{ contactTitle(pair.conflicting_contact) }}
                  </span>
                  <span class="font-mono text-xs text-n-slate-11">
                    {{ pair.conflicting_contact?.phone_number || '—' }}
                  </span>
                </div>

                <div
                  v-if="
                    buildActivitySummary(pair.conflicting_contact) ||
                    buildSecondaryMeta(pair.conflicting_contact).length
                  "
                  class="mt-1 flex flex-wrap items-center gap-1.5 text-[11px] text-n-slate-11"
                >
                  <span
                    v-if="buildActivitySummary(pair.conflicting_contact)"
                    data-testid="contact-activity-pill"
                    class="rounded bg-n-alpha-2 px-1.5 py-0.5 font-medium text-n-slate-12"
                  >
                    {{ buildActivitySummary(pair.conflicting_contact) }}
                  </span>
                  <span
                    v-for="metaItem in buildSecondaryMeta(
                      pair.conflicting_contact
                    )"
                    :key="metaItem"
                    class="truncate text-n-slate-10"
                  >
                    {{ metaItem }}
                  </span>
                </div>
              </div>

              <button
                type="button"
                class="shrink-0 rounded p-1 text-n-slate-10 hover:bg-n-alpha-2 hover:text-n-slate-12"
                :title="t('CONTACTS_DUPLICATES.ACTIONS.OPEN_CONTACT')"
                @click.stop="openContact(pair.conflicting_contact)"
              >
                <span class="i-lucide-external-link size-3.5 block" />
              </button>
            </div>
          </div>

          <!-- Compact Actions on the right -->
          <div class="flex shrink-0 items-center justify-end gap-1.5 lg:pl-2">
            <Button
              data-testid="merge-pair-btn"
              size="xs"
              :is-loading="activePairId === pair.id"
              :disabled="activePairId === pair.id"
              :label="t('CONTACTS_DUPLICATES.ACTIONS.MERGE')"
              @click="mergePair(pair)"
            />
            <Button
              data-testid="dismiss-pair-btn"
              variant="ghost"
              color="slate"
              size="xs"
              :disabled="activePairId === pair.id"
              :label="t('CONTACTS_DUPLICATES.ACTIONS.DISMISS_SHORT')"
              @click="dismissPair(pair)"
            />
          </div>
        </article>
      </div>
    </div>
  </section>
</template>
