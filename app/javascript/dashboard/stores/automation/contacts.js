import { defineStore } from 'pinia';
import AutomationsAPI from 'dashboard/api/automation';

// The backend answers a saved-ids lookup for at most this many ids at a time.
const LOOKUP_CHUNK_SIZE = 100;

const toId = value => {
  const id = Number(value);
  return Number.isSafeInteger(id) && id > 0 ? id : null;
};

// One contact as the "Contact" condition picker shows it: the name, with the
// phone number (or the e-mail) underneath.
export const toContactOption = contact => {
  const id = Number(contact.id);
  const name =
    contact.name || contact.phone_number || contact.email || `№ ${id}`;
  const description = contact.phone_number || contact.email || '';

  return {
    id,
    name,
    description: description === name ? '' : description,
  };
};

const chunk = (items, size) => {
  const chunks = [];
  for (let index = 0; index < items.length; index += size) {
    chunks.push(items.slice(index, index + size));
  }
  return chunks;
};

export const useAutomationContactsStore = defineStore('automationContacts', {
  state: () => ({
    // Contacts seen so far (found by search or named by saved ids), by id.
    known: {},
    // Saved ids that the server did not know: the contact was deleted.
    deletedIds: [],
  }),

  getters: {
    knownOptions: state => Object.values(state.known),
  },

  actions: {
    remember(options) {
      options.forEach(option => {
        this.known[option.id] = option;
      });
      this.deletedIds = this.deletedIds.filter(id => !this.known[id]);
    },

    // One page of contacts found by name or phone, most recently active first.
    async search(query = '', page = 1) {
      const { data } = await AutomationsAPI.contactOptions({
        q: query,
        page,
      });
      const options = (data?.payload || []).map(toContactOption);
      this.remember(options);

      return { options, hasMore: Boolean(data?.meta?.has_more) };
    },

    // Names the contacts a saved rule lists. An id the server does not return
    // belongs to a deleted contact. When a request fails nothing is concluded:
    // those contacts stay unnamed rather than being shown as deleted.
    async loadByIds(ids) {
      const wanted = [...new Set((ids || []).map(toId).filter(Boolean))].filter(
        id => !this.known[id]
      );

      await Promise.all(
        chunk(wanted, LOOKUP_CHUNK_SIZE).map(async idsChunk => {
          try {
            const { data } = await AutomationsAPI.contactOptions({
              ids: idsChunk,
            });
            const options = (data?.payload || []).map(toContactOption);
            this.remember(options);

            const found = new Set(options.map(option => option.id));
            const missing = idsChunk.filter(id => !found.has(id));
            this.deletedIds = [...new Set([...this.deletedIds, ...missing])];
          } catch (_error) {
            // Left unnamed on purpose, see above.
          }
        })
      );
    },
  },
});
