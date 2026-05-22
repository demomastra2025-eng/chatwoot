import { defineStore } from 'pinia';
import camelcaseKeys from 'camelcase-keys';
import ContentConnectionAPI from 'dashboard/api/content/connection';
import ContentChannelsAPI from 'dashboard/api/content/channels';
import ContentPostsAPI from 'dashboard/api/content/posts';
import ContentMediaAPI from 'dashboard/api/content/media';
import ContentAnalyticsAPI from 'dashboard/api/content/analytics';

const normalizePayload = response =>
  camelcaseKeys(response?.data?.payload ?? response?.data ?? {}, {
    deep: true,
  });

const normalizeListPayload = response => {
  const payload = normalizePayload(response);
  if (Array.isArray(payload)) return payload;
  if (Array.isArray(payload?.data)) return payload.data;
  if (Array.isArray(payload?.integrations)) return payload.integrations;
  if (Array.isArray(payload?.posts)) return payload.posts;
  return [];
};

const extractError = error =>
  error?.response?.data?.error ||
  error?.response?.data?.message ||
  error?.message;

export const useContentStore = defineStore('content', {
  state: () => ({
    connection: null,
    channels: [],
    posts: [],
    ui: {
      isLoadingConnection: false,
      isLoadingChannels: false,
      isLoadingPosts: false,
      isMutatingPost: false,
      isUploadingMedia: false,
      isLoadingAnalytics: false,
      error: null,
    },
  }),

  getters: {
    isConnected: state => Boolean(state.connection?.connected),
    enabledChannels: state =>
      state.channels.filter(channel => channel?.disabled !== true),
  },

  actions: {
    setError(error) {
      this.ui.error = extractError(error);
    },

    async fetchConnection() {
      this.ui.isLoadingConnection = true;
      this.ui.error = null;
      try {
        const response = await ContentConnectionAPI.get();
        this.connection = normalizePayload(response);
        return this.connection;
      } catch (error) {
        this.setError(error);
        throw error;
      } finally {
        this.ui.isLoadingConnection = false;
      }
    },

    async saveConnection(payload) {
      this.ui.isLoadingConnection = true;
      this.ui.error = null;
      try {
        const response = await ContentConnectionAPI.update(payload);
        this.connection = normalizePayload(response);
        return this.connection;
      } catch (error) {
        this.setError(error);
        throw error;
      } finally {
        this.ui.isLoadingConnection = false;
      }
    },

    async testConnection() {
      const response = await ContentConnectionAPI.test();
      return normalizePayload(response);
    },

    async fetchChannels() {
      this.ui.isLoadingChannels = true;
      this.ui.error = null;
      try {
        const response = await ContentChannelsAPI.get();
        this.channels = normalizeListPayload(response);
        return this.channels;
      } catch (error) {
        this.setError(error);
        throw error;
      } finally {
        this.ui.isLoadingChannels = false;
      }
    },

    async openOAuth(provider, refresh) {
      const response = await ContentChannelsAPI.oauthUrl({ provider, refresh });
      const payload = normalizePayload(response);
      const url = payload?.url || payload?.data?.url;
      if (url) window.open(url, '_blank', 'noopener,noreferrer');
      return payload;
    },

    async deleteChannel(id) {
      const response = await ContentChannelsAPI.delete(id);
      this.channels = this.channels.filter(channel => channel.id !== id);
      return normalizePayload(response);
    },

    async findChannelSlot(id) {
      const response = await ContentChannelsAPI.findSlot(id);
      return normalizePayload(response);
    },

    async fetchPosts(params) {
      this.ui.isLoadingPosts = true;
      this.ui.error = null;
      try {
        const response = await ContentPostsAPI.get(params);
        this.posts = normalizeListPayload(response);
        return this.posts;
      } catch (error) {
        this.setError(error);
        throw error;
      } finally {
        this.ui.isLoadingPosts = false;
      }
    },

    async createPost(payload) {
      this.ui.isMutatingPost = true;
      this.ui.error = null;
      try {
        const response = await ContentPostsAPI.create(payload);
        return normalizePayload(response);
      } catch (error) {
        this.setError(error);
        throw error;
      } finally {
        this.ui.isMutatingPost = false;
      }
    },

    async deletePost(id) {
      this.ui.isMutatingPost = true;
      this.ui.error = null;
      try {
        const response = await ContentPostsAPI.delete(id);
        this.posts = this.posts.filter(post => post.id !== id);
        return normalizePayload(response);
      } catch (error) {
        this.setError(error);
        throw error;
      } finally {
        this.ui.isMutatingPost = false;
      }
    },

    async updatePostStatus(id, status) {
      this.ui.isMutatingPost = true;
      this.ui.error = null;
      try {
        const response = await ContentPostsAPI.updateStatus(id, status);
        return normalizePayload(response);
      } catch (error) {
        this.setError(error);
        throw error;
      } finally {
        this.ui.isMutatingPost = false;
      }
    },

    async checkPostMissing(id) {
      const response = await ContentPostsAPI.missing(id);
      return normalizePayload(response);
    },

    async uploadMedia(file) {
      this.ui.isUploadingMedia = true;
      this.ui.error = null;
      try {
        const response = await ContentMediaAPI.upload(file);
        return normalizePayload(response);
      } catch (error) {
        this.setError(error);
        throw error;
      } finally {
        this.ui.isUploadingMedia = false;
      }
    },

    async uploadMediaFromUrl(url) {
      this.ui.isUploadingMedia = true;
      this.ui.error = null;
      try {
        const response = await ContentMediaAPI.uploadFromUrl(url);
        return normalizePayload(response);
      } catch (error) {
        this.setError(error);
        throw error;
      } finally {
        this.ui.isUploadingMedia = false;
      }
    },

    async fetchAnalytics(params) {
      this.ui.isLoadingAnalytics = true;
      this.ui.error = null;
      try {
        const response = await ContentAnalyticsAPI.get(params);
        return normalizePayload(response);
      } catch (error) {
        this.setError(error);
        throw error;
      } finally {
        this.ui.isLoadingAnalytics = false;
      }
    },
  },
});
