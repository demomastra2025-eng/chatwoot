import { computed, ref } from 'vue';
import { useStoreGetters } from 'dashboard/composables/store';
import TouchPlansAPI from 'dashboard/api/touchPlans';

const sharedTouchPlans = ref([]);
const loadedAccountId = ref(null);
const isLoadingTouchPlans = ref(false);

export function useTouchPlans() {
  const getters = useStoreGetters();
  const currentAccountId = computed(() => getters.getCurrentAccountId.value);

  const loadTouchPlans = async ({ force = false } = {}) => {
    if (!currentAccountId.value) {
      return [];
    }

    if (!force && loadedAccountId.value === currentAccountId.value) {
      return sharedTouchPlans.value;
    }

    isLoadingTouchPlans.value = true;

    try {
      const response = await TouchPlansAPI.get();
      sharedTouchPlans.value = response.data?.payload || [];
      loadedAccountId.value = currentAccountId.value;
      return sharedTouchPlans.value;
    } finally {
      isLoadingTouchPlans.value = false;
    }
  };

  const touchPlanOptionsForEntityKind = entityKind =>
    sharedTouchPlans.value
      .filter(
        plan => !entityKind || (plan.entity_kinds || []).includes(entityKind)
      )
      .map(plan => ({
        id: plan.id,
        name: plan.name,
      }));

  return {
    isLoadingTouchPlans,
    loadTouchPlans,
    touchPlans: sharedTouchPlans,
    touchPlanOptionsForEntityKind,
  };
}
