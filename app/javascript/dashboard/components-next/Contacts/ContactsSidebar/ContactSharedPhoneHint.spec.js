import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';

import ContactSharedPhoneHint from './ContactSharedPhoneHint.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => (params ? `${key} ${JSON.stringify(params)}` : key),
  }),
}));

const ButtonStub = {
  props: ['label'],
  emits: ['click'],
  template: '<button @click="$emit(\'click\')">{{ label }}</button>',
};

const createWrapper = hint =>
  mount(ContactSharedPhoneHint, {
    props: { hint, patientName: 'Son' },
    global: { stubs: { Button: ButtonStub } },
  });

describe('ContactSharedPhoneHint', () => {
  const hint = {
    masked_phone: '+7 *** ***-**-09',
    reason: 'released',
    previous_holder: { id: 11, name: 'Mother' },
    siblings: [{ id: 13, name: 'Daughter' }],
  };

  it('asks whether to make the released number primary and names the siblings', () => {
    const wrapper = createWrapper(hint);

    expect(wrapper.text()).toContain(
      'HINT_RELEASED {"phone":"+7 *** ***-**-09","owner":"Mother","patient":"Son"}'
    );
    expect(wrapper.text()).toContain('HINT_SIBLINGS {"names":"Daughter"}');
  });

  it('does not leave an empty owner name when the previous holder is gone', () => {
    const wrapper = createWrapper({ ...hint, previous_holder: null });

    expect(wrapper.text()).toContain(
      'HINT_RELEASED_NO_OWNER {"phone":"+7 *** ***-**-09","patient":"Son"}'
    );
    expect(wrapper.text()).not.toContain('"owner":""');
  });

  it('uses the MedElement wording for a blocked automatic promotion', () => {
    const wrapper = createWrapper({
      ...hint,
      reason: 'medelement',
      siblings: [],
    });

    expect(wrapper.text()).toContain('HINT_MEDELEMENT');
    expect(wrapper.text()).not.toContain('HINT_SIBLINGS');
  });

  it('emits promote and dismiss', async () => {
    const wrapper = createWrapper(hint);

    await wrapper
      .find('[data-testid="contact-shared-phone-hint-promote"]')
      .trigger('click');
    await wrapper
      .find('[data-testid="contact-shared-phone-hint-dismiss"]')
      .trigger('click');

    expect(wrapper.emitted('promote')).toHaveLength(1);
    expect(wrapper.emitted('dismiss')).toHaveLength(1);
  });
});
