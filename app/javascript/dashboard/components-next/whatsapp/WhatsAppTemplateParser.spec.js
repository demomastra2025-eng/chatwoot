import { computed, defineComponent, h, nextTick, ref } from 'vue';
import { mount } from '@vue/test-utils';

import WhatsAppTemplateParser from './WhatsAppTemplateParser.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

const template = {
  name: 'intention_request',
  category: 'MARKETING',
  language: 'kk',
  namespace: '',
  components: [
    {
      type: 'BODY',
      text: 'Hello from template',
    },
  ],
};

const ParserParent = defineComponent({
  setup(_, { expose }) {
    const parserRef = ref(null);
    const childIsFormInvalid = computed(() => parserRef.value?.isFormInvalid);

    expose({ childIsFormInvalid });

    return () =>
      h(WhatsAppTemplateParser, {
        ref: parserRef,
        template,
      });
  },
});

const createWrapper = () =>
  mount(ParserParent, {
    global: {
      stubs: {
        Input: true,
        TemplateParamInput: true,
      },
    },
  });

describe('WhatsAppTemplateParser', () => {
  it('exposes template validity to parent campaign forms', async () => {
    const wrapper = createWrapper();
    await nextTick();

    expect(wrapper.vm.childIsFormInvalid).toBe(false);
  });
});
