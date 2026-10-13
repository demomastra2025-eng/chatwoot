import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

import { toContactOption, useAutomationContactsStore } from './contacts';

const { contactOptionsMock } = vi.hoisted(() => ({
  contactOptionsMock: vi.fn(),
}));

vi.mock('dashboard/api/automation', () => ({
  default: { contactOptions: contactOptionsMock },
}));

describe('toContactOption', () => {
  it('shows the phone number under the name', () => {
    expect(
      toContactOption({ id: 7, name: 'Айгерим', phone_number: '+77011234567' })
    ).toEqual({ id: 7, name: 'Айгерим', description: '+77011234567' });
  });

  it('falls back to the e-mail, then to nothing', () => {
    expect(
      toContactOption({ id: 7, name: 'Берик', email: 'berik@example.com' })
    ).toEqual({ id: 7, name: 'Берик', description: 'berik@example.com' });
    expect(toContactOption({ id: 7, name: 'Берик' })).toEqual({
      id: 7,
      name: 'Берик',
      description: '',
    });
  });

  it('does not repeat the name as its own description', () => {
    expect(
      toContactOption({
        id: 7,
        name: '+77011234567',
        phone_number: '+77011234567',
      })
    ).toEqual({ id: 7, name: '+77011234567', description: '' });
  });

  it('names a contact without any details by its number', () => {
    expect(toContactOption({ id: 7 })).toEqual({
      id: 7,
      name: '№ 7',
      description: '',
    });
  });
});

describe('useAutomationContactsStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    vi.clearAllMocks();
  });

  describe('search', () => {
    it('asks the server for a page and remembers what it found', async () => {
      contactOptionsMock.mockResolvedValue({
        data: {
          payload: [
            { id: 1, name: 'Айгерим', phone_number: '+77011234567' },
            { id: 2, name: 'Берик', phone_number: null },
          ],
          meta: { has_more: true, current_page: 2 },
        },
      });
      const store = useAutomationContactsStore();

      const result = await store.search('ай', 2);

      expect(contactOptionsMock).toHaveBeenCalledWith({ q: 'ай', page: 2 });
      expect(result).toEqual({
        options: [
          { id: 1, name: 'Айгерим', description: '+77011234567' },
          { id: 2, name: 'Берик', description: '' },
        ],
        hasMore: true,
      });
      expect(store.knownOptions.map(option => option.id)).toEqual([1, 2]);
    });

    it('starts from the first page without a query', async () => {
      contactOptionsMock.mockResolvedValue({ data: { payload: [], meta: {} } });
      const store = useAutomationContactsStore();

      const result = await store.search();

      expect(contactOptionsMock).toHaveBeenCalledWith({ q: '', page: 1 });
      expect(result).toEqual({ options: [], hasMore: false });
    });

    it('lets the caller handle a failed request', async () => {
      const error = new Error('Network Error');
      contactOptionsMock.mockRejectedValue(error);
      const store = useAutomationContactsStore();

      await expect(store.search('x')).rejects.toBe(error);

      expect(store.knownOptions).toEqual([]);
    });
  });

  describe('loadByIds', () => {
    it('names the contacts a saved rule lists and marks the others deleted', async () => {
      contactOptionsMock.mockResolvedValue({
        data: { payload: [{ id: 1, name: 'Айгерим' }] },
      });
      const store = useAutomationContactsStore();

      await store.loadByIds([1, '2', 1]);

      expect(contactOptionsMock).toHaveBeenCalledTimes(1);
      expect(contactOptionsMock).toHaveBeenCalledWith({ ids: [1, 2] });
      expect(store.knownOptions).toEqual([
        { id: 1, name: 'Айгерим', description: '' },
      ]);
      expect(store.deletedIds).toEqual([2]);
    });

    it('does not ask again for contacts it already knows', async () => {
      const store = useAutomationContactsStore();
      store.remember([{ id: 1, name: 'Айгерим', description: '' }]);

      await store.loadByIds([1]);

      expect(contactOptionsMock).not.toHaveBeenCalled();
    });

    it('ignores values that are not contact ids', async () => {
      const store = useAutomationContactsStore();

      await store.loadByIds([null, 'abc', 0, -3, 1.5, undefined]);
      await store.loadByIds(undefined);

      expect(contactOptionsMock).not.toHaveBeenCalled();
    });

    it('asks for at most a hundred ids at a time', async () => {
      contactOptionsMock.mockResolvedValue({ data: { payload: [] } });
      const store = useAutomationContactsStore();
      const ids = Array.from({ length: 230 }, (_, index) => index + 1);

      await store.loadByIds(ids);

      expect(contactOptionsMock).toHaveBeenCalledTimes(3);
      expect(
        contactOptionsMock.mock.calls.map(([params]) => params.ids.length)
      ).toEqual([100, 100, 30]);
      expect(store.deletedIds).toHaveLength(230);
    });

    it('does not call a contact deleted when the request fails', async () => {
      contactOptionsMock.mockRejectedValue(new Error('Network Error'));
      const store = useAutomationContactsStore();

      await expect(store.loadByIds([1, 2])).resolves.toBeUndefined();

      expect(store.deletedIds).toEqual([]);
      expect(store.knownOptions).toEqual([]);
    });

    it('forgets that a contact was deleted once it is seen again', async () => {
      contactOptionsMock.mockResolvedValue({ data: { payload: [] } });
      const store = useAutomationContactsStore();
      await store.loadByIds([5]);

      expect(store.deletedIds).toEqual([5]);

      store.remember([{ id: 5, name: 'Back', description: '' }]);

      expect(store.deletedIds).toEqual([]);
    });
  });
});
