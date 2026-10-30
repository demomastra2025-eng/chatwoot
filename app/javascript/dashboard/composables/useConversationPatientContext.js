import { computed, getCurrentInstance, unref, watch } from 'vue';
import { getActivePinia } from 'pinia';
import { resolveChatContactId } from 'dashboard/components-next/CRM/crmConversationDealContext';
import {
  conversationPatientContextKey,
  isDraftPatientContextKey,
  useConversationPatientContextStore,
} from 'dashboard/stores/scheduling/patientContext';

export const resolveOptionalPatientStore = () => {
  const instance = getCurrentInstance();
  const appProvides = instance?.appContext?.provides;
  const hasProvidedPinia = Boolean(
    appProvides &&
      Reflect.ownKeys(appProvides).some(key => String(key).includes('pinia'))
  );
  if (!hasProvidedPinia) return null;
  const pinia = getActivePinia();
  return pinia ? useConversationPatientContextStore(pinia) : null;
};

export const useConversationPatientContext = ({
  chat,
  accountId,
  userId,
  route = null,
  router = null,
} = {}) => {
  const patientStore = resolveOptionalPatientStore();

  const chatContactId = computed(() => resolveChatContactId(unref(chat)));

  const patientContextKey = computed(() => {
    if (!patientStore) return '';
    return conversationPatientContextKey({
      accountId: unref(accountId),
      userId: unref(userId),
      chat: unref(chat),
    });
  });

  const patientContextEnabled = computed(() =>
    Boolean(patientStore && patientContextKey.value && chatContactId.value)
  );

  const patientEntry = computed(() => {
    if (!patientStore || !patientContextKey.value) return null;
    return patientStore.contexts[patientContextKey.value] || null;
  });

  const patients = computed(() => patientEntry.value?.patients || []);

  const hasMultiplePatients = computed(() =>
    Boolean(patientEntry.value?.loaded && patients.value.length > 1)
  );

  const selectedPatient = computed(() => {
    if (!patientStore || !patientContextKey.value) return null;
    return patientStore.selectedPatient(patientContextKey.value);
  });

  if (patientStore) {
    watch(patientContextKey, (newKey, oldKey) => {
      if (!newKey || !oldKey || newKey === oldKey) return;
      if (
        !isDraftPatientContextKey(oldKey) ||
        isDraftPatientContextKey(newKey)
      ) {
        return;
      }
      const previous = patientStore.selectedPatient(oldKey);
      if (previous?.id) patientStore.rememberSelection(newKey, previous.id);
    });

    watch(
      () => [
        patientContextKey.value,
        chatContactId.value,
        patientContextEnabled.value,
        route?.query?.patientContactId,
        route?.query?.patientChatContactId,
      ],
      () => {
        if (
          !patientContextEnabled.value ||
          !patientContextKey.value ||
          !chatContactId.value
        ) {
          return;
        }
        const requestedPatient = route?.query?.patientContactId;
        const hasPatientRequest =
          Boolean(router?.replace) &&
          Number(route?.query?.patientChatContactId) ===
            Number(chatContactId.value) &&
          Boolean(requestedPatient);
        if (hasPatientRequest) {
          patientStore.rememberSelection(
            patientContextKey.value,
            requestedPatient
          );
          if (patientEntry.value?.loaded) {
            patientStore.select(patientContextKey.value, requestedPatient);
          }
          if (router?.replace && route?.query) {
            const query = { ...route.query };
            delete query.patientContactId;
            delete query.patientChatContactId;
            router.replace({ query });
          }
        }
        patientStore.load(patientContextKey.value, chatContactId.value, {
          force: hasPatientRequest,
        });
      },
      { immediate: true }
    );
  }

  return {
    patientStore,
    chatContactId,
    patientContextKey,
    patientContextEnabled,
    patientEntry,
    patients,
    hasMultiplePatients,
    selectedPatient,
  };
};
