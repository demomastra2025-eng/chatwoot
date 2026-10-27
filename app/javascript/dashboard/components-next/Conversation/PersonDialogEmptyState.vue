<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';
import { useMapGetter } from 'dashboard/composables/store';
import { useOpenPersonDialog } from 'dashboard/composables/useOpenPersonDialog';
import { getCommunicationReplyChannel } from 'dashboard/helper/communicationThreadHelper';
import { personDialogEmptyStateKind } from 'dashboard/helper/personDialogHelper';

import Button from 'dashboard/components-next/button/Button.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';

// The screen of a person who has no dialog yet and no message in it. It says what the first message needs, in plain words, and
// never asks for anything technical.
const props = defineProps({
  // The channel the reply box has selected (the first message goes there).
  selectedChannelKey: { type: [String, Number], default: null },
});

const { t } = useI18n();
const router = useRouter();
const { openPersonDialog } = useOpenPersonDialog();
const chat = useMapGetter('getSelectedChat');

const holder = computed(() => chat.value?.shared_phone_holder || null);

const activeChannel = computed(() =>
  getCommunicationReplyChannel(chat.value, props.selectedChannelKey)
);

const kind = computed(() =>
  personDialogEmptyStateKind({
    blocked: chat.value?.blocked,
    sharedPhoneHolder: holder.value,
    channels: chat.value?.channels,
    activeChannel: activeChannel.value,
    contact: chat.value?.meta?.sender,
  })
);

const KIND_ICONS = {
  default: 'i-lucide-message-circle',
  whatsapp_template: 'i-lucide-message-square-text',
  needs_phone: 'i-lucide-phone-off',
  shared_phone: 'i-lucide-users',
  no_access: 'i-lucide-lock',
  blocked: 'i-lucide-ban',
};

const text = computed(() => {
  const name = holder.value?.name || '';
  return t(`PERSON_DIALOG.EMPTY.${kind.value.toUpperCase()}`, { name });
});

const personContactId = computed(() => chat.value?.person_contact_id);

const openCard = () => {
  const { href } = router.resolve({
    name: 'contacts_edit',
    params: { contactId: personContactId.value },
  });
  window.open(href, '_blank', 'noopener');
};

const writeToHolder = () =>
  openPersonDialog(holder.value.id, {
    patientContactId: personContactId.value,
  });
</script>

<template>
  <div
    class="flex flex-col items-center justify-center gap-3 px-8 py-10 text-center"
    data-test-id="person-dialog-empty-state"
    :data-kind="kind"
  >
    <div
      class="grid size-10 place-items-center rounded-full bg-n-alpha-black2 text-n-slate-11"
    >
      <Icon :icon="KIND_ICONS[kind]" class="size-5" />
    </div>
    <p
      class="max-w-md text-sm leading-6 text-n-slate-11"
      data-test-id="person-dialog-empty-text"
    >
      {{ text }}
    </p>
    <Button
      v-if="kind === 'needs_phone' || kind === 'blocked'"
      :label="t('PERSON_DIALOG.EMPTY.OPEN_CARD')"
      size="sm"
      slate
      data-test-id="person-dialog-open-card"
      @click="openCard"
    />
    <Button
      v-else-if="kind === 'shared_phone'"
      :label="t('PERSON_DIALOG.EMPTY.WRITE_TO_HOLDER', { name: holder.name })"
      size="sm"
      data-test-id="person-dialog-write-to-holder"
      @click="writeToHolder"
    />
  </div>
</template>
