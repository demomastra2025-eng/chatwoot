<script>
import TeamAvailability from 'widget/components/TeamAvailability.vue';
import { mapGetters } from 'vuex';
import { useRouter } from 'vue-router';
import configMixin from 'widget/mixins/configMixin';
import ArticleContainer from '../components/pageComponents/Home/Article/ArticleContainer.vue';
export default {
  name: 'Home',
  components: {
    ArticleContainer,
    TeamAvailability,
  },
  mixins: [configMixin],
  setup() {
    const router = useRouter();
    return { router };
  },
  computed: {
    ...mapGetters({
      availableAgents: 'agent/availableAgents',
      conversationSize: 'conversation/getConversationSize',
      unreadMessageCount: 'conversation/getUnreadMessageCount',
    }),
    isBookingEnabled() {
      return Boolean(window.chatwootWebChannel?.bookingEnabled);
    },
  },
  mounted() {
    const params = new URLSearchParams(window.location.search);
    if (params.get('booking') === '1' && this.isBookingEnabled) {
      this.startBooking();
    }
  },
  methods: {
    startConversation() {
      if (this.preChatFormEnabled && !this.conversationSize) {
        return this.router.replace({ name: 'prechat-form' });
      }
      return this.router.replace({ name: 'messages' });
    },
    startBooking() {
      return this.router.push({ name: 'booking' });
    },
  },
};
</script>

<template>
  <div class="z-50 flex flex-col justify-end flex-1 w-full p-4 gap-4">
    <div
      v-if="isBookingEnabled"
      data-testid="widget-home-booking-card"
      class="flex items-center justify-between gap-3 rounded-xl border border-n-weak bg-n-solid-2 p-4 shadow-sm"
    >
      <div class="min-w-0">
        <p class="m-0 text-sm font-semibold text-n-slate-12">
          📅 Онлайн-запись на приём
        </p>
        <p class="m-0 mt-0.5 text-xs text-n-slate-11">
          Выберите врача и свободное время в расписании без ожидания ответа
        </p>
      </div>
      <button
        type="button"
        data-testid="widget-home-booking-btn"
        class="shrink-0 rounded-lg px-3.5 py-2 text-xs font-semibold text-white shadow-sm"
        :style="{ backgroundColor: widgetColor || '#1f93ff' }"
        @click="startBooking"
      >
        Записаться
      </button>
    </div>

    <TeamAvailability
      :available-agents="availableAgents"
      :has-conversation="!!conversationSize"
      :unread-count="unreadMessageCount"
      @start-conversation="startConversation"
    />

    <ArticleContainer />
  </div>
</template>
