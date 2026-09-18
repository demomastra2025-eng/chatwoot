import { shallowMount } from '@vue/test-utils';
import { ref } from 'vue';

import Button from 'dashboard/components-next/button/Button.vue';
import OutboundTemplatesPage from './OutboundTemplatesPage.vue';

const { routeState, permissionState } = vi.hoisted(() => ({
  routeState: {
    name: 'outbound_templates_index',
    params: { accountId: '1' },
    query: {},
  },
  permissionState: { canManage: true },
}));

const outboundInboxes = ref([]);

vi.mock('vue-router', async importOriginal => {
  const actual = await importOriginal();
  return {
    ...actual,
    useRoute: () => routeState,
  };
});

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables/store', () => ({
  useStoreGetters: () => ({
    getSortedCannedResponses: ref(() => []),
  }),
  useMapGetter: key =>
    key === 'inboxes/getOutboundCampaignInboxes'
      ? outboundInboxes
      : ref(() => []),
}));

vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({ checkPermissions: () => permissionState.canManage }),
}));

const mountComponent = () =>
  shallowMount(OutboundTemplatesPage, {
    global: {
      stubs: {
        OutboundWorkspaceLayout: {
          props: ['title', 'description'],
          template:
            '<section :data-title="title" :data-description="description"><slot name="tabs" /><slot /></section>',
        },
        Button: true,
        ComboBox: true,
        CannedHome: true,
        WhatsAppTemplatesPage: true,
      },
    },
  });

describe('OutboundTemplatesPage', () => {
  beforeEach(() => {
    routeState.name = 'outbound_templates_index';
    routeState.params = { accountId: '1' };
    routeState.query = {};
    outboundInboxes.value = [];
    permissionState.canManage = true;
  });

  it('uses a dedicated title for quick replies', () => {
    const wrapper = mountComponent();

    expect(wrapper.find('section').attributes('data-title')).toBe(
      'OUTBOUND_WORKSPACE.TEMPLATES.FREE_TEXT.TITLE'
    );
    expect(wrapper.find('section').attributes('data-description')).toBe(
      'OUTBOUND_WORKSPACE.TEMPLATES.FREE_TEXT.DESCRIPTION'
    );
  });

  it('uses a dedicated title for WhatsApp templates', () => {
    routeState.name = 'outbound_whatsapp_templates_index';

    const wrapper = mountComponent();

    expect(wrapper.find('section').attributes('data-title')).toBe(
      'OUTBOUND_WORKSPACE.TEMPLATES.WHATSAPP.TITLE'
    );
  });

  it('does not render a free-text/WhatsApp switcher on either route', () => {
    expect(mountComponent().findComponent({ name: 'TabBar' }).exists()).toBe(
      false
    );

    routeState.name = 'outbound_whatsapp_templates_index';
    expect(mountComponent().findComponent({ name: 'TabBar' }).exists()).toBe(
      false
    );
  });

  it('places WhatsApp actions beside the selected channel', async () => {
    routeState.name = 'outbound_whatsapp_templates_index';
    outboundInboxes.value = [
      {
        id: 7,
        name: 'WhatsApp Cloud',
        channel_type: 'Channel::Whatsapp',
        message_templates: [],
      },
    ];

    const wrapper = mountComponent();
    await wrapper.vm.$nextTick();

    const buttons = wrapper.findAllComponents(Button);
    expect(buttons).toHaveLength(2);
    expect(buttons[0].props('label')).toBe('');
    expect(buttons[0].props('icon')).toBe('i-lucide-refresh-cw');
    expect(buttons[1].props('label')).toBe('Create template');
  });

  it('hides WhatsApp management actions from regular agents', async () => {
    routeState.name = 'outbound_whatsapp_templates_index';
    permissionState.canManage = false;
    outboundInboxes.value = [
      {
        id: 7,
        name: 'WhatsApp Cloud',
        channel_type: 'Channel::Whatsapp',
        message_templates: [],
      },
    ];

    const wrapper = mountComponent();
    await wrapper.vm.$nextTick();

    expect(wrapper.findAllComponents(Button)).toHaveLength(0);
  });
});
