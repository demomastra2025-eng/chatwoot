import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';

import SharedPhonePromotionDialog from './SharedPhonePromotionDialog.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => (params ? `${key} ${JSON.stringify(params)}` : key),
  }),
}));

const DialogStub = {
  emits: ['confirm'],
  methods: { open() {}, close() {} },
  template:
    '<div><slot /><button data-testid="dialog-confirm" @click="$emit(\'confirm\')" /></div>',
};

const preview = {
  fingerprint: 'abc',
  masked_phone: '+7 *** ***-**-09',
  previous_holder: { id: 11, name: 'Mother' },
  conversations: [
    { display_id: 42, inbox_name: 'WhatsApp', messages_count: 5 },
  ],
  messages_count: 5,
  not_moved_other_holders: [],
  not_moved_lid_chats_count: 1,
  siblings: [{ id: 13, name: 'Daughter' }],
};

const createWrapper = props =>
  mount(SharedPhonePromotionDialog, {
    props: { patientName: 'Son', ...props },
    global: { stubs: { Dialog: DialogStub } },
  });

describe('SharedPhonePromotionDialog', () => {
  it('shows exactly what moves, what stays and that the transfer is logged', () => {
    const wrapper = createWrapper({ preview });
    const text = wrapper.text();

    expect(text).toContain(
      'DIALOG_NUMBER {"phone":"+7 *** ***-**-09","patient":"Son"}'
    );
    expect(wrapper.find('[data-testid="shared-phone-moves"]').text()).toContain(
      '"owner":"Mother","patient":"Son","chats":1,"messages":5'
    );
    expect(text).toContain(
      'DIALOG_CHAT {"id":42,"inbox":"WhatsApp","messages":5}'
    );
    expect(text).toContain('DIALOG_STAYS {"owner":"Mother"}');
    expect(text).toContain('DIALOG_NOT_MOVED {"holders":0,"lid":1}');
    expect(text).toContain('HINT_SIBLINGS {"names":"Daughter"}');
    expect(text).toContain('DIALOG_AUDIT');
  });

  it('says nothing moves when the number has no chats', () => {
    const wrapper = createWrapper({
      preview: { ...preview, conversations: [], messages_count: 0 },
    });

    expect(
      wrapper.find('[data-testid="shared-phone-moves-nothing"]').exists()
    ).toBe(true);
  });

  it('emits confirm', async () => {
    const wrapper = createWrapper({ preview });

    await wrapper.find('[data-testid="dialog-confirm"]').trigger('click');

    expect(wrapper.emitted('confirm')).toHaveLength(1);
  });
});
