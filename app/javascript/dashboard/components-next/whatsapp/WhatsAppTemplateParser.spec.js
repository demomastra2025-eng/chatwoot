import { computed, defineComponent, h, nextTick, ref } from 'vue';
import { mount } from '@vue/test-utils';

import WhatsAppTemplateParser from './WhatsAppTemplateParser.vue';

const storeMockState = vi.hoisted(() => ({
  sendableFlows: [],
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables/store', async () => {
  const vue = await vi.importActual('vue');
  return {
    useFunctionGetter: () => vue.computed(() => storeMockState.sendableFlows),
  };
});

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

const flowTemplate = {
  ...template,
  name: 'lead_flow_template',
  components: [
    {
      type: 'BODY',
      text: 'Hello from template',
    },
    {
      type: 'BUTTONS',
      buttons: [{ type: 'FLOW', text: 'Open form' }],
    },
  ],
};

const createWrapper = (parserTemplate = template) => {
  const ParserParent = defineComponent({
    setup(_, { expose }) {
      const parserRef = ref(null);
      const childIsFormInvalid = computed(() => parserRef.value?.isFormInvalid);

      expose({ childIsFormInvalid });

      return () =>
        h(WhatsAppTemplateParser, {
          ref: parserRef,
          inboxId: 24,
          template: parserTemplate,
        });
    },
  });

  return mount(ParserParent, {
    global: {
      directives: {
        'dompurify-html': (el, binding) => {
          el.innerHTML = binding.value || '';
        },
      },
      stubs: {
        Input: true,
        TemplateParamInput: true,
      },
    },
  });
};

describe('WhatsAppTemplateParser', () => {
  beforeEach(() => {
    storeMockState.sendableFlows = [];
  });

  it('exposes template validity to parent campaign forms', async () => {
    const wrapper = createWrapper();
    await nextTick();

    expect(wrapper.vm.childIsFormInvalid).toBe(false);
  });

  it('requires a local Flow reference for WhatsApp Flow template buttons', async () => {
    storeMockState.sendableFlows = [
      { id: 7, name: 'Lead form', provider_flow_id: 'flow-123' },
    ];

    const wrapper = createWrapper(flowTemplate);
    await nextTick();

    expect(wrapper.find('select').exists()).toBe(true);
    expect(wrapper.vm.childIsFormInvalid).toBe(true);

    await wrapper.find('select').setValue('7');

    expect(wrapper.vm.childIsFormInvalid).toBe(false);
  });
});
