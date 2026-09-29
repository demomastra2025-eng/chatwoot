import { computed, nextTick, onBeforeUnmount, ref, watch } from 'vue';
import { useEventListener } from '@vueuse/core';

// The last place the employee dragged the phone to, per browser.
export const PHONE_WIDGET_POSITION_STORAGE_KEY =
  'onelink:phone-widget-position';
// Gap kept between the phone and every edge of the window.
export const PHONE_WIDGET_VIEWPORT_MARGIN = 8;

// Controls inside the drag handle keep working as buttons.
const INTERACTIVE_SELECTOR =
  'button, a, input, select, textarea, [role="button"]';

const isFiniteNumber = value =>
  typeof value === 'number' && Number.isFinite(value);

/**
 * Moves a { left, top } position so that a box of the given size stays fully
 * inside the viewport. A box larger than the viewport sticks to the top-left
 * margin (the phone limits its own height to the viewport).
 */
export const clampPhoneWidgetPosition = (
  position,
  size,
  viewport,
  margin = PHONE_WIDGET_VIEWPORT_MARGIN
) => {
  const maxLeft = Math.max(margin, viewport.width - size.width - margin);
  const maxTop = Math.max(margin, viewport.height - size.height - margin);
  return {
    left: Math.round(Math.min(Math.max(position.left, margin), maxLeft)),
    top: Math.round(Math.min(Math.max(position.top, margin), maxTop)),
  };
};

// Storage may be unavailable (private mode, blocked site data): the phone then
// simply opens at its default place.
export const readPhoneWidgetPosition = () => {
  try {
    const raw = window.localStorage.getItem(PHONE_WIDGET_POSITION_STORAGE_KEY);
    if (!raw) return null;
    const { left, top } = JSON.parse(raw) || {};
    return isFiniteNumber(left) && isFiniteNumber(top) ? { left, top } : null;
  } catch {
    return null;
  }
};

export const savePhoneWidgetPosition = position => {
  try {
    window.localStorage.setItem(
      PHONE_WIDGET_POSITION_STORAGE_KEY,
      JSON.stringify({ left: position.left, top: position.top })
    );
  } catch {
    // Not remembering the place is harmless.
  }
};

const viewportSize = () => ({
  width: window.innerWidth,
  height: window.innerHeight,
});

/**
 * Drag-to-move for the phone widget. Until the employee drags it, the phone
 * keeps its default CSS place (position is null); afterwards it is placed by
 * left/top, always clamped inside the window: while dragging, when the window
 * is resized and when the phone changes size (dialer, keypad, call cards).
 */
export function usePhoneWidgetPosition(widgetRef) {
  const position = ref(readPhoneWidgetPosition());
  const isDragging = ref(false);
  let drag = null;
  let resizeObserver = null;

  const measure = () => {
    const rect = widgetRef.value?.getBoundingClientRect?.();
    // A hidden or detached phone has no size to keep inside the window.
    if (!rect || (!rect.width && !rect.height)) return null;
    return rect;
  };

  const clampToViewport = () => {
    if (!position.value || drag) return;
    const rect = measure();
    if (!rect) return;
    const next = clampPhoneWidgetPosition(position.value, rect, viewportSize());
    // Only a drag saves the place: a temporarily small window must not
    // overwrite where the employee put the phone.
    if (next.left !== position.value.left || next.top !== position.value.top) {
      position.value = next;
    }
  };

  const onPointerMove = event => {
    if (!drag) return;
    position.value = clampPhoneWidgetPosition(
      {
        left: drag.startLeft + (event.clientX - drag.startX),
        top: drag.startTop + (event.clientY - drag.startY),
      },
      drag.size,
      viewportSize()
    );
  };

  const stopDragging = () => {
    window.removeEventListener('pointermove', onPointerMove);
    window.removeEventListener('pointerup', stopDragging);
    window.removeEventListener('pointercancel', stopDragging);
    if (!drag) return;
    drag = null;
    isDragging.value = false;
    if (position.value) savePhoneWidgetPosition(position.value);
  };

  const startDrag = event => {
    if (drag) return;
    // Mouse: primary button only. Touch and pen report button 0 as well.
    if (typeof event.button === 'number' && event.button !== 0) return;
    if (event.target?.closest?.(INTERACTIVE_SELECTOR)) return;
    const rect = measure();
    if (!rect) return;

    const start = clampPhoneWidgetPosition(
      position.value || { left: rect.left, top: rect.top },
      rect,
      viewportSize()
    );
    drag = {
      startX: event.clientX,
      startY: event.clientY,
      startLeft: start.left,
      startTop: start.top,
      size: { width: rect.width, height: rect.height },
    };
    position.value = start;
    isDragging.value = true;
    // Keeps the page from scrolling or selecting text under a touch drag.
    event.preventDefault?.();
    window.addEventListener('pointermove', onPointerMove);
    window.addEventListener('pointerup', stopDragging);
    window.addEventListener('pointercancel', stopDragging);
  };

  const scheduleClamp = () => nextTick(clampToViewport);

  useEventListener(window, 'resize', clampToViewport);

  watch(
    widgetRef,
    element => {
      resizeObserver?.disconnect();
      resizeObserver = null;
      if (!element) return;
      // The restored place may be outside a smaller window: re-clamp it once
      // the phone is on screen and whenever its size changes.
      scheduleClamp();
      if (typeof window.ResizeObserver === 'function') {
        resizeObserver = new window.ResizeObserver(() => clampToViewport());
        resizeObserver.observe(element);
      }
    },
    { immediate: true, flush: 'post' }
  );

  onBeforeUnmount(() => {
    resizeObserver?.disconnect();
    resizeObserver = null;
    stopDragging();
  });

  const positionStyle = computed(() =>
    position.value
      ? {
          left: `${position.value.left}px`,
          top: `${position.value.top}px`,
          right: 'auto',
        }
      : null
  );

  return {
    position,
    positionStyle,
    isDragging,
    startDrag,
    clampToViewport,
    scheduleClamp,
  };
}
