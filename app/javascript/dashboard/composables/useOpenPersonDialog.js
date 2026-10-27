import { inject } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useStore } from 'dashboard/composables/store';
import { personDialogRoute } from 'dashboard/helper/personDialogHelper';

// A panel that shows the dialog beside a page (the calendar, a deal) provides this: «Написать» there opens the dialog in the panel
// and does not leave the page.
export const PERSON_DIALOG_OPENER = 'personDialogOpener';

// «Написать»: every button that writes to a person opens the dialog of the person, either the one they already have or the empty
// screen of a draft. There is no other way to start a conversation from the screen.
export const useOpenPersonDialog = () => {
  const router = useRouter();
  const route = useRoute();
  const store = useStore();
  const panelOpener = inject(PERSON_DIALOG_OPENER, null);

  const openPersonDialog = (contactId, { patientContactId = null } = {}) => {
    if (panelOpener) return panelOpener(contactId, { patientContactId });

    return router.push(
      personDialogRoute({
        accountId:
          route?.params?.accountId || store.getters.getCurrentAccountId,
        contactId,
        patientContactId,
      })
    );
  };

  return { openPersonDialog };
};
