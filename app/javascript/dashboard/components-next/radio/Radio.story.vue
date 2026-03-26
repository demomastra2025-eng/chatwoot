<script setup>
import { ref } from 'vue';
import Radio from './Radio.vue';

const selectedValue = ref('one');
</script>

<template>
  <Story title="Components/Radio" :layout="{ type: 'grid', width: '320px' }">
    <Variant title="States">
      <div class="space-y-4 p-2">
        <label class="flex items-center justify-between gap-4">
          <span>Option One</span>
          <Radio v-model="selectedValue" name="basic-story" value="one" />
        </label>

        <label class="flex items-center justify-between gap-4">
          <span>Option Two</span>
          <Radio v-model="selectedValue" name="basic-story" value="two" />
        </label>

        <label class="flex items-center justify-between gap-4">
          <span>Disabled</span>
          <Radio
            v-model="selectedValue"
            name="basic-story"
            value="disabled"
            disabled
          />
        </label>
      </div>
    </Variant>
  </Story>
</template>
