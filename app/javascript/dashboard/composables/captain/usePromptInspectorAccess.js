import { computed } from 'vue';
import { useMapGetter } from 'dashboard/composables/store';
import { useImpersonation } from 'dashboard/composables/useImpersonation';

// The compiled prompt of an agent (the prompt inspector) is for the platform
// team only: a super admin signed in as himself, or a super admin inside the
// clinic through «Войти как». A clinic user of any role never sees it, and the
// server answers 404 to him anyway (Captain::PromptInspectorAccess).
export const canInspectCompiledPrompts = ({ currentUser, isImpersonating }) =>
  currentUser?.type === 'SuperAdmin' || Boolean(isImpersonating);

export function usePromptInspectorAccess() {
  const currentUser = useMapGetter('getCurrentUser');
  const { isImpersonating } = useImpersonation();

  const canInspectPrompts = computed(() =>
    canInspectCompiledPrompts({
      currentUser: currentUser.value,
      isImpersonating: isImpersonating.value,
    })
  );

  return { canInspectPrompts };
}
