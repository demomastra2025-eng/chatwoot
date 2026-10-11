/* eslint-disable vue/one-component-per-file */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

import CreateAgentDialog from './CreateAgentDialog.vue';

const mocks = vi.hoisted(() => ({
  dispatch: vi.fn(),
  useAlert: vi.fn(),
  updateAvatar: vi.fn(),
  close: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key, te: () => true }),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: mocks.dispatch }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => mocks.useAlert(...args),
}));

vi.mock('dashboard/api/captain/assistant', () => ({
  default: { updateAvatar: (...args) => mocks.updateAvatar(...args) },
}));

// The tests emit the dialog and avatar events themselves, so these stubs
// declare no events of their own.
const DialogStub = defineComponent({
  name: 'DialogStub',
  setup(_props, { slots, expose }) {
    expose({ open: vi.fn(), close: mocks.close });
    return () => h('div', slots.default?.());
  },
});

const fieldStub = (name, tag) =>
  defineComponent({
    name,
    props: {
      modelValue: { type: String, default: '' },
      label: { type: String, default: '' },
      message: { type: String, default: '' },
      messageType: { type: String, default: 'info' },
      maxLength: { type: Number, default: 0 },
    },
    emits: ['update:modelValue'],
    setup(props, { emit }) {
      return () =>
        h(tag, {
          value: props.modelValue,
          'data-label': props.label,
          'data-message': props.message,
          'data-message-type': props.messageType,
          'data-max-length': props.maxLength,
          onInput: event => emit('update:modelValue', event.target.value),
        });
    },
  });

const AvatarStub = defineComponent({
  name: 'Avatar',
  props: {
    src: { type: String, default: '' },
    name: { type: String, default: '' },
    size: { type: Number, default: 32 },
    allowUpload: Boolean,
  },
  setup(props) {
    return () =>
      h('span', {
        'data-src': props.src,
        'data-name': props.name,
        'data-size': props.size,
        'data-allow-upload': props.allowUpload,
      });
  },
});

const mountDialog = () =>
  mount(CreateAgentDialog, {
    global: {
      stubs: {
        Dialog: DialogStub,
        Input: fieldStub('Input', 'input'),
        TextArea: fieldStub('TextArea', 'textarea'),
        Avatar: AvatarStub,
      },
    },
  });

const nameField = wrapper => wrapper.findComponent({ name: 'Input' });
const descriptionField = wrapper => wrapper.findComponent({ name: 'TextArea' });

const fillForm = async (wrapper, { name, description }) => {
  await nameField(wrapper).setValue(name);
  await descriptionField(wrapper).setValue(description);
};

const submit = async wrapper => {
  wrapper.findComponent({ name: 'DialogStub' }).vm.$emit('confirm');
  await flushPromises();
};

const expectedPayload = {
  assistant: {
    name: 'Администратор',
    routing_description: 'Записывает на приём и отвечает о ценах',
    usage_mode: 'external_agent',
    description: 'CAPTAIN.ASSISTANTS.CREATE.DEFAULT_INSTRUCTION.EXTERNAL_AGENT',
    config: {
      tool_access: {
        agent: { enabled: true, tool_ids: ['faq_lookup', 'handoff'] },
      },
    },
  },
};

