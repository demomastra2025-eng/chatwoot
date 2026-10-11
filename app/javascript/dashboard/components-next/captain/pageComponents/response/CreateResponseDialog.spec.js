import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import { ref } from 'vue';
import CreateResponseDialog from './CreateResponseDialog.vue';
import ResponseForm from './ResponseForm.vue';

const mocks = vi.hoisted(() => ({
  dispatch: vi.fn(),
  close: vi.fn(),
  alert: vi.fn(),
}));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { assistantId: '2' } }),
}));
vi.mock('dashboard/composables', () => ({ useAlert: mocks.alert }));
vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: mocks.dispatch }),
  useMapGetter: () => ref([]),
}));

const mountDialog = (props = {}) =>
  mount(CreateResponseDialog, {
    props: { type: 'edit', selectedResponse: { id: 7 }, ...props },
    global: {
      mocks: { $t: key => key },
      stubs: {
        Dialog: {
          setup(_props, { expose }) {
            expose({ close: mocks.close });
          },
          template: '<div><slot /></div>',
        },
        ResponseForm: {
          props: ['mode', 'response', 'assistantId'],
          emits: ['submit', 'cancel'],
          template: '<div />',
        },
      },
    },
  });

const submit = async (wrapper, details) => {
  wrapper.getComponent(ResponseForm).vm.$emit('submit', details);
  await flushPromises();
};

describe('response dialog access preservation', () => {
  beforeEach(() => {
    mocks.dispatch.mockReset();
    mocks.dispatch.mockResolvedValue({});
    mocks.close.mockReset();
  });

  it('does not assign the page agent when submitting a content-only edit', async () => {
    const wrapper = mountDialog();
    await submit(wrapper, { question: 'Question', answer: 'Updated answer' });

    expect(mocks.dispatch).toHaveBeenCalledWith('captainResponses/update', {
      id: 7,
      question: 'Question',
      answer: 'Updated answer',
    });
    expect(mocks.close).toHaveBeenCalledOnce();
  });

  it.each(['edit', 'create'])(
    'keeps the chosen access instead of adding the page agent on %s',
    async type => {
      const wrapper = mountDialog({ type });
      const details = {
        question: 'Question',
        answer: 'Answer',
        visibility: 'personal',
        assistant_id: null,
        allowed_assistant_ids: [4],
      };
      await submit(wrapper, details);

      expect(mocks.dispatch).toHaveBeenCalledWith(
        `captainResponses/${type === 'edit' ? 'update' : 'create'}`,
        type === 'edit' ? { id: 7, ...details } : details
      );
    }
  );
});
