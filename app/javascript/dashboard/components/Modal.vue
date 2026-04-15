<script setup>
import { computed, defineEmits } from 'vue';
import { useEventListener } from '@vueuse/core';
import Button from 'dashboard/components-next/button/Button.vue';

const { modalType, closeOnBackdropClick, onClose } = defineProps({
  closeOnBackdropClick: { type: Boolean, default: true },
  showCloseButton: { type: Boolean, default: true },
  onClose: { type: Function, default: undefined },
  fullWidth: { type: Boolean, default: false },
  modalType: { type: String, default: 'centered' },
  size: { type: String, default: '' },
});

const emit = defineEmits(['close']);
const show = defineModel('show', { type: Boolean, default: false });

const modalClassName = computed(() => {
  const modalClassNameMap = {
    centered: '',
    'right-aligned': 'right-aligned',
  };

  return `modal-mask skip-context-menu ${modalClassNameMap[modalType] || ''}`;
});

const close = () => {
  show.value = false;
  emit('close');
  onClose?.();
};

const handleBackdropClick = () => {
  if (!closeOnBackdropClick) {
    return;
  }

  close();
};

const onKeydown = e => {
  if (show.value && e.code === 'Escape') {
    close();
    e.stopPropagation();
  }
};

useEventListener(document, 'keydown', onKeydown);
</script>

<template>
  <transition name="modal-fade">
    <div
      v-if="show"
      :class="modalClassName"
      transition="modal"
      @click.self="handleBackdropClick"
    >
      <div
        class="relative max-h-full overflow-auto bg-n-alpha-3 shadow-md modal-container rtl:text-right skip-context-menu"
        :class="{
          'rounded-xl w-[37.5rem]': !fullWidth,
          'items-center rounded-none flex h-full justify-center w-full':
            fullWidth,
          [size]: true,
        }"
        @mouse.stop
        @mousedown="event => event.stopPropagation()"
      >
        <Button
          v-if="showCloseButton"
          ghost
          slate
          icon="i-lucide-x"
          class="absolute z-10 right-2 top-2"
          @click="close"
        />
        <slot />
      </div>
    </div>
  </transition>
</template>

<style lang="scss">
.modal-mask {
  @apply flex items-center justify-center bg-n-alpha-black2 backdrop-blur-[4px] z-[9990] h-full left-0 fixed top-0 w-full;

  .modal-container {
    &.medium {
      @apply max-w-[80%] w-[56.25rem];
    }

    // .content-box {
    //   @apply h-auto p-0;
    // }
    .content {
      @apply p-8;
    }

    form,
    .modal-content {
      @apply pt-4 pb-8 px-8 self-center;

      a {
        @apply p-4;
      }
    }
  }
}

.modal-big {
  @apply w-full;
}

.modal-mask.right-aligned {
  @apply justify-end;

  .modal-container {
    @apply rounded-none h-full w-[30rem];
  }
}

.modal-enter,
.modal-leave {
  @apply opacity-0;
}

.modal-enter .modal-container,
.modal-leave .modal-container {
  transform: scale(1.1);
}
</style>
