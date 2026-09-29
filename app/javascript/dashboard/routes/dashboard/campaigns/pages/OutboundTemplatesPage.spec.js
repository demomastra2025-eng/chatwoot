import { shallowMount } from '@vue/test-utils';
import { reactive, ref } from 'vue';

import OutboundTemplatesPage from './OutboundTemplatesPage.vue';

const route = reactive({ name: 'outbound_templates_index' });
const inboxes = ref([]);

vi.mock('vue-router', () => ({
  useRoute: () => route,
}));

// The embedded pages pull in the whole router; only their placement matters.
vi.mock('../../settings/canned/Index.vue', () => ({
  default: {
    name: 'CannedHome',
    template: '<div data-test="canned-home" />',
    methods: { openAddPopup: () => {} },
  },
}));

vi.mock('../../settings/inbox/settingsPage/WhatsAppTemplatesPage.vue', () => ({
  default: {
    name: 'WhatsAppTemplatesPage',
    template: '<div data-test="whatsapp-templates" />',
  },
}));

vi.mock(
  'dashboard/components-next/Outbound/OutboundWorkspaceLayout.vue',
  () => ({
    default: {
      name: 'OutboundWorkspaceLayout',
      props: ['title', 'description'],
      template:
        '<section :data-title="title" :data-description="description"><slot name="meta" /><slot name="actions" /><slot name="tabs" /><slot /></section>',
    },
  })
);

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => (params ? `${key}:${JSON.stringify(params)}` : key),
  }),
}));

vi.mock('dashboard/composables/store', () => ({
  useStoreGetters: () => ({
    getSortedCannedResponses: ref(() => [{ id: 1 }, { id: 2 }]),
  }),
  useMapGetter: key => {
    if (key === 'inboxes/getOutboundCampaignInboxes') return inboxes;
    if (key === 'inboxes/getFilteredWhatsAppTemplates') return ref(() => []);
    return ref(null);
  },
}));

const mountComponent = () =>
  shallowMount(OutboundTemplatesPage, {
    global: {
      mocks: { $t: key => key },
      stubs: {
        OutboundWorkspaceLayout: {
          props: ['title', 'description'],
          template:
            '<section :data-title="title" :data-description="description"><slot name="meta" /><slot name="actions" /><slot name="tabs" /><slot /></section>',
        },
        CannedHome: {
          template: '<div data-test="canned-home" />',
          methods: { openAddPopup: () => {} },
        },
        WhatsAppTemplatesPage: true,
        ComboBox: true,
        Button: true,
      },
    },
  });

describe('OutboundTemplatesPage', () => {
  beforeEach(() => {
    route.name = 'outbound_templates_index';
    inboxes.value = [];
  });

  it('shows quick replies on the templates route without top tabs', () => {
    const wrapper = mountComponent();
    const layout = wrapper.get('section');

    expect(layout.attributes('data-title')).toBe(
      'OUTBOUND_WORKSPACE.TEMPLATES.FREE_TEXT.TITLE'
    );
    expect(wrapper.find('[data-test="canned-home"]').exists()).toBe(true);
    expect(wrapper.findComponent({ name: 'TabBar' }).exists()).toBe(false);
  });

  it('shows WhatsApp templates on the WhatsApp route', () => {
    route.name = 'outbound_whatsapp_templates_index';
    const wrapper = mountComponent();

    expect(wrapper.get('section').attributes('data-title')).toBe(
      'OUTBOUND_WORKSPACE.TEMPLATES.WHATSAPP.TITLE'
    );
    expect(wrapper.find('[data-test="canned-home"]').exists()).toBe(false);
    expect(wrapper.text()).toContain(
      'OUTBOUND_WORKSPACE.TEMPLATES.WHATSAPP.EMPTY_TITLE'
    );
  });
});
