import { flushPromises, mount } from '@vue/test-utils';

import TouchMessageComposer from './TouchMessageComposer.vue';
import { uploadWhatsAppTemplateMedia } from 'dashboard/helper/uploadHelper';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('dashboard/helper/uploadHelper', () => ({
  uploadWhatsAppTemplateMedia: vi.fn(),
}));

const mediaTemplate = {
  name: 'document_template',
  category: 'UTILITY',
  language: 'ru',
  components: [
    { type: 'HEADER', format: 'DOCUMENT' },
    { type: 'BODY', text: 'Документ' },
  ],
};

const createDeferred = () => {
  let resolve;
  const promise = new Promise(resolvePromise => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
};

const createWrapper = () =>
  mount(TouchMessageComposer, {
    props: {
      bodyEditorId: 'touch-body',
      instructionsEditorId: 'touch-instructions',
      contentKind: 'channel_template',
      enableAttachments: false,
      selectedTemplate: mediaTemplate,
      templateName: mediaTemplate.name,
      templateLanguage: mediaTemplate.language,
      templateOptions: [
        { label: mediaTemplate.name, value: mediaTemplate.name },
      ],
      templateParams: {
        header: {
          media_url: 'https://app.one-link.kz/media/old.pdf',
          media_name: 'old.pdf',
        },
      },
    },
    global: {
      mocks: { $t: key => key },
      directives: {
        'dompurify-html': (el, binding) => {
          el.innerHTML = binding.value || '';
        },
      },
      stubs: {
        Button: true,
        ComboBox: true,
        Input: true,
        TabBar: true,
        TemplateParamInput: true,
        TemplatePreview: true,
        WootMessageEditor: true,
      },
    },
  });

it('marks an external touch composer invalid while replacement media is uploading', async () => {
  const upload = createDeferred();
  uploadWhatsAppTemplateMedia.mockReturnValue(upload.promise);
  const wrapper = createWrapper();
  await flushPromises();

  expect(wrapper.vm.isTemplateReady()).toBe(true);

  const fileInput = wrapper.find('input[type="file"]');
  const replacement = new File(['new'], 'new.pdf', {
    type: 'application/pdf',
  });
  Object.defineProperty(fileInput.element, 'files', {
    configurable: true,
    value: [replacement],
  });
  await fileInput.trigger('change');

  expect(wrapper.vm.isTemplateReady()).toBe(false);
  expect(wrapper.vm.hasValidTemplate).toBe(false);

  upload.resolve({ fileUrl: 'https://app.one-link.kz/media/new.pdf' });
  await flushPromises();

  expect(wrapper.vm.isTemplateReady()).toBe(true);
  expect(wrapper.vm.parserState.processedParams.header).toMatchObject({
    media_url: 'https://app.one-link.kz/media/new.pdf',
    media_name: 'new.pdf',
  });
});
