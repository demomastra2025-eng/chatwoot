import { computed, defineComponent, h, nextTick, ref } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

import WhatsAppTemplateParser from './WhatsAppTemplateParser.vue';
import { uploadWhatsAppTemplateMedia } from 'dashboard/helper/uploadHelper';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/helper/uploadHelper', () => ({
  uploadWhatsAppTemplateMedia: vi.fn(),
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

const createDeferred = () => {
  let resolve;
  const promise = new Promise(resolvePromise => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
};

const selectMediaFile = async (wrapper, file) => {
  const fileInput = wrapper.find('input[type="file"]');
  Object.defineProperty(fileInput.element, 'files', {
    configurable: true,
    value: [file],
  });
  await fileInput.trigger('change');
};

describe('WhatsAppTemplateParser', () => {
  it('exposes template validity to parent campaign forms', async () => {
    const wrapper = createWrapper();
    await nextTick();

    expect(wrapper.vm.childIsFormInvalid).toBe(false);
  });

  it('accepts a OneLink file instead of a manually entered media URL', async () => {
    uploadWhatsAppTemplateMedia.mockResolvedValue({
      fileUrl: 'https://app.one-link.kz/media/invoice.jpg',
    });
    const wrapper = mount(WhatsAppTemplateParser, {
      ...mountOptions,
      props: { template: mediaTemplate },
    });
    const file = new File(['image'], 'invoice.jpg', { type: 'image/jpeg' });

    await selectMediaFile(wrapper, file);
    await flushPromises();

    expect(uploadWhatsAppTemplateMedia).toHaveBeenCalledWith(file, 'image');
    expect(wrapper.vm.processedParams.header.media_url).toBe(
      'https://app.one-link.kz/media/invoice.jpg'
    );
  });

  it('blocks send while replacement media is still uploading', async () => {
    const upload = createDeferred();
    uploadWhatsAppTemplateMedia.mockReturnValue(upload.promise);
    const wrapper = mount(WhatsAppTemplateParser, {
      ...mountOptions,
      props: {
        template: mediaTemplate,
        initialProcessedParams: {
          header: { media_url: 'https://app.one-link.kz/media/old.jpg' },
        },
      },
    });
    const file = new File(['new'], 'new.jpg', { type: 'image/jpeg' });

    await selectMediaFile(wrapper, file);
    wrapper.vm.sendMessage();

    expect(wrapper.emitted('sendMessage')).toBeUndefined();

    upload.resolve({ fileUrl: 'https://app.one-link.kz/media/new.jpg' });
    await flushPromises();
    wrapper.vm.sendMessage();

    expect(wrapper.emitted('sendMessage')).toHaveLength(1);
    expect(
      wrapper.emitted('sendMessage')[0][0].templateParams.processed_params
        .header.media_url
    ).toBe('https://app.one-link.kz/media/new.jpg');
  });

  it('ignores a late media result after resetting the template', async () => {
    const upload = createDeferred();
    uploadWhatsAppTemplateMedia.mockReturnValue(upload.promise);
    const wrapper = mount(WhatsAppTemplateParser, {
      ...mountOptions,
      props: { template: mediaTemplate },
    });
    const file = new File(['image'], 'late.jpg', { type: 'image/jpeg' });

    await selectMediaFile(wrapper, file);
    wrapper.vm.resetTemplate();
    upload.resolve({ fileUrl: 'https://app.one-link.kz/media/late.jpg' });
    await flushPromises();

    expect(wrapper.emitted('resetTemplate')).toHaveLength(1);
    expect(wrapper.vm.processedParams.header.media_url).not.toBe(
      'https://app.one-link.kz/media/late.jpg'
    );
  });
});
