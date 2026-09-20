import { mount } from '@vue/test-utils';
import { nextTick } from 'vue';
import { afterEach, describe, expect, it } from 'vitest';

import CrmConflictNotice from './CrmConflictNotice.vue';

let wrapper;

afterEach(() => {
  wrapper?.unmount();
  document.body.innerHTML = '';
});

describe('CrmConflictNotice', () => {
  it('moves focus to a newly rendered conflict alert', async () => {
    wrapper = mount(CrmConflictNotice, {
      attachTo: document.body,
      global: {
        mocks: { $t: key => key },
        stubs: { Button: true, Icon: true },
      },
    });

    await nextTick();

    const notice = wrapper.find('[data-test="crm-conflict-notice"]');
    expect(notice.attributes('role')).toBe('alert');
    expect(notice.attributes('tabindex')).toBe('-1');
    expect(document.activeElement).toBe(notice.element);
  });
});
