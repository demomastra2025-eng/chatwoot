import { computed } from 'vue';
import { useMapGetter } from 'dashboard/composables/store';

// Only the server can verify platform access, including an impersonation.
export const canInspectCompiledPrompts = ({ currentUser }) =>
  currentUser?.captain_platform_access === true;

export function usePromptInspectorAccess() {
  const currentUser = useMapGetter('getCurrentUser');
  const canInspectPrompts = computed(() =>
    canInspectCompiledPrompts({ currentUser: currentUser.value })
  );
  return { canInspectPrompts };
}
