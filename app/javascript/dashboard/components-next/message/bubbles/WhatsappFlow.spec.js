import { mount } from '@vue/test-utils';
import { ref } from 'vue';
import WhatsappFlowBubble from './WhatsappFlow.vue';
import { provideMessageContext } from '../provider';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => ref([]),
}));

const mountBubble = contentAttributes => {
  const Wrapper = {
    components: { WhatsappFlowBubble },
    setup() {
      provideMessageContext({
        content: ref('Flow response received'),
        contentAttributes: ref(contentAttributes),
        variant: ref('agent'),
        orientation: ref('right'),
        inReplyTo: ref(null),
        shouldGroupWithNext: ref(false),
      });
    },
    template: '<WhatsappFlowBubble />',
  };

  return mount(Wrapper, {
    global: {
      stubs: {
        BaseBubble: {
          template: '<div data-test-id="base-bubble"><slot /></div>',
        },
        MessageMeta: true,
      },
    },
  });
};

describe('WhatsappFlowBubble', () => {
  it('renders submitted Flow fields without exposing the flow token', () => {
    const wrapper = mountBubble({
      interactiveReplyType: 'nfm_reply',
      flowReplyName: 'lead_qualification',
      flowResponse: {
        customer_name: 'Aruzhan',
        budget: '1000000',
        flow_token: '[REDACTED]',
      },
    });

    expect(wrapper.text()).toContain('Aruzhan');
    expect(wrapper.text()).toContain('1000000');
    expect(wrapper.text()).not.toContain('flow_token');
    expect(wrapper.text()).not.toContain('[REDACTED]');
  });
});
