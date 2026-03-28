<script setup>
import { computed, ref } from 'vue';
import { useRouter } from 'vue-router';
import { useI18n } from 'vue-i18n';
import EmptyStateLayout from 'dashboard/components-next/EmptyStateLayout.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import ArticleCard from 'dashboard/components-next/HelpCenter/ArticleCard/ArticleCard.vue';
import portalEmptyStateContent from './portalEmptyStateContent';
import CreatePortalDialog from 'dashboard/components-next/HelpCenter/PortalSwitcher/CreatePortalDialog.vue';

const createPortalDialogRef = ref(null);
const openDialog = () => {
  createPortalDialogRef.value.dialogRef.open();
};

const router = useRouter();
const { t } = useI18n();

const articleContent = computed(() =>
  portalEmptyStateContent.map(article => ({
    ...article,
    title: t(article.titleKey),
    author: {
      ...article.author,
      name: t(article.author.nameKey),
    },
    category: {
      ...article.category,
      name: t(article.category.nameKey),
    },
  }))
);

const reversedArticleContent = computed(() =>
  [...articleContent.value].reverse()
);

const onPortalCreate = ({ slug: portalSlug, locale }) => {
  router.push({
    name: 'portals_articles_index',
    params: { portalSlug, locale },
  });
};
</script>

<template>
  <EmptyStateLayout
    :title="$t('HELP_CENTER.TITLE')"
    :subtitle="$t('HELP_CENTER.NEW_PAGE.DESCRIPTION')"
    class="bg-n-surface-1"
  >
    <template #empty-state-item>
      <div class="grid grid-cols-2 gap-4 p-px">
        <div class="space-y-4">
          <ArticleCard
            v-for="(article, index) in articleContent"
            :id="article.id"
            :key="`article-${index}`"
            :title="article.title"
            :status="article.status"
            :updated-at="article.updatedAt"
            :author="article.author"
            :category="article.category"
            :views="article.views"
          />
        </div>
        <div class="space-y-4">
          <ArticleCard
            v-for="(article, index) in reversedArticleContent"
            :id="article.id"
            :key="`article-${index}`"
            :title="article.title"
            :status="article.status"
            :updated-at="article.updatedAt"
            :author="article.author"
            :category="article.category"
            :views="article.views"
          />
        </div>
      </div>
    </template>
    <template #actions>
      <Button
        :label="$t('HELP_CENTER.NEW_PAGE.CREATE_PORTAL_BUTTON')"
        icon="i-lucide-plus"
        @click="openDialog"
      />
      <CreatePortalDialog
        ref="createPortalDialogRef"
        @create="onPortalCreate"
      />
    </template>
  </EmptyStateLayout>
</template>
