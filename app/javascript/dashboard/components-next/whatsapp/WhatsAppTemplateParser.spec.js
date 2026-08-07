import { computed, defineComponent, h, nextTick, ref } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

import WhatsAppTemplateParser from './WhatsAppTemplateParser.vue';
import { uploadFile } from 'dashboard/helper/uploadHelper';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/helper/uploadHelper', () => ({
  uploadFile: vi.fn(),
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

const mediaTemplate = {
  ...template,
  components: [
    { type: 'HEADER', format: 'IMAGE' },
    { type: 'BODY', text: 'Hello from template' },
  ],
};

const mountOptions = {
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

const createWrapper = () => mount(ParserParent, mountOptions);

describe('WhatsAppTemplateParser', () => {
  it('exposes template validity to parent campaign forms', async () => {
    const wrapper = createWrapper();
    await nextTick();

    expect(wrapper.vm.childIsFormInvalid).toBe(false);
  });

  it('accepts a OneLink file instead of a manually entered media URL', async () => {
    uploadFile.mockResolvedValue({
      fileUrl: 'https://app.one-link.kz/media/invoice.jpg',
    });
    const wrapper = mount(WhatsAppTemplateParser, {
      ...mountOptions,
      props: { template: mediaTemplate },
    });
    const file = new File(['image'], 'invoice.jpg', { type: 'image/jpeg' });
    const fileInput = wrapper.find('input[type="file"]');
    Object.defineProperty(fileInput.element, 'files', { value: [file] });

    await fileInput.trigger('change');
    await flushPromises();

    expect(uploadFile).toHaveBeenCalledWith(file);
    expect(wrapper.vm.processedParams.header.media_url).toBe(
      'https://app.one-link.kz/media/invoice.jpg'
    );
  });
});
