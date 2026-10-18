<script setup>
import { ref, computed, onMounted } from 'vue';
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

const mergePair = async (pair, baseContact, mergeeContact) => {
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

onMounted(() => {
  fetchDuplicates();
});
</script>

<template>
  <section class="flex h-full w-full flex-col overflow-hidden bg-n-background">
    <header
      class="flex flex-wrap items-center justify-between gap-4 border-b border-n-weak px-6 py-4"
    >
      <div>
        <div class="flex items-center gap-2">
          <h1 class="text-lg font-semibold text-n-slate-12">
            {{ t('CONTACTS_DUPLICATES.TITLE') }}
          </h1>
          <span
            class="rounded-full bg-n-alpha-2 px-2.5 py-0.5 text-xs font-medium text-n-slate-11"
          >
            {{ filteredPairs.length }}
          </span>
        </div>
        <p class="mt-0.5 text-xs text-n-slate-11">
          {{ t('CONTACTS_DUPLICATES.DESCRIPTION') }}
        </p>
      </div>

      <div class="flex items-center gap-3">
        <input
          v-model="searchQuery"
          type="search"
          :placeholder="t('CONTACTS_DUPLICATES.SEARCH_PLACEHOLDER')"
          class="h-9 w-64 rounded-lg border border-n-weak bg-n-alpha-1 px-3 text-xs text-n-slate-12 placeholder:text-n-slate-10 focus:border-n-brand focus:outline-none"
        />
        <Button
          variant="faded"
          color="slate"
          size="sm"
          icon="i-lucide-refresh-cw"
          :label="t('CONTACTS_DUPLICATES.REFRESH')"
          :is-loading="isLoading"
          @click="fetchDuplicates"
        />
      </div>
    </header>

    <div class="flex-1 overflow-y-auto px-6 py-5">
      <div
        v-if="isLoading && !duplicatePairs.length"
        class="flex h-64 items-center justify-center"
      >
        <Spinner class="text-n-brand" />
      </div>

      <div
        v-else-if="!filteredPairs.length"
        class="flex h-64 flex-col items-center justify-center rounded-xl border border-dashed border-n-weak bg-n-alpha-1 p-8 text-center"
      >
        <p class="text-sm font-medium text-n-slate-12">
          {{ t('CONTACTS_DUPLICATES.EMPTY_TITLE') }}
        </p>
        <p class="mt-1 max-w-md text-xs text-n-slate-11">
          {{ t('CONTACTS_DUPLICATES.EMPTY_DESCRIPTION') }}
        </p>
      </div>

      <div v-else class="flex flex-col gap-4">
        <article
          v-for="pair in filteredPairs"
          :key="pair.id"
          class="rounded-xl border border-n-weak bg-n-solid-2 p-4 shadow-xs"
        >
          <div class="mb-3 flex flex-wrap items-center gap-2">
            <span
              v-for="reason in pair.match_reasons"
              :key="reason"
              class="rounded-full bg-n-amber-3 px-2.5 py-0.5 text-xs font-medium text-n-amber-11"
            >
              {{ reasonLabel(reason) }}
            </span>
          </div>

          <div class="grid gap-3 lg:grid-cols-2">
            <div
              v-for="(contact, role) in {
                primary: pair.primary_contact,
                duplicate: pair.conflicting_contact,
              }"
              :key="role"
              class="flex flex-col justify-between rounded-lg border border-n-weak bg-n-alpha-1 p-3.5"
            >
              <div>
                <div class="flex items-center justify-between gap-2">
                  <span
                    class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
                  >
                    {{
                      role === 'primary'
                        ? t('CONTACTS_DUPLICATES.PRIMARY_ROLE')
                        : t('CONTACTS_DUPLICATES.DUPLICATE_ROLE')
                    }}
                  </span>
                  <Button
                    variant="ghost"
                    color="slate"
                    size="xs"
                    :label="t('CONTACTS_DUPLICATES.ACTIONS.OPEN_CONTACT')"
                    @click="openContact(contact)"
                  />
                </div>

                <p class="mt-1 text-sm font-semibold text-n-slate-12">
                  {{ contactTitle(contact) }}
                </p>

                <dl class="mt-3 grid grid-cols-2 gap-2 text-xs text-n-slate-11">
                  <div>
                    <dt class="text-n-slate-10">
                      {{ t('CONTACTS_DUPLICATES.FIELDS.PHONE') }}
                    </dt>
                    <dd class="font-medium text-n-slate-12">
                      {{ contact.phone_number || '—' }}
                    </dd>
                  </div>

                  <div
                    v-if="
                      contact.secondary_phones &&
                      contact.secondary_phones.length
                    "
                  >
                    <dt class="text-n-slate-10">
                      {{ t('CONTACTS_DUPLICATES.FIELDS.SECONDARY_PHONES') }}
                    </dt>
                    <dd class="font-medium text-n-slate-12">
                      {{ contact.secondary_phones.join(', ') }}
                    </dd>
                  </div>

                  <div v-if="contact.email">
                    <dt class="text-n-slate-10">
                      {{ t('CONTACTS_DUPLICATES.FIELDS.EMAIL') }}
                    </dt>
                    <dd class="font-medium text-n-slate-12">
                      {{ contact.email }}
                    </dd>
                  </div>

                  <div v-if="contact.identifier_masked">
                    <dt class="text-n-slate-10">
                      {{ t('CONTACTS_DUPLICATES.FIELDS.IIN') }}
                    </dt>
                    <dd class="font-medium text-n-slate-12">
                      {{ contact.identifier_masked }}
                    </dd>
                  </div>

                  <div v-if="contact.birth_date">
                    <dt class="text-n-slate-10">
                      {{ t('CONTACTS_DUPLICATES.FIELDS.BIRTH_DATE') }}
                    </dt>
                    <dd class="font-medium text-n-slate-12">
                      {{ contact.birth_date }}
                    </dd>
                  </div>

                  <div v-if="contact.patient_code">
                    <dt class="text-n-slate-10">
                      {{ t('CONTACTS_DUPLICATES.FIELDS.PATIENT_CODE') }}
                    </dt>
                    <dd class="font-medium text-n-slate-12">
                      {{ contact.patient_code }}
                    </dd>
                  </div>

                  <div>
                    <dt class="text-n-slate-10">
                      {{ t('CONTACTS_DUPLICATES.FIELDS.CONVERSATIONS') }}
                    </dt>
                    <dd>{{ contact.conversations_count }}</dd>
                  </div>

                  <div>
                    <dt class="text-n-slate-10">
                      {{ t('CONTACTS_DUPLICATES.FIELDS.APPOINTMENTS') }}
                    </dt>
                    <dd>{{ contact.appointments_count }}</dd>
                  </div>

                  <div>
                    <dt class="text-n-slate-10">
                      {{ t('CONTACTS_DUPLICATES.FIELDS.DEALS') }}
                    </dt>
                    <dd>{{ contact.deals_count }}</dd>
                  </div>

                  <div>
                    <dt class="text-n-slate-10">
                      {{ t('CONTACTS_DUPLICATES.FIELDS.CALLS') }}
                    </dt>
                    <dd>{{ contact.call_sessions_count }}</dd>
                  </div>
                </dl>
              </div>
            </div>
          </div>

          <div class="mt-4 flex flex-wrap items-center gap-2">
            <Button
              size="sm"
              :is-loading="activePairId === pair.id"
              :disabled="activePairId === pair.id"
              :label="
                t('CONTACTS_DUPLICATES.ACTIONS.KEEP_LEFT', {
                  name: contactTitle(pair.primary_contact),
                })
              "
              @click="
                mergePair(pair, pair.primary_contact, pair.conflicting_contact)
              "
            />
            <Button
              variant="faded"
              color="slate"
              size="sm"
              :is-loading="activePairId === pair.id"
              :disabled="activePairId === pair.id"
              :label="
                t('CONTACTS_DUPLICATES.ACTIONS.KEEP_RIGHT', {
                  name: contactTitle(pair.conflicting_contact),
                })
              "
              @click="
                mergePair(pair, pair.conflicting_contact, pair.primary_contact)
              "
            />
            <Button
              variant="ghost"
              color="slate"
              size="sm"
              :disabled="activePairId === pair.id"
              :label="t('CONTACTS_DUPLICATES.ACTIONS.DISMISS')"
              @click="dismissPair(pair)"
            />
          </div>
        </article>
      </div>
    </div>
  </section>
</template>
