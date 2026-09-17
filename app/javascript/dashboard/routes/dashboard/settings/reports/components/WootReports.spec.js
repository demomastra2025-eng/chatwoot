import { describe, expect, it, vi } from 'vitest';

import WootReports from './WootReports.vue';

describe('WootReports item provider contract', () => {
  it('uses supplied items instead of a legacy Vuex getter', () => {
    const items = [{ id: 1, name: 'Support' }];

    expect(
      WootReports.computed.filterItemsList.call({
        items,
        getterKey: '',
        $store: { getters: {} },
      })
    ).toBe(items);
  });

  it('uses the supplied fetch function instead of a legacy Vuex action', () => {
    const fetchItems = vi.fn();
    const dispatch = vi.fn();

    WootReports.mounted.call({
      fetchItems,
      actionKey: '',
      $store: { dispatch },
    });

    expect(fetchItems).toHaveBeenCalledOnce();
    expect(dispatch).not.toHaveBeenCalled();
  });
});