describe('CreateAgentDialog', () => {
  beforeEach(() => {
    mocks.dispatch.mockReset();
    mocks.useAlert.mockReset();
    mocks.updateAvatar.mockReset();
    mocks.close.mockReset();
  });

  it('asks for a name, a description and an optional avatar', () => {
    const wrapper = mountDialog();

    expect(nameField(wrapper).props('label')).toBe(
      'CAPTAIN.GALLERY.CREATE.NAME_LABEL'
    );
    expect(descriptionField(wrapper).props()).toMatchObject({
      label: 'CAPTAIN.GALLERY.CREATE.DESCRIPTION_LABEL',
      maxLength: 400,
    });
    expect(wrapper.findComponent({ name: 'Avatar' }).props()).toMatchObject({
      size: 72,
      allowUpload: true,
    });
  });

  it('shows the field errors only after the first submit attempt', async () => {
    const wrapper = mountDialog();

    expect(nameField(wrapper).props('message')).toBe('');
    expect(descriptionField(wrapper).props('message')).toBe('');

    await submit(wrapper);

    expect(mocks.dispatch).not.toHaveBeenCalled();
    expect(nameField(wrapper).props()).toMatchObject({
      message: 'CAPTAIN.GALLERY.CREATE.NAME_ERROR',
      messageType: 'error',
    });
    expect(descriptionField(wrapper).props()).toMatchObject({
      message: 'CAPTAIN.GALLERY.CREATE.DESCRIPTION_ERROR_REQUIRED',
      messageType: 'error',
    });
  });

  it('does not create an agent without a description', async () => {
    const wrapper = mountDialog();
    await fillForm(wrapper, { name: 'Администратор', description: '   ' });

    await submit(wrapper);

    expect(mocks.dispatch).not.toHaveBeenCalled();
    expect(nameField(wrapper).props('message')).toBe('');
  });

  it('does not create an agent with a description over 400 characters', async () => {
    const wrapper = mountDialog();
    await fillForm(wrapper, {
      name: 'Администратор',
      description: 'а'.repeat(401),
    });

    await submit(wrapper);

    expect(mocks.dispatch).not.toHaveBeenCalled();
    expect(descriptionField(wrapper).props('message')).toBe(
      'CAPTAIN.GALLERY.CREATE.DESCRIPTION_ERROR_MAX'
    );
  });

  it('creates an AI agent with the default settings only', async () => {
    const created = { id: 77, name: 'Администратор' };
    mocks.dispatch.mockResolvedValueOnce(created);
    const wrapper = mountDialog();
    await fillForm(wrapper, {
      name: '  Администратор ',
      description: ' Записывает на приём и отвечает о ценах ',
    });

    await submit(wrapper);

    expect(mocks.dispatch).toHaveBeenCalledTimes(1);
    expect(mocks.dispatch).toHaveBeenCalledWith(
      'captainAssistants/create',
      expectedPayload
    );
    const [, payload] = mocks.dispatch.mock.calls[0];
    expect(Object.keys(payload.assistant.config)).toEqual(['tool_access']);
    expect(mocks.updateAvatar).not.toHaveBeenCalled();
    expect(mocks.useAlert).toHaveBeenCalledWith(
      'CAPTAIN.GALLERY.CREATE.SUCCESS'
    );
    expect(mocks.close).toHaveBeenCalledTimes(1);
    expect(wrapper.emitted('created')).toEqual([[created]]);
  });

  it('uploads the chosen avatar once the agent exists', async () => {
    const created = { id: 77, name: 'Администратор' };
    const refreshed = { ...created, avatar_url: 'https://example.com/a.png' };
    const file = new File(['avatar'], 'avatar.png', { type: 'image/png' });
    mocks.dispatch
      .mockResolvedValueOnce(created)
      .mockResolvedValueOnce(refreshed);
    mocks.updateAvatar.mockResolvedValueOnce({});
    const wrapper = mountDialog();
    await fillForm(wrapper, {
      name: 'Администратор',
      description: 'Записывает на приём и отвечает о ценах',
    });
    wrapper
      .findComponent({ name: 'Avatar' })
      .vm.$emit('upload', { file, url: 'blob:avatar' });

    await submit(wrapper);

    expect(mocks.updateAvatar).toHaveBeenCalledWith(77, file);
    expect(mocks.dispatch).toHaveBeenLastCalledWith(
      'captainAssistants/show',
      77
    );
    expect(wrapper.emitted('created')).toEqual([[refreshed]]);
  });

  it('still opens the new agent when the avatar upload fails', async () => {
    const created = { id: 77, name: 'Администратор' };
    const file = new File(['avatar'], 'avatar.png', { type: 'image/png' });
    mocks.dispatch.mockResolvedValueOnce(created);
    mocks.updateAvatar.mockRejectedValueOnce(new Error('too large'));
    const wrapper = mountDialog();
    await fillForm(wrapper, {
      name: 'Администратор',
      description: 'Записывает на приём и отвечает о ценах',
    });
    wrapper
      .findComponent({ name: 'Avatar' })
      .vm.$emit('upload', { file, url: 'blob:avatar' });

    await submit(wrapper);

    expect(mocks.useAlert).toHaveBeenCalledWith(
      'CAPTAIN.GALLERY.CREATE.AVATAR_ERROR'
    );
    expect(wrapper.emitted('created')).toEqual([[created]]);
  });

  it('keeps the dialog open when the agent cannot be created', async () => {
    mocks.dispatch.mockRejectedValueOnce(new Error('Имя уже занято'));
    const wrapper = mountDialog();
    await fillForm(wrapper, {
      name: 'Администратор',
      description: 'Записывает на приём и отвечает о ценах',
    });

    await submit(wrapper);

    expect(mocks.useAlert).toHaveBeenCalledWith('Имя уже занято');
    expect(mocks.close).not.toHaveBeenCalled();
    expect(wrapper.emitted('created')).toBeUndefined();
  });
});
