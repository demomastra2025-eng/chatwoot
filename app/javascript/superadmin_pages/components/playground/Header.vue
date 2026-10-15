<script setup>
defineProps({
  responseSourcePath: {
    type: String,
    required: true,
  },
  responseSourceName: {
    type: String,
    required: true,
  },
});
</script>

<template>
  <header
    class="flex items-center px-8 py-4 bg-n-solid-2 border-b border-n-weak"
    role="banner"
  >
    <a :href="responseSourcePath" class="text-n-brand hover:underline mr-4">
      {{ 'Back' }}
    </a>
    <div
      class="border border-solid border-n-weak text-n-slate-12 mr-4 p-2 rounded-full"
    >
      <svg width="24" height="24"><use xlink:href="#icon-mist-fill" /></svg>
    </div>
    <div class="flex flex-col h-14 justify-center">
      <h1 id="page-title" class="text-base font-medium text-n-slate-12">
        {{ 'Robin AI playground' }}
      </h1>
      <p class="text-sm text-n-slate-11">
        {{ 'Chat with the source' }}
        <span class="font-medium">
          {{ responseSourceName }}
        </span>
        {{ 'and evaluate it’s efficiency.' }}
      </p>
    </div>
  </header>
</template>
