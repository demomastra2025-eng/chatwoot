<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Avatar from 'next/avatar/Avatar.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import {
  displayableIdentityDetail,
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
  onlyActionable: {
    type: Boolean,
    default: false,
  },
  hideEmptyState: {
    type: Boolean,
    default: false,
  },
  showMessageAction: {
    type: Boolean,
    default: false,
  },
  showIdentifiers: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits([
  'select-name-source',
  'select-avatar-source',
  'open-channel-conversation',
]);

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

const rawContactInboxes = computed(
  () => props.contact.contactInboxes || props.contact.contact_inboxes || []
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
    secondaryLine: displayableIdentityDetail(email, phoneNumber),
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
  const profiledContactInboxIds = new Set(
    rawProfiles.value
      .map(profile => valueFor(profile, 'contactInboxId'))
      .filter(Boolean)
      .map(String)
  );

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
        secondaryLine: displayableIdentityDetail(username, phoneNumber),
        identifierLine: displayableIdentityDetail(
          sourceId,
          valueFor(profile, 'identifier')
        ),
        nameSource: displayName ? channelSource : null,
        avatarSource: avatarUrl ? channelSource : null,
        channelIdentity: valueFor(profile, 'inboxId')
          ? {
              inboxId: valueFor(profile, 'inboxId'),
              sourceId,
            }
          : null,
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
      source =>
        source.displayName ||
        source.avatarUrl ||
        source.identifierLine ||
        source.channelIdentity
    );

  const inboxSources = rawContactInboxes.value
    .filter(
      contactInbox =>
        !profiledContactInboxIds.has(String(valueFor(contactInbox, 'id')))
    )
    .map(contactInbox => {
      const inbox = valueFor(contactInbox, 'inbox') || {};
      const inboxId = valueFor(contactInbox, 'inboxId');
      const sourceId = valueFor(contactInbox, 'sourceId');
      const provider =
        valueFor(inbox, 'provider') || valueFor(inbox, 'channelType');
      const channelSource = {
        kind: 'channel_profile',
        contactInboxId: valueFor(contactInbox, 'id'),
        inboxId,
        channelType: valueFor(inbox, 'channelType'),
        provider,
        sourceId,
      };

      return {
        id: `contact-inbox:${valueFor(contactInbox, 'id') || sourceId}`,
        cardKey: `contact-inbox:${valueFor(contactInbox, 'id') || sourceId}`,
        displayName: valueFor(inbox, 'name') || humanizeSource(provider),
        avatarUrl: valueFor(inbox, 'avatarUrl') || '',
        label: humanizeSource(provider),
        iconClass: getContactSourceIconClass(channelSource),
        secondaryLine: '',
        identifierLine: displayableIdentityDetail(sourceId),
        nameSource: null,
        avatarSource: null,
        channelIdentity: inboxId
          ? {
              inboxId,
              sourceId,
            }
          : null,
        nameSelected: false,
        avatarSelected: false,
        sourcePriority: -1,
        sortTimestamp: 0,
      };
    })
    .filter(source => source.identifierLine || source.channelIdentity);

  const sources = [
    contactRecordSource.value,
    ...profileSources,
    ...inboxSources,
  ].filter(Boolean);

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

const canUseName = source =>
  Boolean(source.nameSource && source.displayName && !source.nameSelected);

const canUsePhoto = source =>
  Boolean(source.avatarSource && source.avatarUrl && !source.avatarSelected);

const canMessage = source =>
  Boolean(
    props.showMessageAction &&
      source.channelIdentity &&
      source.channelIdentity.inboxId
  );

const visibleSources = computed(() => {
  if (!props.onlyActionable) {
    return normalizedSources.value;
  }

  return normalizedSources.value.filter(
    source => canUseName(source) || canUsePhoto(source) || canMessage(source)
  );
});

const displayIdentifier = source => {
  if (!props.showIdentifiers) {
    return '';
  }

  const value = source.identifierLine || '';
  return value && value !== source.secondaryLine ? value : '';
};

const isSourceSelected = source =>
  Boolean(source.nameSelected || source.avatarSelected);

const sourceIconClass = source =>
  source.iconClass ||
  getContactSourceIconClass(source.nameSource || source.avatarSource || source);
</script>

<template>
  <section class="w-full">
    <div
      v-if="visibleSources.length"
      class="flex flex-col divide-y divide-n-weak"
    >
      <article
        v-for="source in visibleSources"
        :key="source.cardKey"
        data-source-card
        class="flex flex-col gap-3 py-3 first:pt-0 last:pb-0"
      >
        <div class="flex min-w-0 items-start gap-3">
          <Avatar
            :src="source.avatarUrl"
            :name="source.displayName || source.label"
            :size="32"
            rounded-full
          />

          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-center gap-2">
              <span
                class="inline-flex max-w-full items-center gap-1 rounded-full border border-n-weak bg-n-alpha-1 px-2 py-0.5 text-[11px] font-medium text-n-slate-11"
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
              <span
                v-if="isSourceSelected(source)"
                class="i-lucide-badge-check size-4 shrink-0 text-n-brand"
                aria-hidden="true"
              />
            </div>

            <div class="mt-2 flex items-center gap-2">
              <p
                class="mb-0 min-w-0 flex-1 truncate text-sm font-medium"
                :class="
                  isSourceSelected(source) ? 'text-n-brand' : 'text-n-slate-12'
                "
              >
                {{
                  source.displayName ||
                  source.label ||
                  $t('CONTACT_PANEL.SOURCE_IDENTITIES.NO_NAME')
                }}
              </p>
              <span
                v-if="displayIdentifier(source)"
                class="inline-flex max-w-[52%] shrink-0 items-center gap-1 rounded-full border border-n-weak bg-n-alpha-1 px-2 py-0.5 text-[11px] text-n-slate-11"
              >
                <span class="i-lucide-id-card size-3 shrink-0" />
                <span class="truncate">{{ displayIdentifier(source) }}</span>
              </span>
            </div>
            <p
              v-if="source.secondaryLine"
              class="mb-0 mt-0.5 truncate text-xs text-n-slate-11"
            >
              {{ source.secondaryLine }}
            </p>
          </div>
        </div>

        <div
          v-if="canUseName(source) || canUsePhoto(source) || canMessage(source)"
          class="flex flex-wrap gap-2 pl-11"
        >
          <NextButton
            v-if="canUseName(source)"
            icon="i-lucide-badge-check"
            slate
            sm
            :faded="!source.nameSelected"
            :disabled="isUpdating"
            :label="$t('CONTACT_PANEL.SOURCE_IDENTITIES.USE_NAME')"
            @click="emit('select-name-source', source)"
          />
          <NextButton
            v-if="canUsePhoto(source)"
            icon="i-lucide-image-up"
            slate
            sm
            :faded="!source.avatarSelected"
            :disabled="isUpdating"
            :label="$t('CONTACT_PANEL.SOURCE_IDENTITIES.USE_PHOTO')"
            @click="emit('select-avatar-source', source)"
          />
          <NextButton
            v-if="canMessage(source)"
            icon="i-ph-chat-circle-dots"
            slate
            sm
            :disabled="isUpdating"
            :label="$t('CONTACT_PANEL.NEW_MESSAGE')"
            @click="emit('open-channel-conversation', source.channelIdentity)"
          />
        </div>
      </article>
    </div>

    <p v-else-if="!hideEmptyState" class="mb-0 text-sm text-n-slate-11">
      {{ $t('CONTACT_PANEL.SOURCE_IDENTITIES.EMPTY') }}
    </p>
  </section>
</template>
