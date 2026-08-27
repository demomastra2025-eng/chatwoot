/* eslint-disable vue/one-component-per-file */
import { defineComponent, h } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

const getMock = vi.fn();
const deleteEventMock = vi.fn();
const clearMock = vi.fn();
const alertMock = vi.fn();

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key, locale: { value: 'en' } }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => alertMock(...args),
}));

vi.mock('dashboard/api/captain/observability', () => ({
  default: {
    get: getMock,
    deleteEvent: deleteEventMock,
    clear: clearMock,
  },
}));

vi.mock('dashboard/components-next/button/Button.vue', () => ({
  default: defineComponent({
    props: {
      label: { type: String, default: '' },
      icon: { type: String, default: '' },
    },
    emits: ['click'],
    setup(props, { emit }) {
      return () =>
        h(
          'button',
          { class: props.icon, onClick: () => emit('click') },
          props.label || props.icon
        );
    },
  }),
}));

vi.mock('dashboard/components-next/captain/PageLayout.vue', () => ({
  default: defineComponent({
    props: {
      buttonLabel: { type: String, default: '' },
      currentPage: { type: Number, default: 1 },
      isEmpty: Boolean,
    },
    emits: ['click', 'update:currentPage'],
    setup(props, { emit, slots }) {
      return () =>
        h('main', [
          props.buttonLabel
            ? h(
                'button',
                { class: 'clear-logs', onClick: () => emit('click') },
                props.buttonLabel
              )
            : null,
          slots.search?.(),
          h(
            'button',
            {
              class: 'page-next',
              onClick: () => emit('update:currentPage', props.currentPage + 1),
            },
            'next'
          ),
          props.isEmpty ? slots.emptyState?.() : slots.body?.(),
        ]);
    },
  }),
}));

vi.mock('dashboard/components-next/dialog/Dialog.vue', () => ({
  default: defineComponent({
    props: { title: { type: String, default: '' } },
    emits: ['confirm'],
    setup(props, { emit, expose, slots }) {
      const open = vi.fn();
      const close = vi.fn();
      expose({ open, close });
      return () =>
        h('section', { class: 'dialog' }, [
          props.title,
          slots.default?.(),
          h(
            'button',
            { class: 'dialog-confirm', onClick: () => emit('confirm') },
            'confirm'
          ),
        ]);
    },
  }),
}));

vi.mock('./EventDetailsDialog.vue', () => ({
  default: defineComponent({
    setup(_props, { expose }) {
      expose({ open: vi.fn() });
      return () => h('div');
    },
  }),
}));

const { default: ObservabilityIndex } = await import('./Index.vue');

const event = {
  id: 17,
  event_name: 'llm.chat.complete',
  feature: 'assistant',
  status: 'completed',
  model: 'openai/gpt-5',
  created_at: '2026-08-26T10:00:00Z',
};

const response = payload => ({
  data: {
    payload,
    meta: { count: payload.length, current_page: 1, per_page: 25 },
  },
});

