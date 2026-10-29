import { mount } from '@vue/test-utils';
import ContactCustomAttributeItem from './ContactCustomAttributeItem.vue';
import CrmCustomFieldDescriptionHint from 'dashboard/components-next/CRM/CrmCustomFieldDescriptionHint.vue';

const mocks = vi.hoisted(() => ({ dispatch: vi.fn() }));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: mocks.dispatch }),
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { contactId: 5 } }),
}));

const attribute = {
  id: 1,
  attributeKey: 'medelement_patient_code',
  attributeDisplayName: 'Medelement patient code',
  attributeDisplayType: 'text',
  value: 'P-100',
};

const mountItem = (props = {}) =>
  mount(ContactCustomAttributeItem, {
    props: { attribute, ...props },
    global: {
      stubs: {
        ListAttribute: true,
        CheckboxAttribute: true,
        DateAttribute: true,
        OtherAttribute: { template: '<div data-testid="attribute-editor" />' },
      },
    },
  });

describe('ContactCustomAttributeItem', () => {
  it('renders the editor for an ordinary attribute and omits (?) hint when description is empty', () => {
    const wrapper = mountItem();

    expect(wrapper.find('[data-testid="attribute-editor"]').exists()).toBe(
      true
    );
    expect(
      wrapper.find('[data-testid="contact-attribute-read-only"]').exists()
    ).toBe(false);
    expect(wrapper.findComponent(CrmCustomFieldDescriptionHint).exists()).toBe(
      false
    );
  });

  it('renders (?) tooltip hint for an ordinary attribute with a description', () => {
    const wrapper = mountItem({
      attribute: {
        ...attribute,
        attributeKey: 'preferred_time',
        attributeDisplayName: 'Preferred time',
        attributeDescription: 'Client preferred visit window',
      },
    });

    const hint = wrapper.findComponent(CrmCustomFieldDescriptionHint);
    expect(hint.exists()).toBe(true);
    expect(hint.props('description')).toBe('Client preferred visit window');
  });

  it('shows a value MedElement owns cleanly on one line and moves the MedElement reason into the (?) tooltip next to the label', () => {
    const wrapper = mountItem({ readOnly: true });

    const readOnly = wrapper.get('[data-testid="contact-attribute-read-only"]');
    expect(readOnly.text()).toBe('P-100');
    expect(readOnly.text()).not.toContain('Filled in automatically');

    const hint = wrapper.findComponent(CrmCustomFieldDescriptionHint);
    expect(hint.exists()).toBe(true);
    expect(hint.props('description')).toContain(
      'Filled in automatically from MedElement. It cannot be edited here.'
    );
    expect(wrapper.find('[data-testid="attribute-editor"]').exists()).toBe(
      false
    );
  });

  it('shows a dash for a read-only attribute with no value', () => {
    const wrapper = mountItem({
      readOnly: true,
      attribute: { ...attribute, value: '' },
    });

    expect(
      wrapper.get('[data-testid="contact-attribute-read-only"]').text()
    ).toBe('---');
  });
});
