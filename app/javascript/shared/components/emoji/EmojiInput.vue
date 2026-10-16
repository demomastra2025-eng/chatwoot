<script>
import rawEmojis from './emojisGroup.json';
import FluentIcon from 'shared/components/FluentIcon/Index.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import AppleEmoji from './AppleEmoji.vue';
import {
  getFrequentEmojiItems,
  recordEmojiUsage,
} from 'shared/helpers/emojiUsage';
import {
  enrichEmojiCategories,
  matchesEmojiSearch,
  getCategoryLabelKey,
} from './emojiSearchKeywords';

const SEARCH_KEY = 'Search';
const FREQUENT_KEY = 'Frequent';
const ENRICHED_EMOJIS = enrichEmojiCategories(rawEmojis);
const FLAT_EMOJI_CATALOG = ENRICHED_EMOJIS.flatMap(c => c.emojis);

export default {
  components: { FluentIcon, NextButton, AppleEmoji },
  props: {
    onClick: {
      type: Function,
      default: () => {},
    },
    showRemoveButton: {
      type: Boolean,
      default: false,
    },
    inline: {
      type: Boolean,
      default: false,
    },
  },
  data() {
    return {
      selectedKey: SEARCH_KEY,
      emojis: ENRICHED_EMOJIS,
      search: '',
      usageVersion: 0,
    };
  },
  computed: {
    categories() {
      return [...this.emojis];
    },
    frequentEmojis() {
      // eslint-disable-next-line no-unused-expressions
      this.usageVersion;
      return getFrequentEmojiItems(FLAT_EMOJI_CATALOG, 16);
    },
    filterEmojisByCategory() {
      if (this.selectedKey === FREQUENT_KEY) {
        return this.frequentEmojis;
      }
      const selectedCategoryName = this.emojis.find(category =>
        category.name === this.selectedKey ? category.name : null
      );
      return selectedCategoryName?.emojis || [];
    },
    filterAllEmojisBySearch() {
      const query = this.search.trim();
      return this.emojis
        .map(category => {
          const allEmojis = query
            ? category.emojis.filter(emoji => matchesEmojiSearch(emoji, query))
            : category.emojis;
          return allEmojis.length > 0
            ? { ...category, emojis: allEmojis }
            : null;
        })
        .filter(Boolean);
    },
    hasNoSearch() {
      return this.selectedKey !== SEARCH_KEY && this.search === '';
    },
    hasEmptySearchResult() {
      return this.filterAllEmojisBySearch.every(
        category => category.emojis.length === 0
      );
    },
  },
  mounted() {
    this.focusSearchInput();
  },
  methods: {
    changeCategory(category) {
      this.search = '';
      this.$refs.emojiItem.scrollTop = 0;
      this.selectedKey = category;
    },
    getFirstEmojiByCategoryName(categoryName) {
      const categoryItem = this.emojis.find(category =>
        category.name === categoryName ? category : null
      );
      return categoryItem ? categoryItem.emojis[0].emoji : '';
    },
    categoryTitle(category) {
      if (!category) return '';
      if (category === FREQUENT_KEY) {
        return this.$t('EMOJI.FREQUENTLY_USED');
      }
      const i18nKey = getCategoryLabelKey(category.slug);
      if (i18nKey && this.$te(i18nKey)) {
        return this.$t(i18nKey);
      }
      return category.name;
    },
    selectedCategoryTitle() {
      if (this.selectedKey === FREQUENT_KEY) {
        return this.$t('EMOJI.FREQUENTLY_USED');
      }
      const cat = this.emojis.find(c => c.name === this.selectedKey);
      return this.categoryTitle(cat);
    },
    handleClick(emoji) {
      recordEmojiUsage(emoji);
      this.usageVersion += 1;
      this.onClick(emoji);
    },
    focusSearchInput() {
      this.$nextTick(() => {
        this.$refs.searchbar?.focus();
      });
    },
  },
};
</script>

