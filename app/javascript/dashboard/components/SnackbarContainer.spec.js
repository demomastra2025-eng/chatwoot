import { mount } from '@vue/test-utils';
import { nextTick } from 'vue';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const i18n = vi.hoisted(() => ({ t: vi.fn(key => key) }));

vi.mock('vue-i18n', () => ({ useI18n: () => i18n }));

import { emitter } from 'shared/helpers/mitt';
import SnackbarContainer from './SnackbarContainer.vue';

describe('SnackbarContainer', () => {
  let wrapper;

  beforeEach(() => {
    vi.useFakeTimers();
    i18n.t.mockClear();
    wrapper = mount(SnackbarContainer, {
      global: {
        stubs: {
          WootSnackbar: {
            props: ['message', 'action'],
            template: '<div data-testid="toast">{{ message }}</div>',
          },
        },
      },
    });
  });

  afterEach(() => {
    wrapper.unmount();
    vi.useRealTimers();
  });

  it('removes only the toast whose timer expired when durations overlap', async () => {
    emitter.emit('newToastMessage', { message: 'regular notice' });
    await nextTick();
    vi.advanceTimersByTime(1000);

    emitter.emit('newToastMessage', {
      message: 'recovery notice',
      action: { type: 'callback', message: 'refresh', duration: 10_000 },
    });
    await nextTick();

    await vi.advanceTimersByTimeAsync(1501);
    await nextTick();
    expect(wrapper.findAll('[data-testid="toast"]').map(toast => toast.text()))
      .toEqual(['recovery notice']);

    await vi.advanceTimersByTimeAsync(8499);
    await nextTick();
    expect(wrapper.findAll('[data-testid="toast"]')).toHaveLength(0);
  });

  it('does not translate an absent action label', async () => {
    emitter.emit('newToastMessage', {
      message: 'existing caller notice',
      action: { usei18n: true, duration: 10_000 },
    });
    await nextTick();

    expect(i18n.t).not.toHaveBeenCalledWith(undefined);
    expect(wrapper.find('[data-testid="toast"]').text()).toBe(
      'existing caller notice'
    );
  });
});