const deferred = () => {
  let resolve;
  const promise = new Promise(resolvePromise => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
};

describe('AI Agent logs', () => {
  beforeEach(() => {
    getMock.mockReset();
    getMock.mockResolvedValue(response([event]));
    deleteEventMock.mockReset();
    deleteEventMock.mockResolvedValue({});
    clearMock.mockReset();
    clearMock.mockResolvedValue({});
    alertMock.mockReset();
  });

  it('loads only AI Agent events and renders a compact list', async () => {
    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    expect(getMock).toHaveBeenCalledWith({
      feature: 'assistant',
      page: 1,
      per_page: 25,
    });
    expect(wrapper.text()).toContain('Llm Chat Complete');
    expect(wrapper.text()).toContain('openai/gpt-5');
  });

  it('deletes one event and reloads the list', async () => {
    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    await wrapper.find('button.i-lucide-trash-2').trigger('click');
    await wrapper.findAll('.dialog-confirm')[0].trigger('click');
    await flushPromises();

    expect(deleteEventMock).toHaveBeenCalledWith(17);
    expect(getMock).toHaveBeenCalledTimes(2);
  });

  it('moves to the previous page after deleting its last event', async () => {
    getMock.mockResolvedValue({
      data: {
        payload: [event],
        meta: { count: 26, current_page: 2, per_page: 25 },
      },
    });
    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    await wrapper.find('.page-next').trigger('click');
    await flushPromises();
    await wrapper.find('button.i-lucide-trash-2').trigger('click');
    await wrapper.findAll('.dialog-confirm')[0].trigger('click');
    await flushPromises();

    expect(getMock).toHaveBeenLastCalledWith({
      feature: 'assistant',
      page: 1,
      per_page: 25,
    });
  });

  it('clears AI Agent logs and reloads the first page', async () => {
    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    await wrapper.find('.clear-logs').trigger('click');
    await wrapper.findAll('.dialog-confirm')[1].trigger('click');
    await flushPromises();

    expect(clearMock).toHaveBeenCalledOnce();
    expect(getMock).toHaveBeenLastCalledWith({
      feature: 'assistant',
      page: 1,
      per_page: 25,
    });
  });

  it('ignores an older refresh response after deleting an event', async () => {
    const wrapper = mount(ObservabilityIndex);
    await flushPromises();
    const staleRefresh = deferred();
    getMock.mockImplementationOnce(() => staleRefresh.promise);
    getMock.mockResolvedValueOnce(response([]));

    await wrapper.find('button.i-lucide-refresh-cw').trigger('click');
    await wrapper.find('button.i-lucide-trash-2').trigger('click');
    await wrapper.findAll('.dialog-confirm')[0].trigger('click');
    await flushPromises();

    staleRefresh.resolve(response([event]));
    await flushPromises();

    expect(wrapper.text()).not.toContain('Llm Chat Complete');
  });

  it('ignores an older refresh response after clearing events', async () => {
    const wrapper = mount(ObservabilityIndex);
    await flushPromises();
    const staleRefresh = deferred();
    getMock.mockImplementationOnce(() => staleRefresh.promise);
    getMock.mockResolvedValueOnce(response([]));

    await wrapper.find('button.i-lucide-refresh-cw').trigger('click');
    await wrapper.find('.clear-logs').trigger('click');
    await wrapper.findAll('.dialog-confirm')[1].trigger('click');
    await flushPromises();

    staleRefresh.resolve(response([event]));
    await flushPromises();

    expect(wrapper.text()).not.toContain('Llm Chat Complete');
  });

  it('clamps an empty out-of-range page to the last available page', async () => {
    const secondEvent = { ...event, id: 18, event_name: 'llm.tool.complete' };
    const fallbackEvent = { ...event, id: 19, event_name: 'llm.chat.fallback' };
    getMock
      .mockResolvedValueOnce(response([event]))
      .mockResolvedValueOnce({
        data: {
          payload: [event, secondEvent],
          meta: { count: 27, current_page: 2, per_page: 25 },
        },
      })
      .mockResolvedValueOnce({
        data: {
          payload: [],
          meta: { count: 25, current_page: 2, per_page: 25 },
        },
      })
      .mockResolvedValueOnce(response([fallbackEvent]));
    const wrapper = mount(ObservabilityIndex);
    await flushPromises();

    await wrapper.find('.page-next').trigger('click');
    await flushPromises();
    await wrapper.find('button.i-lucide-trash-2').trigger('click');
    await wrapper.findAll('.dialog-confirm')[0].trigger('click');
    await flushPromises();

    expect(getMock).toHaveBeenLastCalledWith({
      feature: 'assistant',
      page: 1,
      per_page: 25,
    });
    expect(wrapper.text()).toContain('Llm Chat Fallback');
  });
});
