<script>
import rawEmojis from './emojisGroup.json';
import FluentIcon from 'shared/components/FluentIcon/Index.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import {
  getFrequentEmojiItems,
  recordEmojiUsage,
} from 'shared/helpers/emojiUsage';
import {
  enrichEmojiCategories,
  matchesEmojiSearch,
} from './emojiSearchKeywords';

const SEARCH_KEY = 'Search';
const FREQUENT_KEY = 'Frequent';
const ENRICHED_EMOJIS = enrichEmojiCategories(rawEmojis);
const FLAT_EMOJI_CATALOG = ENRICHED_EMOJIS.flatMap(c => c.emojis);

const CATEGORY_I18N_MAP = {
  smileys_emotion: 'EMOJI.CATEGORIES.SMILEYS_AND_EMOTION',
  people_body: 'EMOJI.CATEGORIES.PEOPLE_AND_BODY',
  animals_nature: 'EMOJI.CATEGORIES.ANIMALS_AND_NATURE',
  food_drink: 'EMOJI.CATEGORIES.FOOD_AND_DRINK',
  travel_places: 'EMOJI.CATEGORIES.TRAVEL_AND_PLACES',
  activities: 'EMOJI.CATEGORIES.ACTIVITIES',
  objects: 'EMOJI.CATEGORIES.OBJECTS',
  symbols: 'EMOJI.CATEGORIES.SYMBOLS',
  flags: 'EMOJI.CATEGORIES.FLAGS',
};

