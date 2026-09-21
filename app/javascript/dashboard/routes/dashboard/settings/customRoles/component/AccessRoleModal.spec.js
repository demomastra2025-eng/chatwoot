import { flushPromises, mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import AccessRoleModal from './AccessRoleModal.vue';

const { dispatch, useAlert } = vi.hoisted(() => ({
  dispatch: vi.fn(),
  useAlert: vi.fn(),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch }),
}));

vi.mock('dashboard/composables', () => ({ useAlert }));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => {
      if (key === 'CUSTOM_ROLE.ACCESS_EDITOR.CLONE_NAME') {
        return `${params.name} copy`;
      }
      if (key === 'CUSTOM_ROLE.ACCESS_EDITOR.CLONE_DESCRIPTION') {
        return `Copy of ${params.name}`;
      }
      return key;
    },
  }),
}));

const resources = {
  contacts: ['view', 'create'],
};

const role = {
  id: 12,
  name: 'Support',
  description: 'Supports customers',
  lock_version: 4,
  grants: [
    {
      resource: 'contacts',
      capability: 'view',
      access_scope: 'team',
    },
  ],
};

const mountComponent = props =>
  mount(AccessRoleModal, {
    props: {
      resources,
      accessScopes: ['none', 'own', 'team', 'all'],
      ...props,
    },
    global: {
      mocks: { $t: key => key },
      stubs: {
        WootModalHeader: true,
        Button: {
          props: ['type', 'label', 'disabled'],
          emits: ['click'],
          template:
            '<button :type="type" :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
        },
      },
    },
  });

describe('AccessRoleModal', () => {
  beforeEach(() => {
    dispatch.mockReset();
    useAlert.mockReset();
    dispatch.mockResolvedValue();
  });

  it('submits a complete normalized edit with the current lock version', async () => {
    const wrapper = mountComponent({ mode: 'edit', selectedRole: role });
    const selects = wrapper.findAll('select');

    expect(selects[0].element.value).toBe('team');
    expect(selects[1].element.value).toBe('none');

    await selects[1].setValue('own');
    await wrapper.get('form').trigger('submit');
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('customRole/updateAccessRole', {
      id: role.id,
      lock_version: role.lock_version,
      name: role.name,
      description: role.description,
      grants: [
        {
          resource: 'contacts',
          capability: 'view',
          access_scope: 'team',
        },
        {
          resource: 'contacts',
          capability: 'create',
          access_scope: 'own',
        },
      ],
    });
    expect(wrapper.emitted('close')).toHaveLength(1);
  });

  it('uses resource-specific scopes and round-trips Automation manage', async () => {
    const wrapper = mountComponent({
      mode: 'edit',
      resources: { automation_rules: ['manage'] },
      resourceAccessScopes: { automation_rules: ['none', 'all'] },
      selectedRole: {
        ...role,
        grants: [
          {
            resource: 'automation_rules',
            capability: 'manage',
            access_scope: 'all',
          },
        ],
      },
    });
    const select = wrapper.get('select');

    expect(
      select.findAll('option').map(option => option.element.value)
    ).toEqual(['none', 'all']);
    expect(select.element.value).toBe('all');

    await wrapper.get('form').trigger('submit');
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith(
      'customRole/updateAccessRole',
      expect.objectContaining({
        grants: [
          {
            resource: 'automation_rules',
            capability: 'manage',
            access_scope: 'all',
          },
        ],
      })
    );
  });

  it('previews a clone and creates only copied metadata and normalized grants', async () => {
    const sourceRole = {
      ...role,
      system_key: 'employee',
      role_kind: 'system',
      description: null,
      assigned_users_count: 9,
      legacy_custom_role_id: null,
    };
    const wrapper = mountComponent({
      mode: 'clone',
      selectedRole: sourceRole,
    });

    expect(wrapper.get('input').element.value).toBe('Support copy');
    expect(wrapper.get('textarea').element.value).toBe('Copy of Support');
    expect(wrapper.findAll('select')[0].element.value).toBe('team');

    await wrapper.get('form').trigger('submit');
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('customRole/createAccessRole', {
      name: 'Support copy',
      description: 'Copy of Support',
      grants: sourceRole.grants,
    });
    expect(wrapper.emitted('close')).toHaveLength(1);
  });

  it('keeps the editor open and requests a rebase after a stale conflict', async () => {
    const staleError = new Error('stale');
    staleError.code = 'STALE_ACCESS_ROLE';
    dispatch.mockRejectedValue(staleError);
    const wrapper = mountComponent({ mode: 'edit', selectedRole: role });

    await wrapper.get('form').trigger('submit');
    await flushPromises();

    expect(wrapper.emitted('close')).toBeUndefined();
    expect(wrapper.emitted('stale')[0]).toEqual([role.id]);
    expect(useAlert).not.toHaveBeenCalled();
  });

  it('closes cleanly when the edited role no longer exists', async () => {
    const notFoundError = new Error('not found');
    notFoundError.code = 'ACCESS_ROLE_NOT_FOUND';
    dispatch.mockRejectedValue(notFoundError);
    const wrapper = mountComponent({ mode: 'edit', selectedRole: role });

    await wrapper.get('form').trigger('submit');
    await flushPromises();

    expect(wrapper.emitted('close')).toHaveLength(1);
    expect(wrapper.emitted('stale')).toBeUndefined();
    expect(useAlert).toHaveBeenCalledWith(
      'CUSTOM_ROLE.ACCESS_EDITOR.NOT_FOUND_ERROR'
    );
  });

  it.each(['ACCESS_ROLE_MUTATIONS_NOT_ENABLED', 'ACCESS_CONTROL_NOT_ENFORCED'])(
    'closes after runtime mutation mode change %s',
    async code => {
      const modeError = new Error('Mutation mode changed');
      modeError.code = code;
      dispatch.mockRejectedValue(modeError);
      const wrapper = mountComponent({ mode: 'edit', selectedRole: role });

      await wrapper.get('form').trigger('submit');
      await flushPromises();

      expect(wrapper.emitted('close')).toHaveLength(1);
      expect(useAlert).toHaveBeenCalledWith('Mutation mode changed');
    }
  );

  it('preserves a dirty draft when catalog metadata is refreshed', async () => {
    const wrapper = mountComponent({ mode: 'edit', selectedRole: role });
    const inputs = wrapper.findAll('input, textarea');
    const selects = wrapper.findAll('select');
    await inputs[0].setValue('Unsaved name');
    await inputs[1].setValue('Unsaved description');
    await selects[1].setValue('all');

    await wrapper.setProps({ resources: { contacts: ['view', 'create'] } });

    expect(inputs[0].element.value).toBe('Unsaved name');
    expect(inputs[1].element.value).toBe('Unsaved description');
    expect(selects[1].element.value).toBe('all');
  });

  it('does not submit an invalid new role', async () => {
    const wrapper = mountComponent({ mode: 'add' });

    await wrapper.get('form').trigger('submit');

    expect(dispatch).not.toHaveBeenCalled();
    expect(wrapper.get('[role="alert"]').exists()).toBe(true);
  });
});
