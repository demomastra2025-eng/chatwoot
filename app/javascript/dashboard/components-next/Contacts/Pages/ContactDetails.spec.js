import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, shallowMount } from '@vue/test-utils';
import { ref } from 'vue';
import ContactDetails from './ContactDetails.vue';

const dispatch = vi.hoisted(() => vi.fn());

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch }),
  useMapGetter: () => ref({ isUpdating: false }),
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/useOpenPersonDialog', () => ({
  useOpenPersonDialog: () => ({ openPersonDialog: vi.fn() }),
}));
vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key, locale: ref('ru') }),
}));

const ButtonStub = {
  name: 'Button',
  props: ['label', 'disabled'],
  emits: ['click'],
  template:
    '<button :data-label="label" :disabled="disabled" @click="$emit(\'click\')" />',
};
const selectedSource = {
  kind: 'channel_profile',
  contactInboxId: 7,
  inboxId: 9,
};
const contact = () => ({
  id: 17,
  name: 'Channel Name',
  createdAt: 1793000000,
  additionalAttributes: {
    displayPreferences: { primaryNameSource: selectedSource },
  },
  primaryNameSource: selectedSource,
  channelProfiles: [{ id: 7, displayName: 'Channel Name' }],
});
const mountDetails = props =>
  shallowMount(ContactDetails, {
    props: { selectedContact: contact(), ...props },
    global: {
      mocks: { $t: key => key },
      stubs: {
        Button: ButtonStub,
        Policy: { template: '<div><slot /></div>' },
      },
    },
  });
const save = async wrapper => {
  await wrapper
    .get(
      'button[data-label="CONTACTS_LAYOUT.CARD.EDIT_DETAILS_FORM.UPDATE_BUTTON"]'
    )
    .trigger('click');
  await flushPromises();
  return dispatch.mock.calls.find(
    ([action]) => action === 'contacts/update'
  )[1];
};

describe('ContactDetails name intent', () => {
  beforeEach(() => {
    dispatch.mockReset();
    dispatch.mockResolvedValue(undefined);
  });

  it('marks a manual name edit explicitly instead of replaying its old channel source', async () => {
    const wrapper = mountDetails();
    wrapper.findComponent({ name: 'ContactsForm' }).vm.$emit('update', {
      name: '15550000011',
    });

    const payload = await save(wrapper);

    expect(payload.name).toBe('15550000011');
    expect(
      payload.additionalAttributes.displayPreferences.primaryNameSource
    ).toEqual({ kind: 'manual' });
  });

  it.each(['camel', 'snake'])(
    'retains the avatar pin and unrelated metadata from %s attributes on a real-shaped form rename',
    async representation => {
      const avatarSource = {
        kind: 'channel_profile',
        contactInboxId: 11,
        inboxId: 13,
      };
      const selectedContact = contact();
      if (representation === 'camel') {
        selectedContact.additionalAttributes = {
          displayPreferences: {
            primaryNameSource: selectedSource,
            primaryAvatarSource: avatarSource,
          },
          unrelatedMetadata: { keep: 'recorded' },
          description: 'Original biography',
        };
      } else {
        delete selectedContact.additionalAttributes;
        selectedContact.additional_attributes = {
          display_preferences: {
            primary_name_source: {
              kind: 'channel_profile',
              contact_inbox_id: 7,
              inbox_id: 9,
            },
            primary_avatar_source: {
              kind: 'channel_profile',
              contact_inbox_id: 11,
              inbox_id: 13,
            },
          },
          unrelated_metadata: { keep: 'recorded' },
          description: 'Original biography',
        };
      }
      const wrapper = mountDetails({ selectedContact });
      // ContactsForm emits stateWithoutNames, including only its own attribute fields.
      wrapper.findComponent({ name: 'ContactsForm' }).vm.$emit('update', {
        id: 17,
        name: 'Manual Alias',
        email: 'synthetic@example.invalid',
        phoneNumber: '',
        additionalAttributes: {
          description: 'Edited biography',
          companyName: 'Synthetic company',
          countryCode: 'KZ',
          country: 'Kazakhstan',
          city: 'Astana',
          socialProfiles: { telegram: 'synthetic_handle' },
        },
      });

      const payload = await save(wrapper);

      expect(payload.name).toBe('Manual Alias');
      expect(payload.additional_attributes).toBeUndefined();
      expect(payload.additionalAttributes.displayPreferences).toEqual({
        primaryNameSource: { kind: 'manual' },
        primaryAvatarSource: avatarSource,
      });
      expect(payload.additionalAttributes).toMatchObject({
        unrelatedMetadata: { keep: 'recorded' },
        description: 'Edited biography',
        companyName: 'Synthetic company',
        city: 'Astana',
        socialProfiles: { telegram: 'synthetic_handle' },
      });
      expect(payload.email).toBe('synthetic@example.invalid');
    }
  );

  it('does not change the selected name source for another form field', async () => {
    const wrapper = mountDetails();
    wrapper.findComponent({ name: 'ContactsForm' }).vm.$emit('update', {
      email: 'synthetic@example.com',
      name: 'Channel Name',
    });

    const payload = await save(wrapper);

    expect(
      payload.additionalAttributes.displayPreferences.primaryNameSource
    ).toEqual(selectedSource);
  });

  it('marks manual intent when the original attributes use the API snake-case representation', async () => {
    const selectedContact = contact();
    delete selectedContact.additionalAttributes;
    selectedContact.additional_attributes = {
      display_preferences: { primary_name_source: selectedSource },
    };
    const wrapper = mountDetails({ selectedContact });
    wrapper.findComponent({ name: 'ContactsForm' }).vm.$emit('update', {
      name: 'Manual Alias',
    });

    const payload = await save(wrapper);

    expect(payload.additional_attributes).toBeUndefined();
    expect(
      payload.additionalAttributes.displayPreferences.primaryNameSource
    ).toEqual({ kind: 'manual' });
  });

  it('keeps the explicit source chooser as a channel selection', async () => {
    const wrapper = mountDetails();
    wrapper
      .findComponent({ name: 'ContactIdentitySources' })
      .vm.$emit('selectNameSource', {
        ...selectedSource,
        displayName: 'Selected Channel Name',
      });
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith(
      'contacts/update',
      expect.objectContaining({
        name: 'Selected Channel Name',
        additionalAttributes: {
          displayPreferences: {
            primaryNameSource: expect.objectContaining(selectedSource),
          },
        },
      })
    );
  });
});
