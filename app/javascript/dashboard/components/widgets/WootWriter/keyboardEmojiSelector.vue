<script setup>
import { shallowRef, computed, onMounted } from 'vue';
import emojiGroups from 'shared/components/emoji/emojisGroup.json';
import AppleEmoji from 'shared/components/emoji/AppleEmoji.vue';
import {
  enrichEmojiCategories,
  matchesEmojiSearch,
} from 'shared/components/emoji/emojiSearchKeywords';
import {
  getSortedStoredEmojis,
  FREQUENT_EMOJIS_STORAGE_KEY,
  recordEmojiUsage,
} from 'shared/helpers/emojiUsage';
import MentionBox from '../mentions/MentionBox.vue';

const props = defineProps({
  searchKey: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['selectEmoji']);

const allEmojis = shallowRef([]);

const items = computed(() => {
  if (!props.searchKey) return [];
  const searchTerm = props.searchKey.toLowerCase().trim();
  const frequentList = getSortedStoredEmojis(FREQUENT_EMOJIS_STORAGE_KEY);
  const frequentRank = new Map(frequentList.map((e, idx) => [e, idx]));

  const filtered = allEmojis.value.filter(
    emoji =>
      emoji.searchString.includes(searchTerm) ||
      matchesEmojiSearch(emoji, searchTerm)
  );

  return filtered.sort((a, b) => {
    const rankA = frequentRank.has(a.emoji) ? frequentRank.get(a.emoji) : 9999;
    const rankB = frequentRank.has(b.emoji) ? frequentRank.get(b.emoji) : 9999;
    return rankA - rankB;
  });
});

function loadEmojis() {
  const enriched = enrichEmojiCategories(emojiGroups);
  allEmojis.value = enriched.flatMap(({ emojis }) =>
    emojis.map(({ name, slug, searchText, ...rest }) => ({
      ...rest,
      name,
      slug,
      searchText,
      searchString: `${name.replace(/\s+/g, '')} ${slug} ${searchText || ''}`.toLowerCase(),
    }))
  );
}

function handleMentionClick(item = {}) {
  if (item.emoji) {
    recordEmojiUsage(item.emoji);
  }
  emit('selectEmoji', item.emoji);
}

onMounted(() => {
  loadEmojis();
});
</script>

<!-- eslint-disable-next-line vue/no-root-v-if -->
<template>
  <MentionBox
    v-if="items.length"
    type="emoji"
    :items="items"
    @mention-select="handleMentionClick"
  >
    <template #default="{ item, selected }">
      <span
        class="max-w-full inline-flex items-center gap-1.5 min-w-0 mb-0 text-sm font-medium text-n-slate-12 group-hover:text-n-brand truncate"
      >
        <AppleEmoji :emoji="item.emoji" size-class="size-4" />
        <p
          class="relative mb-0 truncate bottom-px"
          :class="{
            'text-n-brand': selected,
            'font-normal': !selected,
          }"
        >
          :{{ item.name }}
        </p>
      </span>
    </template>
  </MentionBox>
</template>
