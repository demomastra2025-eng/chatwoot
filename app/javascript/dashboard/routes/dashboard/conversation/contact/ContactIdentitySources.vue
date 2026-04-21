<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Avatar from 'next/avatar/Avatar.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import {
  getContactSourceIconClass,
  sourceValue,
} from 'dashboard/helper/contactIdentity';

const props = defineProps({
  contact: {
    type: Object,
    default: () => ({}),
  },
  isUpdating: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['select-name-source', 'select-avatar-source']);

const { t } = useI18n();

const valueFor = sourceValue;

const humanizeSource = value => {
  const rawValue = value?.replace('Channel::', '') || '';
  if (!rawValue) {
    return '';
  }

  return rawValue
    .replace(/_/g, ' ')
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .split(' ')
    .filter(Boolean)
    .map(chunk => chunk.charAt(0).toUpperCase() + chunk.slice(1))
    .join(' ');
};

const normalizeSource = source => {
  if (!source) {
    return null;
  }

  return {
    kind: valueFor(source, 'kind'),
    contactInboxId: valueFor(source, 'contactInboxId'),
    inboxId: valueFor(source, 'inboxId'),
    sourceId: valueFor(source, 'sourceId'),
    identifier: valueFor(source, 'identifier'),
  };
};

const sourceMatches = (source, candidate) => {
  const normalizedSource = normalizeSource(source);
  const normalizedCandidate = normalizeSource(candidate);

  if (
    !normalizedSource ||
    !normalizedCandidate ||
    normalizedSource.kind !== normalizedCandidate.kind
  ) {
    return false;
  }

  if (['manual', 'contact_avatar'].includes(normalizedSource.kind)) {
    return true;
  }

  if (normalizedSource.kind !== 'channel_profile') {
    return false;
  }

  const sourceContactInboxId = normalizedSource.contactInboxId;
  const candidateContactInboxId = normalizedCandidate.contactInboxId;
  if (sourceContactInboxId && candidateContactInboxId) {
    return String(sourceContactInboxId) === String(candidateContactInboxId);
  }

  return (
    String(normalizedSource.sourceId || '') ===
      String(normalizedCandidate.sourceId || '') &&
    String(normalizedSource.inboxId || '') ===
      String(normalizedCandidate.inboxId || '')
  );
};

const primaryNameSource = computed(
  () => props.contact.primaryNameSource || props.contact.primary_name_source
);

const primaryAvatarSource = computed(
  () => props.contact.primaryAvatarSource || props.contact.primary_avatar_source
);

const rawProfiles = computed(
  () => props.contact.channelProfiles || props.contact.channel_profiles || []
);

const contactRecordSource = computed(() => {
  const displayName = props.contact.name || '';
  const avatarUrl =
    props.contact.contactAvatarUrl || props.contact.contact_avatar_url || '';
  const phoneNumber = props.contact.phoneNumber || props.contact.phone_number;
  const email = props.contact.email || '';
  const hasSelectableName = Boolean(displayName);
  const hasSelectableAvatar = Boolean(avatarUrl);

  if (!hasSelectableName && !hasSelectableAvatar) {
    return null;
  }

  return {
    id: 'contact-record',
    cardKey: 'contact-record',
    label: t('CONTACT_PANEL.SOURCE_IDENTITIES.CONTACT_CARD'),
    iconClass: 'i-lucide-user-round',
    displayName,
    avatarUrl,
    secondaryLine: email || phoneNumber || '',
    fallbackLine: '',
    nameSource: hasSelectableName ? { kind: 'manual' } : null,
    avatarSource: hasSelectableAvatar ? { kind: 'contact_avatar' } : null,
    nameSelected: sourceMatches(primaryNameSource.value, { kind: 'manual' }),
    avatarSelected: sourceMatches(primaryAvatarSource.value, {
      kind: 'contact_avatar',
    }),
    sourcePriority: 1,
    sortTimestamp: Number.MAX_SAFE_INTEGER,
  };
});

const parsedTimestamp = value => {
  if (typeof value === 'number') {
    return value;
  }

  const parsed = Date.parse(value || '');
  return Number.isNaN(parsed) ? 0 : parsed;
};

const normalizedSources = computed(() => {
  const profileSources = rawProfiles.value
    .map(profile => {
      const displayName =
        valueFor(profile, 'displayName') ||
        valueFor(profile, 'name') ||
        valueFor(valueFor(profile, 'profileData'), 'displayName') ||
        valueFor(valueFor(profile, 'profileData'), 'name') ||
        '';

      const avatarUrl =
        valueFor(profile, 'avatarUrl') ||
        valueFor(profile, 'thumbnail') ||
        valueFor(valueFor(profile, 'profileData'), 'avatarUrl') ||
        valueFor(valueFor(profile, 'profileData'), 'profilePhotoUrl') ||
        valueFor(valueFor(profile, 'profileData'), 'profilePicUrl') ||
        '';

      const provider =
        valueFor(profile, 'provider') || valueFor(profile, 'channelType');

      const username = valueFor(profile, 'username');
      const phoneNumber = valueFor(profile, 'phoneNumber');
      const sourceId = valueFor(profile, 'sourceId');
      const channelSource = {
        kind: 'channel_profile',
        contactInboxId: valueFor(profile, 'contactInboxId'),
        inboxId: valueFor(profile, 'inboxId'),
        channelType: valueFor(profile, 'channelType'),
        provider,
        sourceId,
        identifier: valueFor(profile, 'identifier'),
      };

      return {
        id: valueFor(profile, 'id'),
        cardKey:
          valueFor(profile, 'contactInboxId') ||
          `${provider || 'profile'}:${sourceId || valueFor(profile, 'id')}`,
        displayName,
        avatarUrl,
        label: humanizeSource(provider),
        iconClass: getContactSourceIconClass(channelSource),
        secondaryLine: username || phoneNumber || '',
        fallbackLine: sourceId || valueFor(profile, 'identifier') || '',
        nameSource: displayName ? channelSource : null,
        avatarSource: avatarUrl ? channelSource : null,
        nameSelected: sourceMatches(primaryNameSource.value, channelSource),
        avatarSelected: sourceMatches(primaryAvatarSource.value, channelSource),
        sourcePriority: 0,
        sortTimestamp:
          parsedTimestamp(valueFor(profile, 'lastSyncedAt')) ||
          parsedTimestamp(valueFor(profile, 'updatedAt')) ||
          parsedTimestamp(valueFor(profile, 'createdAt')) ||
          0,
      };
    })
    .filter(
      source => source.displayName || source.avatarUrl || source.fallbackLine
    );

  const sources = [contactRecordSource.value, ...profileSources].filter(
    Boolean
  );

  return sources.sort((left, right) => {
    const leftRank =
      Number(left.nameSelected) * 2 + Number(left.avatarSelected) * 2;
    const rightRank =
      Number(right.nameSelected) * 2 + Number(right.avatarSelected) * 2;

    if (leftRank !== rightRank) {
      return rightRank - leftRank;
    }

    if (left.sourcePriority !== right.sourcePriority) {
      return right.sourcePriority - left.sourcePriority;
    }

    return Number(right.sortTimestamp || 0) - Number(left.sortTimestamp || 0);
  });
});

const sourceCardClass = source => {
  if (source.nameSelected || source.avatarSelected) {
    return 'border-n-slate-5 bg-n-alpha-1 shadow-md';
  }

  return 'border-n-weak bg-white dark:bg-slate-900/40';
};

const sourceIconClass = source =>
  source.iconClass ||
  getContactSourceIconClass(source.nameSource || source.avatarSource || source);
</script>

<template>
  <section class="w-full rounded-3xl border border-n-weak bg-n-solid-1 p-3">
    <div v-if="normalizedSources.length" class="relative">
      <div
        v-if="normalizedSources.length > 1"
        class="pointer-events-none absolute inset-y-0 left-0 z-10 w-6 bg-gradient-to-r from-n-solid-1 to-transparent"
      />
      <div
        v-if="normalizedSources.length > 1"
        class="pointer-events-none absolute inset-y-0 right-0 z-10 w-10 bg-gradient-to-l from-n-solid-1 to-transparent"
      />

      <div
        class="flex gap-3 overflow-x-auto pb-1 scroll-smooth snap-x snap-mandatory no-scrollbar"
      >
        <article
          v-for="source in normalizedSources"
          :key="source.cardKey"
          data-source-card
          class="basis-[84%] shrink-0 snap-start rounded-2xl border p-2.5 shadow-sm transition-colors sm:basis-[72%] xl:basis-[68%]"
          :class="sourceCardClass(source)"
        >
          <div class="flex items-start gap-3">
            <Avatar
              :src="source.avatarUrl"
              :name="source.displayName || source.label"
              :size="32"
              rounded-full
            />

            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-start justify-between gap-2">
                <span
                  class="inline-flex max-w-full items-center gap-1 rounded-full bg-n-alpha-2 px-2 py-0.5 text-[11px] font-medium text-n-slate-11"
                >
                  <span
                    class="shrink-0 text-sm leading-none"
                    :class="sourceIconClass(source)"
                  />
                  <span class="truncate">
                    {{
                      source.label ||
                      $t('CONTACT_PANEL.SOURCE_IDENTITIES.UNKNOWN')
                    }}
                  </span>
                </span>

                <div class="flex flex-wrap justify-end gap-1">
                  <span
                    v-if="source.nameSelected"
                    class="inline-flex items-center rounded-full bg-emerald-50 px-2 py-0.5 text-[11px] font-medium text-emerald-700"
                  >
                    {{ $t('CONTACT_PANEL.SOURCE_IDENTITIES.NAME_IN_USE') }}
                  </span>
                  <span
                    v-if="source.avatarSelected"
                    class="inline-flex items-center rounded-full bg-blue-50 px-2 py-0.5 text-[11px] font-medium text-blue-700"
                  >
                    {{ $t('CONTACT_PANEL.SOURCE_IDENTITIES.PHOTO_IN_USE') }}
                  </span>
                </div>
              </div>

              <p class="mb-0 mt-2 truncate text-sm font-medium text-n-slate-12">
                {{
                  source.displayName ||
                  $t('CONTACT_PANEL.SOURCE_IDENTITIES.NO_NAME')
                }}
              </p>
              <p
                v-if="source.secondaryLine || source.fallbackLine"
                class="mb-0 mt-0.5 truncate text-xs text-n-slate-11"
              >
                {{ source.secondaryLine || source.fallbackLine }}
              </p>
            </div>
          </div>

          <div class="mt-3 flex flex-wrap gap-2">
            <NextButton
              icon="i-lucide-badge-check"
              slate
              sm
              :faded="!source.nameSelected"
              :disabled="
                isUpdating ||
                !source.nameSource ||
                !source.displayName ||
                source.nameSelected
              "
              :label="$t('CONTACT_PANEL.SOURCE_IDENTITIES.USE_NAME')"
              @click="emit('select-name-source', source)"
            />
            <NextButton
              icon="i-lucide-image-up"
              slate
              sm
              :faded="!source.avatarSelected"
              :disabled="
                isUpdating ||
                !source.avatarSource ||
                !source.avatarUrl ||
                source.avatarSelected
              "
              :label="$t('CONTACT_PANEL.SOURCE_IDENTITIES.USE_PHOTO')"
              @click="emit('select-avatar-source', source)"
            />
          </div>
        </article>
      </div>
    </div>

    <div
      v-else
      class="rounded-2xl border border-dashed border-n-weak px-4 py-5 text-sm text-n-slate-11"
    >
      {{ $t('CONTACT_PANEL.SOURCE_IDENTITIES.EMPTY') }}
    </div>
  </section>
</template>
