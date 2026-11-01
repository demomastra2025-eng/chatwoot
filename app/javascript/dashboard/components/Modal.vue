<script setup>
import {
  computed,
  nextTick,
  onUnmounted,
  ref,
  useAttrs,
  useId,
  watch,
} from 'vue';
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
defineOptions({ inheritAttrs: false });
const attrs = useAttrs();
const dialogRef = ref(null);
const headingId = useId();
const automaticLabelId = ref(undefined);
let returnFocusTo;

// Preserve existing overlay attributes; accessible naming belongs to the dialog.
const overlayAttrs = () =>
  Object.fromEntries(
    Object.entries(attrs).filter(
      ([key]) =>
        !['aria-label', 'aria-labelledby', 'aria-describedby'].includes(key)
    )
  );
const isTopmost = () => {
  // Native dialogs occupy the top layer even when they occur earlier in the DOM.
  const nativeDialogs = [...document.querySelectorAll('dialog[open]')];
  if (nativeDialogs.some(dialog => !dialog.contains(dialogRef.value)))
    return false;
  const dialogs = document.querySelectorAll(
    '[data-legacy-modal], dialog[open]'
  );
  return dialogs[dialogs.length - 1] === dialogRef.value;
};
const focusableElements = () =>
  [
    ...dialogRef.value.querySelectorAll(
      'button, [href], input, select, textarea, [tabindex], [contenteditable]:not([contenteditable="false"]), summary'
    ),
  ]
    .filter(element => !element.matches(':disabled'))
    .filter(
      element =>
        element.tabIndex >= 0 ||
        (element.matches('[contenteditable]:not([contenteditable="false"])') &&
          !element.hasAttribute('tabindex'))
    )
    .filter(
      element => !element.closest('[hidden], [inert], [aria-hidden="true"]')
    )
    .filter(element => {
      let ancestor = element;
      while (ancestor && dialogRef.value.contains(ancestor)) {
        const style = getComputedStyle(ancestor);
        if (
          style.display === 'none' ||
          ['hidden', 'collapse'].includes(style.visibility)
        )
          return false;
        ancestor = ancestor.parentElement;
      }
      return true;
    });
const restoreFocus = () => {
  if (returnFocusTo?.isConnected) returnFocusTo.focus();
  returnFocusTo = undefined;
};

watch(
  show,
  async visible => {
    if (!visible) {
      await nextTick();
      if (!show.value) restoreFocus();
      return;
    }
    returnFocusTo = document.activeElement;
    automaticLabelId.value = undefined;
    await nextTick();
    if (!show.value || !dialogRef.value) return;
    const heading = dialogRef.value.querySelector(
      'h1, h2, h3, [role="heading"]'
    );
    if (heading) {
      if (!heading.id) heading.id = headingId;
      automaticLabelId.value = heading.id;
    }
    if (!isTopmost()) return;
    const autofocus = dialogRef.value.querySelector(
      '[autofocus]:not(:disabled)'
    );
    (autofocus || focusableElements()[0] || dialogRef.value).focus();
  },
  { immediate: true }
);

// A nested modal's opener may belong to a parent that is also being removed.
// Restore after removal so that a detached child opener cannot steal focus.
onUnmounted(restoreFocus);

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
  if (!show.value || !isTopmost()) return;
  if (e.key === 'Escape' || e.code === 'Escape') {
    close();
    e.preventDefault();
    e.stopPropagation();
    return;
  }
  if (e.key !== 'Tab') return;
  const controls = focusableElements();
  const first = controls[0] || dialogRef.value;
  const last = controls[controls.length - 1] || dialogRef.value;
  const active = document.activeElement;
  if (
    !controls.length ||
    !dialogRef.value.contains(active) ||
    (e.shiftKey && (active === first || active === dialogRef.value)) ||
    (!e.shiftKey && active === last)
  ) {
    e.preventDefault();
    (e.shiftKey ? last : first).focus();
  }
};

useEventListener(document, 'keydown', onKeydown);
useEventListener(document, 'focusin', event => {
  if (show.value && isTopmost() && !dialogRef.value.contains(event.target)) {
    (focusableElements()[0] || dialogRef.value).focus();
  }
});
</script>

<template>
  <transition name="modal-fade">
    <div
      v-if="show"
      v-bind="overlayAttrs()"
      :class="modalClassName"
      transition="modal"
      @click.self="handleBackdropClick"
    >
      <div
        ref="dialogRef"
        role="dialog"
        aria-modal="true"
        data-legacy-modal
        tabindex="-1"
        :aria-label="attrs['aria-label']"
        :aria-labelledby="
          attrs['aria-labelledby'] ||
          (!attrs['aria-label'] ? automaticLabelId : undefined)
        "
        :aria-describedby="attrs['aria-describedby']"
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
          type="button"
          :aria-label="$t('GENERAL.CLOSE')"
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
