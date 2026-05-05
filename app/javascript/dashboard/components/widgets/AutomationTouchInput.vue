<script>
import WootMessageEditor from 'dashboard/components/widgets/WootWriter/Editor.vue';
import NextInput from 'dashboard/components-next/input/Input.vue';
import NextSwitch from 'dashboard/components-next/switch/Switch.vue';

const DEFAULT_TOUCH_PARAMS = {
  body: '',
  delay_minutes: 0,
  auto_cancel_on_incoming: false,
};

export default {
  components: {
    NextInput,
    NextSwitch,
    WootMessageEditor,
  },
  props: {
    eventName: {
      type: String,
      default: '',
    },
    modelValue: {
      type: [Array, Object],
      default: () => ({}),
    },
  },
  emits: ['update:modelValue', 'input'],
  computed: {
    entityKey() {
      if (this.eventName?.startsWith('appointment_')) return 'appointment';
      if (this.eventName?.startsWith('deal_')) return 'deal';
      if (this.eventName?.startsWith('task_')) return 'task';
      return 'conversation';
    },
    helperText() {
      const messages = {
        appointment: this.$t(
          'AUTOMATION.ACTION.TOUCH_EDITOR.HELPERS.appointment'
        ),
        conversation: this.$t(
          'AUTOMATION.ACTION.TOUCH_EDITOR.HELPERS.conversation'
        ),
        deal: this.$t('AUTOMATION.ACTION.TOUCH_EDITOR.HELPERS.deal'),
        task: this.$t('AUTOMATION.ACTION.TOUCH_EDITOR.HELPERS.task'),
      };

      return messages[this.entityKey] || messages.conversation;
    },
    normalizedValue() {
      const raw = Array.isArray(this.modelValue)
        ? this.modelValue[0]
        : this.modelValue;

      return {
        ...DEFAULT_TOUCH_PARAMS,
        ...(raw || {}),
      };
    },
    body: {
      get() {
        return this.normalizedValue.body;
      },
      set(value) {
        this.emitValue({ body: value });
      },
    },
    delayMinutes: {
      get() {
        return this.normalizedValue.delay_minutes;
      },
      set(value) {
        this.emitValue({ delay_minutes: value });
      },
    },
    autoCancelOnIncoming: {
      get() {
        return this.normalizedValue.auto_cancel_on_incoming;
      },
      set(value) {
        this.emitValue({ auto_cancel_on_incoming: value });
      },
    },
  },
  methods: {
    emitValue(partial) {
      const payload = {
        ...this.normalizedValue,
        ...partial,
      };

      this.$emit('update:modelValue', payload);
      this.$emit('input', payload);
    },
  },
};
</script>

<template>
  <div class="grid gap-3 rounded-lg border border-n-weak bg-n-alpha-1 p-3">
    <div class="grid gap-1">
      <p class="text-sm font-medium text-n-slate-12">
        {{ $t('AUTOMATION.ACTION.TOUCH_EDITOR.TITLE') }}
      </p>
      <p class="text-xs leading-5 text-n-slate-11">
        {{ helperText }}
      </p>
    </div>

    <div class="grid gap-2">
      <p class="text-xs font-medium uppercase tracking-wide text-n-slate-11">
        {{ $t('AUTOMATION.ACTION.TOUCH_EDITOR.BODY_LABEL') }}
      </p>
      <WootMessageEditor
        v-model="body"
        rows="4"
        enable-variables
        :placeholder="$t('AUTOMATION.ACTION.TOUCH_EDITOR.BODY_PLACEHOLDER')"
        class="[&_.ProseMirror-menubar]:hidden px-3 py-1 bg-n-solid-1 rounded-lg outline outline-1 outline-n-weak dark:outline-n-strong"
      />
    </div>

    <div class="grid gap-2 md:grid-cols-[160px_minmax(0,1fr)] md:items-start">
      <div class="grid gap-1">
        <p class="text-xs font-medium uppercase tracking-wide text-n-slate-11">
          {{ $t('AUTOMATION.ACTION.TOUCH_EDITOR.DELAY_LABEL') }}
        </p>
        <NextInput v-model="delayMinutes" type="number" min="0" size="sm" />
      </div>
      <p class="text-xs leading-5 text-n-slate-11 md:pt-6">
        {{ $t('AUTOMATION.ACTION.TOUCH_EDITOR.DELAY_NOTE') }}
      </p>
    </div>

    <div
      class="flex items-start justify-between gap-4 rounded-lg bg-n-solid-1 p-3"
    >
      <div class="min-w-0">
        <p class="mb-1 text-sm font-medium text-n-slate-12">
          {{ $t('AUTOMATION.ACTION.TOUCH_EDITOR.AUTO_CANCEL_LABEL') }}
        </p>
        <p class="text-xs leading-5 text-n-slate-11">
          {{ $t('AUTOMATION.ACTION.TOUCH_EDITOR.AUTO_CANCEL_NOTE') }}
        </p>
      </div>
      <NextSwitch v-model="autoCancelOnIncoming" />
    </div>
  </div>
</template>
