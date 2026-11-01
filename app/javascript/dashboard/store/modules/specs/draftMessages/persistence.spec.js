import { createStore } from 'vuex';
import draftMessages from '../../draftMessages';
import { LocalStorage } from 'shared/helpers/localStorage';
import { LOCAL_STORAGE_KEYS } from 'dashboard/constants/localStorage';

const key = 'draft-42-reply';
const context = {
  accountId: 1,
  userId: 7,
  conversationId: 42,
  replyType: 'reply',
};
const aiIdentity = { suggestionRequestId: 'generated-request' };
const boot = () =>
  createStore({
    modules: {
      drafts: {
        ...draftMessages,
        state: () => ({
          records: LocalStorage.get(LOCAL_STORAGE_KEYS.DRAFT_MESSAGES) || {},
          replyEditorMode: 'reply',
        }),
      },
    },
  });

describe('draft record persistence', () => {
  afterEach(() => {
    vi.restoreAllMocks();
    LocalStorage.remove(LOCAL_STORAGE_KEYS.DRAFT_MESSAGES);
  });

  it('restores the edited text and minimal identity from the same persisted record after a fresh store boot', async () => {
    const store = boot();
    await store.dispatch('drafts/set', {
      key,
      message: 'Edited reply',
      context,
      aiIdentity,
    });
    expect(
      JSON.parse(localStorage.getItem(LOCAL_STORAGE_KEYS.DRAFT_MESSAGES))[key]
    ).toEqual({
      message: 'Edited reply',
      context,
      aiIdentity,
    });
    const reloaded = boot();
    expect(reloaded.getters['drafts/get'](key)).toBe('Edited reply');
    expect(reloaded.getters['drafts/getRecord'](key)).toEqual({
      message: 'Edited reply',
      context,
      aiIdentity,
    });
  });

  it('keeps both previous text and identity when the storage write fails and permits an atomic retry', async () => {
    const store = boot();
    await store.dispatch('drafts/set', {
      key,
      message: 'Before edit',
      context,
      aiIdentity,
    });
    const original = Storage.prototype.setItem;
    const fault = vi
      .spyOn(Storage.prototype, 'setItem')
      .mockImplementation(function storageWriteFault(name, value) {
        if (name === LOCAL_STORAGE_KEYS.DRAFT_MESSAGES)
          throw new Error('injected storage unavailable');
        return original.call(this, name, value);
      });
    await expect(
      store.dispatch('drafts/set', {
        key,
        message: 'After edit',
        context,
        aiIdentity,
      })
    ).rejects.toThrow('storage unavailable');
    expect(boot().getters['drafts/getRecord'](key)).toEqual({
      message: 'Before edit',
      context,
      aiIdentity,
    });
    expect(store.getters['drafts/getRecord'](key).message).toBe('Before edit');
    fault.mockRestore();
    await store.dispatch('drafts/set', {
      key,
      message: 'After edit',
      context,
      aiIdentity,
    });
    expect(boot().getters['drafts/getRecord'](key)).toEqual({
      message: 'After edit',
      context,
      aiIdentity,
    });
  });

  it('reads legacy strings as human drafts and never infers an AI identity from their text', async () => {
    LocalStorage.set(LOCAL_STORAGE_KEYS.DRAFT_MESSAGES, {
      [key]: 'Text copied from an AI draft',
    });
    const store = boot();
    expect(store.getters['drafts/get'](key)).toBe(
      'Text copied from an AI draft'
    );
    expect(store.getters['drafts/getRecord'](key)).toEqual({
      message: 'Text copied from an AI draft',
    });
    await store.dispatch('drafts/set', {
      key,
      message: 'A human reply',
      context,
    });
    expect(boot().getters['drafts/getRecord'](key).aiIdentity).toBeNull();
  });

  it('replacing a previous AI draft with human text and deleting it cannot leave an identity behind', async () => {
    const store = boot();
    await store.dispatch('drafts/set', {
      key,
      message: 'AI draft',
      context,
      aiIdentity,
    });
    await store.dispatch('drafts/set', {
      key,
      message: 'Human reply',
      context,
    });
    expect(boot().getters['drafts/getRecord'](key).aiIdentity).toBeNull();
    await store.dispatch('drafts/delete', { key });
    expect(boot().getters['drafts/getRecord'](key)).toBeNull();
    expect(boot().getters['drafts/get'](key)).toBe('');
  });
});
