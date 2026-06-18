import { flushPromises, shallowMount } from '@vue/test-utils';

import WhatsAppFlowsPage from './WhatsAppFlowsPage.vue';

const dispatchMock = vi.hoisted(() => vi.fn());
const alertMock = vi.hoisted(() => vi.fn());
const flowState = vi.hoisted(() => ({ flows: [] }));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params = {}) => (params.flow ? `${key}:${params.flow}` : key),
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => alertMock(...args),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({
    dispatch: dispatchMock,
    getters: {
      'inboxes/getWhatsAppFlows': () => flowState.flows,
    },
  }),
}));

const dialogStub = {
  template: '<div><slot /></div>',
  methods: {
    open() {},
    close() {
      this.$emit('close');
    },
  },
};

const buildWrapper = () =>
  shallowMount(WhatsAppFlowsPage, {
    props: {
      inbox: { id: 24, name: 'WhatsApp Cloud' },
    },
    global: {
      stubs: {
        SettingsFieldSection: { template: '<section><slot /></section>' },
        Button: { template: '<button><slot /></button>' },
        Dialog: dialogStub,
        Input: true,
        Select: true,
        TextArea: true,
      },
    },
  });

describe('WhatsAppFlowsPage', () => {
  beforeEach(() => {
    flowState.flows = [
      {
        id: 1,
        provider_flow_id: 'flow-123',
        name: 'lead_qualification',
        title: 'Lead qualification',
        display_title: 'Lead qualification',
        status: 'published',
        mode: 'published',
        category: 'sales',
        flow_json: { screens: [{ id: 'WELCOME' }] },
        metadata: { flow_cta: 'Open form' },
        updated_at: '2026-06-17T10:00:00Z',
      },
    ];
    alertMock.mockReset();
    dispatchMock.mockReset();
    dispatchMock.mockResolvedValue({ id: 99 });
  });

  it('loads inbox-scoped WhatsApp Flows on mount', async () => {
    buildWrapper();
    await flushPromises();

    expect(dispatchMock).toHaveBeenCalledWith('inboxes/fetchWhatsAppFlows', 24);
  });

  it('creates a Flow with parsed JSON and CTA metadata', async () => {
    const wrapper = buildWrapper();
    await flushPromises();
    dispatchMock.mockClear();

    wrapper.vm.form.providerFlowId = 'flow-456';
    wrapper.vm.form.name = 'follow_up';
    wrapper.vm.form.title = 'Follow up form';
    wrapper.vm.form.status = 'published';
    wrapper.vm.form.mode = 'published';
    wrapper.vm.form.category = 'sales';
    wrapper.vm.form.cta = 'Start';
    wrapper.vm.form.flowJsonText = '{"screens":[{"id":"WELCOME"}]}';

    await wrapper.vm.saveFlow();
    await flushPromises();

    expect(dispatchMock).toHaveBeenCalledWith('inboxes/createWhatsAppFlow', {
      inboxId: 24,
      flow: expect.objectContaining({
        provider_flow_id: 'flow-456',
        name: 'follow_up',
        title: 'Follow up form',
        status: 'published',
        category: 'sales',
        mode: 'published',
        flow_json: { screens: [{ id: 'WELCOME' }] },
        metadata: { flow_cta: 'Start' },
      }),
    });
  });

  it('updates an existing Flow without dropping existing metadata', async () => {
    const wrapper = buildWrapper();
    await flushPromises();
    dispatchMock.mockClear();

    wrapper.vm.openEditDialog(flowState.flows[0]);
    wrapper.vm.form.cta = 'Open updated form';

    await wrapper.vm.saveFlow();
    await flushPromises();

    expect(dispatchMock).toHaveBeenCalledWith('inboxes/updateWhatsAppFlow', {
      inboxId: 24,
      flowId: 1,
      flow: expect.objectContaining({
        metadata: { flow_cta: 'Open updated form' },
      }),
    });
  });

  it('does not submit invalid JSON', async () => {
    const wrapper = buildWrapper();
    await flushPromises();
    dispatchMock.mockClear();

    wrapper.vm.form.name = 'broken_flow';
    wrapper.vm.form.status = 'published';
    wrapper.vm.form.flowJsonText = '[]';

    await wrapper.vm.saveFlow();

    expect(dispatchMock).not.toHaveBeenCalled();
    expect(alertMock).toHaveBeenCalledWith(
      'WHATSAPP_FLOWS.SETTINGS.ERRORS.FLOW_JSON_OBJECT'
    );
  });

  it('deletes a Flow from the inbox registry', async () => {
    const wrapper = buildWrapper();
    await flushPromises();
    dispatchMock.mockClear();

    wrapper.vm.flowPendingDelete = flowState.flows[0];
    await wrapper.vm.deleteFlow();
    await flushPromises();

    expect(dispatchMock).toHaveBeenCalledWith('inboxes/deleteWhatsAppFlow', {
      inboxId: 24,
      flowId: 1,
    });
  });
});
