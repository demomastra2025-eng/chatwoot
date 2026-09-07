import { mount } from '@vue/test-utils';
import { createI18n } from 'vue-i18n';
import en from '../i18n/locale/en/chatlist.json';
import ru from '../i18n/locale/ru/chatlist.json';
import kk from '../i18n/locale/kk/chatlist.json';
import ConversationListLoadError from './ConversationListLoadError.vue';

describe.each(Object.entries({ en, ru, kk }))(
  'list retry in %s',
  (locale, messages) => {
    it('renders real locale text and retries only on user action', async () => {
      const wrapper = mount(ConversationListLoadError, {
        global: {
          plugins: [
            createI18n({
              legacy: false,
              locale,
              messages: { [locale]: messages },
            }),
          ],
        },
      });
      expect(wrapper.text()).toContain(messages.CHAT_LIST.LOAD_ERROR);
      expect(wrapper.text()).not.toContain('CHAT_LIST.');
      expect(wrapper.emitted('retry')).toBeUndefined();
      await wrapper.get('button').trigger('click');
      expect(wrapper.emitted('retry')).toHaveLength(1);
      wrapper.unmount();
    });
  }
);
