<script>
export default {
  props: {
    message: { type: String, default: '' },
    action: {
      type: Object,
      default: () => ({}),
    },
  },
  computed: {
    isActionPresent() {
      return this.action && this.action.message;
    },
  },
};
</script>

<template>
  <div
    class="bg-n-slate-12 dark:bg-n-slate-7 rounded-md drop-shadow-md mb-4 max-w-full inline-flex flex-wrap items-center min-w-0 sm:min-w-[22rem] py-3 px-4"
    :class="isActionPresent ? 'justify-between' : 'justify-center'"
  >
    <div class="min-w-0 break-words text-sm font-medium text-white">
      {{ message }}
    </div>
    <div v-if="isActionPresent" class="min-w-0 max-w-full break-words sm:ml-4">
      <router-link v-if="action.type == 'link'" :to="action.to" class="">
        {{ action.message }}
      </router-link>
    </div>
  </div>
</template>
