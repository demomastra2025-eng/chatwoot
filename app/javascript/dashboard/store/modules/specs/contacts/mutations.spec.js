import types from '../../../mutation-types';
import Contacts from '../../contacts';
const { mutations } = Contacts;

describe('#mutations', () => {
  describe('#SET_CONTACTS', () => {
    it('set contact records', () => {
      const state = { records: {} };
      mutations[types.SET_CONTACTS](state, [
        { id: 2, name: 'contact2', email: 'contact2@one-link.kz' },
        { id: 1, name: 'contact1', email: 'contact1@one-link.kz' },
      ]);
      expect(state.records).toEqual({
        1: {
          id: 1,
          name: 'contact1',
          email: 'contact1@one-link.kz',
        },
        2: {
          id: 2,
          name: 'contact2',
          email: 'contact2@one-link.kz',
        },
      });
      expect(state.sortOrder).toEqual([2, 1]);
    });
  });

  describe('#SET_CONTACT_ITEM', () => {
    it('push contact data to the store', () => {
      const state = {
        records: {
          1: { id: 1, name: 'contact1', email: 'contact1@one-link.kz' },
        },
        sortOrder: [1],
      };
      mutations[types.SET_CONTACT_ITEM](state, {
        id: 2,
        name: 'contact2',
        email: 'contact2@one-link.kz',
      });
      expect(state.records).toEqual({
        1: { id: 1, name: 'contact1', email: 'contact1@one-link.kz' },
        2: { id: 2, name: 'contact2', email: 'contact2@one-link.kz' },
      });
      expect(state.sortOrder).toEqual([1, 2]);
    });
  });

  describe('#EDIT_CONTACT', () => {
    it('update contact', () => {
      const state = {
        records: {
          1: { id: 1, name: 'contact1', email: 'contact1@one-link.kz' },
        },
      };
      mutations[types.EDIT_CONTACT](state, {
        id: 1,
        name: 'contact2',
        email: 'contact2@one-link.kz',
      });
      expect(state.records).toEqual({
        1: { id: 1, name: 'contact2', email: 'contact2@one-link.kz' },
      });
    });
  });

  describe('#SET_CONTACT_FILTERS', () => {
    it('set contact filter', () => {
      const appliedFilters = [
        {
          attribute_key: 'name',
          filter_operator: 'equal_to',
          values: ['fayaz'],
          query_operator: 'and',
        },
      ];
      mutations[types.SET_CONTACT_FILTERS](appliedFilters);
      expect(appliedFilters).toEqual([
        {
          attribute_key: 'name',
          filter_operator: 'equal_to',
          values: ['fayaz'],
          query_operator: 'and',
        },
      ]);
    });
  });
  describe('#CLEAR_CONTACT_FILTERS', () => {
    it('clears applied contact filters', () => {
      const state = {
        appliedFilters: [
          {
            attribute_key: 'name',
            filter_operator: 'equal_to',
            values: ['fayaz'],
            query_operator: 'and',
          },
        ],
      };
      mutations[types.CLEAR_CONTACT_FILTERS](state);
      expect(state.appliedFilters).toEqual([]);
    });
  });
});
