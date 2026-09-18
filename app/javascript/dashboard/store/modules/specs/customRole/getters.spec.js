import { getters } from '../../customRole';
import { accessRoleCatalog, customRoleList } from './fixtures';

describe('#getters', () => {
  it('getCustomRoles', () => {
    const state = { records: customRoleList };
    expect(getters.getCustomRoles(state)).toEqual(customRoleList);
  });

  it('getAccessRoleCatalog', () => {
    const state = { accessRoleCatalog };
    expect(getters.getAccessRoleCatalog(state)).toEqual(accessRoleCatalog);
  });

  it('getUIFlags', () => {
    const state = {
      uiFlags: {
        fetchingList: true,
        creatingItem: false,
        updatingItem: false,
        deletingItem: false,
      },
    };
    expect(getters.getUIFlags(state)).toEqual({
      fetchingList: true,
      creatingItem: false,
      updatingItem: false,
      deletingItem: false,
    });
  });
});
