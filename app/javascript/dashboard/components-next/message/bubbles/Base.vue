<script setup>
import { computed } from 'vue';

import MessageMeta from '../MessageMeta.vue';
import MessageReactions from '../MessageReactions.vue';

import { emitter } from 'shared/helpers/mitt';
import { useMessageContext } from '../provider.js';
import { useI18n } from 'vue-i18n';

import MessageFormatter from 'shared/helpers/MessageFormatter.js';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { MESSAGE_VARIANTS, ORIENTATION } from '../constants';

const props = defineProps({
  hideMeta: { type: Boolean, default: false },
});

const {
  variant,
  orientation,
  inReplyTo,
  shouldGroupWithNext,
  contentAttributes,
} = useMessageContext();
const { t } = useI18n();

const groupSender = computed(
  () =>
    contentAttributes?.value?.groupSender ||
    contentAttributes?.value?.group_sender ||
    null
);

const shouldShowGroupSender = computed(
  () =>
    orientation.value === ORIENTATION.LEFT &&
    variant.value === MESSAGE_VARIANTS.USER &&
    Boolean(groupSender.value?.name)
);

const groupSenderHandle = computed(() => {
  const username = groupSender.value?.username;
  if (username) {
    return username.startsWith('@') ? username : `@${username}`;
  }
  const phone =
    groupSender.value?.phoneNumber || groupSender.value?.phone_number;
  if (phone && phone !== groupSender.value?.name) {
    return phone;
  }
  return '';
});

const GROUP_SENDER_COLOR_CLASSES = [
  'text-n-teal-11',
  'text-n-blue-11',
  'text-n-iris-11',
  'text-n-amber-11',
  'text-n-ruby-11',
];

const groupSenderColorClass = computed(() => {
  const seed = String(groupSender.value?.id || groupSender.value?.name || '');
  let hash = 0;
  for (let i = 0; i < seed.length; i += 1) {
    hash = (hash * 31 + seed.charCodeAt(i)) % 997;
  }
  return GROUP_SENDER_COLOR_CLASSES[
    Math.abs(hash) % GROUP_SENDER_COLOR_CLASSES.length
  ];
});

const varaintBaseMap = {
  [MESSAGE_VARIANTS.AGENT]: 'bg-n-blue-2 dark:bg-n-blue-1 text-n-slate-12',
  [MESSAGE_VARIANTS.PRIVATE]:
    'bg-n-solid-amber text-n-amber-12 [&_.prosemirror-mention-node]:font-semibold',
  [MESSAGE_VARIANTS.USER]: 'bg-n-alpha-1 text-n-slate-12',
  [MESSAGE_VARIANTS.ACTIVITY]: 'bg-transparent text-n-slate-11 text-sm',
  [MESSAGE_VARIANTS.BOT]: 'bg-n-solid-iris text-n-slate-12',
  [MESSAGE_VARIANTS.TEMPLATE]: 'bg-n-solid-iris text-n-slate-12',
  [MESSAGE_VARIANTS.ERROR]: 'bg-n-ruby-4 text-n-ruby-12',
  [MESSAGE_VARIANTS.EMAIL]: 'w-full',
  [MESSAGE_VARIANTS.UNSUPPORTED]:
    'bg-n-solid-amber/70 border border-dashed border-n-amber-10 text-n-amber-12',
};

const orientationMap = {
  [ORIENTATION.LEFT]:
    'left-bubble rounded-xl ltr:rounded-bl-sm rtl:rounded-br-sm',
  [ORIENTATION.RIGHT]:
    'right-bubble rounded-xl ltr:rounded-br-sm rtl:rounded-bl-sm',
  [ORIENTATION.CENTER]: 'rounded-md',
};

const flexOrientationClass = computed(() => {
  const map = {
    [ORIENTATION.LEFT]: 'justify-start',
    [ORIENTATION.RIGHT]: 'justify-end',
    [ORIENTATION.CENTER]: 'justify-center',
  };

  return map[orientation.value];
});

const messageClass = computed(() => {
  const classToApply = [varaintBaseMap[variant.value]];

  if (variant.value !== MESSAGE_VARIANTS.ACTIVITY) {
    classToApply.push(orientationMap[orientation.value]);
  } else {
    classToApply.push('rounded-lg');
  }

  return classToApply;
});

const scrollToMessage = () => {
  emitter.emit(BUS_EVENTS.SCROLL_TO_MESSAGE, {
    messageId: inReplyTo.value.id,
  });
};

const shouldShowMeta = computed(
  () =>
    !props.hideMeta &&
    !shouldGroupWithNext.value &&
    variant.value !== MESSAGE_VARIANTS.ACTIVITY
);

const shouldShowReactions = computed(
  () => variant.value !== MESSAGE_VARIANTS.ACTIVITY
);

const replyToPreview = computed(() => {
  if (!inReplyTo) return '';

  const { content, attachments } = inReplyTo.value;

  if (content) return new MessageFormatter(content).formattedMessage;
  if (attachments?.length) {
    const firstAttachment = attachments[0];
    const fileType = firstAttachment.fileType ?? firstAttachment.file_type;

    return t(`CHAT_LIST.ATTACHMENTS.${fileType}.CONTENT`);
  }

  return t('CONVERSATION.REPLY_MESSAGE_NOT_FOUND');
});
</script>

<template>
  <div
    class="text-sm min-w-0 max-w-full"
    :class="[
      messageClass,
      {
        'max-w-lg': variant !== MESSAGE_VARIANTS.EMAIL,
      },
    ]"
  >
    <div
      v-if="shouldShowGroupSender"
      data-testid="group-sender-header"
      class="mb-1 flex items-baseline gap-1.5 text-xs leading-4"
    >
      <span class="truncate font-semibold" :class="groupSenderColorClass">
        {{ groupSender.name }}
      </span>
      <span
        v-if="groupSenderHandle"
        class="shrink-0 text-[11px] font-normal text-n-slate-10"
      >
        {{ groupSenderHandle }}
      </span>
    </div>
    <div
      v-if="inReplyTo"
      class="p-2 -mx-1 mb-2 rounded-lg cursor-pointer bg-n-alpha-black1"
      @click="scrollToMessage"
    >
      <div
        v-dompurify-html="replyToPreview"
        class="prose prose-bubble line-clamp-2"
      />
    </div>
    <slot />
    <div
      v-if="shouldShowReactions || shouldShowMeta"
      class="flex flex-wrap items-center justify-between gap-x-2 gap-y-1 mt-1.5 [&:not(:has(*))]:hidden"
      :class="[
        flexOrientationClass,
        variant === MESSAGE_VARIANTS.EMAIL ? 'px-3 pb-3' : '',
      ]"
    >
      <MessageReactions v-if="shouldShowReactions" />
      <MessageMeta
        v-if="shouldShowMeta"
        :class="[
          orientation === ORIENTATION.RIGHT ? 'ltr:ml-auto rtl:mr-auto' : '',
          variant === MESSAGE_VARIANTS.PRIVATE
            ? 'text-n-amber-12/50'
            : 'text-n-slate-11',
        ]"
      />
    </div>
  </div>
</template>