<template>
  <div
    role="dialog"
    class="emoji-dialog bg-n-background shadow-lg rounded-md border border-n-weak box-content p-2 right-0 -top-96 h-[20.5rem] w-80 absolute z-20"
    :class="{ 'emoji-dialog--inline': inline }"
  >
    <div class="flex flex-col">
      <div class="flex gap-1 m-1">
        <input
          ref="searchbar"
          v-model="search"
          type="text"
          class="focus:box-shadow-blue dark:focus:box-shadow-dark !mb-0 !h-8 !text-sm w-full bg-n-alpha-black2 dark:bg-n-solid-1 rounded-lg px-2.5 text-n-slate-12 border-0"
          :placeholder="$t('EMOJI.PLACEHOLDER')"
        />
        <NextButton
          v-if="showRemoveButton"
          faded
          sm
          slate
           class="flex-shrink-0"
          :label="$t('EMOJI.REMOVE')"
          @click="onClick('')"
        />
      </div>
      <div v-if="hasNoSearch" ref="emojiItem" class="emoji-item">
        <h5
          class="text-xs text-n-slate-11 font-medium leading-normal m-0 py-1 px-2 capitalize"
        >
          {{ selectedCategoryTitle() }}
        </h5>
        <div class="emoji--row">
          <button
            v-for="item in filterEmojisByCategory"
            :key="item.slug"
            type="button"
            class="emoji--item"
            track-by="$index"
            :title="item.name"
            @click="handleClick(item.emoji)"
          >
            <AppleEmoji :emoji="item.emoji" size-class="size-[22px]" />
          </button>
        </div>
      </div>
      <div v-else ref="emojiItem" class="emoji-item">
        <div v-if="search === '' && frequentEmojis.length > 0">
          <h5
            class="text-xs text-n-slate-11 font-medium leading-normal m-0 py-1 px-2"
          >
            {{ $t('EMOJI.FREQUENTLY_USED') }}
          </h5>
          <div class="emoji--row">
            <button
              v-for="item in frequentEmojis"
              :key="`freq-${item.slug || item.emoji}`"
              type="button"
              class="emoji--item"
              :title="item.name"
              @click="handleClick(item.emoji)"
            >
              <AppleEmoji :emoji="item.emoji" size-class="size-[22px]" />
            </button>
          </div>
        </div>
        <div v-for="category in filterAllEmojisBySearch" :key="category.slug">
          <h5
            v-if="category.emojis.length > 0"
            class="text-xs text-n-slate-11 font-medium leading-normal m-0 py-1 px-2 capitalize"
          >
            {{ categoryTitle(category) }}
          </h5>
          <div v-if="category.emojis.length > 0" class="emoji--row">
            <button
              v-for="item in category.emojis"
              :key="item.slug"
              type="button"
              class="emoji--item"
              track-by="$index"
              :title="item.name"
              @click="handleClick(item.emoji)"
            >
              <AppleEmoji :emoji="item.emoji" size-class="size-[22px]" />
            </button>
          </div>
        </div>
        <div
          v-if="hasEmptySearchResult"
          class="items-center flex flex-col h-[13.25rem] justify-center"
        >
          <div class="text-n-slate-11 mb-2">
            <FluentIcon icon="emoji" size="48" />
          </div>
          <span class="text-n-slate-11 text-sm font-medium text-center">
            {{ $t('EMOJI.NOT_FOUND') }}
          </span>
        </div>
      </div>

      <nav
        class="emoji-dialog--footer relative w-[calc(100%+1rem)] py-1 -bottom-2 -left-2 bg-n-slate-3 rounded-b-md"
        role="navigation"
      >
        <ul
          class="flex relative left-[2px] list-none m-0 overflow-auto py-1 px-0"
        >
          <li>
            <button
              type="button"
              class="emoji--item"
              :class="{ active: selectedKey === 'Search' }"
              @click="changeCategory('Search')"
            >
              <FluentIcon icon="search" size="16" class="text-n-slate-11" />
            </button>
          </li>
          <li>
            <button
              type="button"
              class="emoji--item"
              :title="$t('EMOJI.FREQUENTLY_USED')"
              :class="{ active: selectedKey === 'Frequent' }"
              @click="changeCategory('Frequent')"
            >
              <span class="i-lucide-clock-3 size-4 text-n-slate-11" />
            </button>
          </li>
          <li
            v-for="category in categories"
            :key="category.slug"
            @click="changeCategory(category.name)"
          >
            <button
              type="button"
              class="emoji--item"
              :title="categoryTitle(category)"
              :class="{ active: selectedKey === category.name }"
              @click="changeCategory(category.name)"
            >
              <AppleEmoji
                :emoji="getFirstEmojiByCategoryName(category.name)"
                size-class="size-4"
              />
            </button>
          </li>
        </ul>
      </nav>
    </div>
  </div>
</template>

<style scoped>
@tailwind base;
@tailwind components;
@tailwind utilities;

@layer components {
  .box-shadow-blue {
    box-shadow:
      0 0 0 1px #1f93ff,
      0 0 1px 2px #c7e3ff;
  }

  .box-shadow-dark {
    box-shadow:
      0 0 0 1px #212222,
      0 0 1px 2px #4c5155;
  }
}
</style>

<style lang="scss">
.emoji-font {
  font-family:
    'Apple Color Emoji', 'Segoe UI Emoji', 'Segoe UI Symbol',
    'Noto Color Emoji', sans-serif;
}

.emoji-dialog {
  &::before {
    @apply absolute -bottom-3 h-3 w-6 bg-n-slate-3 content-[""];
    clip-path: polygon(50% 100%, 0% 0%, 100% 0%);
  }

  &.emoji-dialog--inline {
    @apply static right-auto top-auto z-auto box-border h-auto w-full rounded-xl shadow-none;

    &::before {
      @apply hidden;
    }

    .emoji-item {
      @apply h-48;
    }
  }
}

.emoji--item {
  @apply bg-transparent border-0 rounded-lg cursor-pointer text-lg h-7 w-7 m-0 p-0 inline-flex items-center justify-center hover:bg-n-slate-4 transition-transform duration-150 select-none;
}

.emoji--row {
  @apply box-border px-1.5 py-0.5 flex flex-wrap;

  .emoji--item {
    @apply h-8 w-8 text-[1.35rem] leading-none m-0.5 hover:scale-125;
  }
}

.emoji-item {
  @apply h-[14.25rem] overflow-y-auto;
}

.emoji-dialog--footer {
  ul {
    > li {
      @apply items-center cursor-pointer flex justify-center p-0.5;
    }

    li .active {
      @apply bg-n-background shadow-sm;
    }

    .emoji--item {
      @apply flex items-center text-sm hover:bg-n-slate-2;
    }
  }
}
</style>