export default {
  components: { FluentIcon, NextButton },
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
      // Touch usageVersion so this recomputes after clicking an emoji
      // eslint-disable-next-line no-unused-expressions
      this.usageVersion;
      return getFrequentEmojiItems(FLAT_EMOJI_CATALOG, 16);
    },
    filterEmojisByCategory() {
      if (this.selectedKey === FREQUENT_KEY) {
        return this.frequentEmojis;
      }
      const selectedCategory = this.emojis.find(
        category => category.name === this.selectedKey
      );
      return selectedCategory?.emojis || [];
    },
    filterAllEmojisBySearch() {
      const trimmed = this.search.trim();
      return this.emojis.map(category => {
        const allEmojis = trimmed
          ? category.emojis.filter(emoji => matchesEmojiSearch(emoji, trimmed))
          : category.emojis;
        return allEmojis.length > 0
          ? { ...category, emojis: allEmojis }
          : { ...category, emojis: [] };
      });
    },
    hasNoSearch() {
      return this.selectedKey !== SEARCH_KEY && this.search === '';
    },
    showFrequentInAllView() {
      return (
        this.selectedKey === SEARCH_KEY &&
        this.search.trim() === '' &&
        this.frequentEmojis.length > 0
      );
    },
    hasEmptySearchResult() {
      return this.filterAllEmojisBySearch.every(
        category => category.emojis.length === 0
      );
    },
  },
  watch: {
    search() {
      this.selectedKey = SEARCH_KEY;
    },
    selectedKey() {
      return this.selectedKey === SEARCH_KEY ? this.focusSearchInput() : null;
    },
  },
  mounted() {
    this.focusSearchInput();
  },
  methods: {
    handleEmojiClick(emoji) {
      if (emoji) {
        recordEmojiUsage(emoji);
        this.usageVersion += 1;
      }
      this.onClick(emoji);
    },
    changeCategory(category) {
      this.search = '';
      if (this.$refs.emojiItem) {
        this.$refs.emojiItem.scrollTo({ top: 0 });
      }
      this.selectedKey = category;
    },
    getFirstEmojiByCategoryName(categoryName) {
      const categoryItem = this.emojis.find(
        category => category.name === categoryName
      );
      return categoryItem ? categoryItem.emojis[0].emoji : '';
    },
    getCategoryTitle(category) {
      if (!category) return '';
      if (typeof category === 'string') {
        if (category === FREQUENT_KEY) {
          return this.$t('EMOJI.FREQUENTLY_USED');
        }
        const found = this.emojis.find(c => c.name === category);
        if (!found) return category;
        return this.getCategoryTitle(found);
      }
      const key = CATEGORY_I18N_MAP[category.slug];
      if (key && this.$te && this.$te(key)) {
        return this.$t(key);
      }
      return category.name;
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
    class="emoji-dialog bg-n-background shadow-xl rounded-xl outline outline-1 outline-n-weak box-content h-[20rem] absolute right-0 -top-[95px] w-[21rem] z-20"
    :class="{ 'emoji-dialog--inline': inline }"
  >
    <div class="flex flex-col h-full justify-between">
      <div class="flex gap-2 m-2 sticky top-2">
        <input
          ref="searchbar"
          v-model="search"
          type="text"
          class="focus:box-shadow-blue dark:focus:box-shadow-dark !mb-0 !h-8 !text-sm !rounded-lg"
          :placeholder="$t('EMOJI.PLACEHOLDER')"
        />
        <NextButton
          v-if="showRemoveButton"
          faded
          sm
          slate
          class="flex-shrink-0"
          :label="$t('EMOJI.REMOVE')"
          @click="handleEmojiClick('')"
        />
      </div>
      <div v-if="hasNoSearch" ref="emojiItem" class="emoji-item">
        <h5
          class="text-xs text-n-slate-11 font-semibold tracking-wide uppercase leading-normal m-0 py-1.5 px-2.5"
        >
          {{ getCategoryTitle(selectedKey) }}
        </h5>
        <div class="emoji--row">
          <button
            v-for="item in filterEmojisByCategory"
            :key="item.slug || item.emoji"
            type="button"
            class="emoji--item emoji-font"
            :title="item.name"
            @click="handleEmojiClick(item.emoji)"
          >
            {{ item.emoji }}
          </button>
        </div>
      </div>
      <div v-else ref="emojiItem" class="emoji-item">
        <div v-if="showFrequentInAllView" class="mb-1">
          <h5
            class="text-xs text-n-slate-11 font-semibold tracking-wide uppercase leading-normal m-0 py-1.5 px-2.5 flex items-center gap-1"
          >
            {{ $t('EMOJI.FREQUENTLY_USED') }}
          </h5>
          <div class="emoji--row">
            <button
              v-for="item in frequentEmojis"
              :key="`freq-${item.emoji}`"
              type="button"
              class="emoji--item emoji-font"
              :title="item.name"
              @click="handleEmojiClick(item.emoji)"
            >
              {{ item.emoji }}
            </button>
          </div>
        </div>
        <div v-for="category in filterAllEmojisBySearch" :key="category.slug">
          <h5
            v-if="category.emojis.length > 0"
            class="text-xs text-n-slate-11 font-semibold tracking-wide uppercase leading-normal m-0 py-1.5 px-2.5"
          >
            {{ getCategoryTitle(category) }}
          </h5>
          <div v-if="category.emojis.length > 0" class="emoji--row">
            <button
              v-for="item in category.emojis"
              :key="item.slug || item.emoji"
              type="button"
              class="emoji--item emoji-font"
              :title="item.name"
              @click="handleEmojiClick(item.emoji)"
            >
              {{ item.emoji }}
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
          <span class="text-n-slate-11 text-sm font-medium">
            {{ $t('EMOJI.NOT_FOUND') }}
          </span>
        </div>
      </div>

      <div
        class="emoji-dialog--footer relative w-full py-0 rounded-b-xl px-1 bg-n-slate-3"
        role="menu"
      >
        <ul
          class="flex relative left-[2px] rtl:left-[unset] rtl:right-[2px] list-none m-0 overflow-x-auto py-1 px-0 items-center"
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
              <FluentIcon icon="clock" size="16" class="text-n-slate-11" />
            </button>
          </li>
          <li
            v-for="category in categories"
            :key="category.slug"
            @click="changeCategory(category.name)"
          >
            <button
              type="button"
              class="emoji--item emoji-font"
              :title="getCategoryTitle(category)"
              :class="{ active: selectedKey === category.name }"
              @click="changeCategory(category.name)"
            >
              {{ getFirstEmojiByCategoryName(category.name) }}
            </button>
          </li>
        </ul>
      </div>
    </div>
  </div>
</template>

<style scoped>
@tailwind components;

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
