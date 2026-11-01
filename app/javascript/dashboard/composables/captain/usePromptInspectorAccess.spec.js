import { beforeEach, describe, expect, it, vi } from 'vitest';
import { computed, ref } from 'vue';
import {
  canInspectCompiledPrompts,
  usePromptInspectorAccess,
} from './usePromptInspectorAccess';

const currentUser = ref({});
vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => computed(() => currentUser.value),
}));
vi.mock('dashboard/composables/useImpersonation', () => ({
  useImpersonation: () => {
    throw new Error('Local impersonation is not authority');
  },
}));

beforeEach(() => {
  sessionStorage.clear();
});
describe('verified platform access', () => {
  it.each([
    [{ type: 'User', role: 'administrator' }, false],
    [{ type: 'User', role: 'agent', captain_platform_access: false }, false],
    [{ type: 'SuperAdmin' }, false],
    [{ type: 'SuperAdmin', captain_platform_access: true }, true],
    [{ type: 'User', captain_platform_access: true }, true],
    [{ type: 'User', captain_platform_access: 'true' }, false],
  ])('uses only the server boolean for %o', (user, allowed) => {
    expect(
      canInspectCompiledPrompts({ currentUser: user, isImpersonating: true })
    ).toBe(allowed);
  });
  it('denies a spoofed local impersonation marker without a server flag', () => {
    sessionStorage.setItem(
      'impersonationUser',
      JSON.stringify({ type: 'SuperAdmin' })
    );
    currentUser.value = { type: 'User' };
    const { canInspectPrompts } = usePromptInspectorAccess();
    expect(canInspectPrompts.value).toBe(false);
    currentUser.value = { type: 'User', captain_platform_access: true };
    expect(canInspectPrompts.value).toBe(true);
  });
});
