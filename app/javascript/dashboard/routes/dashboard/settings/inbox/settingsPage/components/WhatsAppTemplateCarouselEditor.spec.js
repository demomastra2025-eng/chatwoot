import { flushPromises, mount } from '@vue/test-utils';

import { uploadWhatsAppTemplateMedia } from 'dashboard/helper/uploadHelper';
import { createEmptyCarouselCard } from 'dashboard/helper/whatsappTemplateLibrary';
import WhatsAppTemplateCarouselEditor from './WhatsAppTemplateCarouselEditor.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('dashboard/helper/uploadHelper', () => ({
  uploadWhatsAppTemplateMedia: vi.fn(),
}));

const createCards = () => [
  createEmptyCarouselCard(),
  createEmptyCarouselCard(),
];

const mountEditor = cards => {
  let wrapper;
  wrapper = mount(WhatsAppTemplateCarouselEditor, {
    props: {
      modelValue: cards,
      'onUpdate:modelValue': value => wrapper.setProps({ modelValue: value }),
    },
    global: {
      stubs: {
        Button: true,
        ComboBox: true,
        Input: true,
        TextArea: true,
      },
    },
  });
  return wrapper;
};

const selectFile = async (wrapper, file, inputIndex = 0) => {
  const fileInput = wrapper.findAll('input[type="file"]')[inputIndex];
  Object.defineProperty(fileInput.element, 'files', { value: [file] });
  await fileInput.trigger('change');
};

describe('WhatsAppTemplateCarouselEditor', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('locks structural controls and reports upload state until media is attached', async () => {
    let resolveUpload;
    uploadWhatsAppTemplateMedia.mockReturnValue(
      new Promise(resolve => {
        resolveUpload = resolve;
      })
    );
    const wrapper = mountEditor(createCards());
    const file = new File(['image'], 'product.jpg', { type: 'image/jpeg' });

    await selectFile(wrapper, file);

    expect(uploadWhatsAppTemplateMedia).toHaveBeenCalledWith(file, 'image');
    expect(wrapper.emitted('uploadingChange')).toEqual([[true]]);
    expect(
      wrapper
        .findAll('input[type="file"]')
        .every(input => input.attributes('disabled') !== undefined)
    ).toBe(true);

    resolveUpload({
      blobId: 'signed-product-blob',
      fileUrl: 'https://app.one-link.kz/media/product.jpg',
    });
    await flushPromises();

    expect(wrapper.props('modelValue')[0]).toMatchObject({
      sampleMediaBlobId: 'signed-product-blob',
      sampleMediaFileName: 'product.jpg',
      sampleMediaUrl: 'https://app.one-link.kz/media/product.jpg',
    });
    expect(wrapper.emitted('uploadingChange')).toEqual([[true], [false]]);
  });

  it('does not attach a late upload result to replacement cards', async () => {
    let resolveUpload;
    uploadWhatsAppTemplateMedia.mockReturnValue(
      new Promise(resolve => {
        resolveUpload = resolve;
      })
    );
    const wrapper = mountEditor(createCards());
    const file = new File(['image'], 'stale.jpg', { type: 'image/jpeg' });

    await selectFile(wrapper, file);
    await wrapper.setProps({ modelValue: createCards() });

    resolveUpload({
      blobId: 'stale-blob',
      fileUrl: 'https://app.one-link.kz/media/stale.jpg',
    });
    await flushPromises();

    expect(
      wrapper.props('modelValue').every(card => card.sampleMediaBlobId === '')
    ).toBe(true);
  });
});
