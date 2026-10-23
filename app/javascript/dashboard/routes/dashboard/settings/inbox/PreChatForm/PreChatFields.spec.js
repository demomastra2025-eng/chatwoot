import { describe, expect, it } from 'vitest';
import { mount } from '@vue/test-utils';

import PreChatFields from './PreChatFields.vue';

const fields = [
  {
    name: 'emailAddress',
    type: 'email',
    label: 'Email',
    placeholder: '',
    enabled: true,
    required: false,
  },
  {
    name: 'fullName',
    type: 'text',
    label: 'Full name',
    placeholder: '',
    enabled: true,
    required: false,
  },
  {
    name: 'phoneNumber',
    type: 'tel',
    label: 'Phone',
    placeholder: '',
    enabled: true,
    required: true,
  },
  {
    name: 'loyalty_tier',
    type: 'list',
    label: 'Tier',
    placeholder: '',
    enabled: false,
    required: false,
  },
  {
    name: 'company_name',
    type: 'text',
    label: 'Company',
    placeholder: '',
    enabled: false,
    required: false,
  },
];

// A minimal list stand-in: the real draggable list needs a browser.
const DraggableStub = {
  props: ['modelValue'],
  template:
    '<tbody><template v-for="item in modelValue" :key="item.name"><slot name="item" :element="item" /></template></tbody>',
};

const mountFields = props =>
  mount(PreChatFields, {
    props: { preChatFields: fields, ...props },
    global: { stubs: { Draggable: DraggableStub } },
  });

const rowFor = (wrapper, index) => wrapper.findAll('tr')[index].findAll('td');

describe('PreChatFields', () => {
  it('shows human field names and types instead of raw keys', () => {
    const wrapper = mountFields({ fieldTitles: { loyalty_tier: 'Тариф' } });
    const names = fields.map((_, index) => rowFor(wrapper, index)[2].text());
    const types = fields.map((_, index) => rowFor(wrapper, index)[3].text());

    expect(names).toEqual(['Email', 'Name', 'Phone', 'Тариф', 'Company name']);
    expect(types).toEqual(['Email', 'Text', 'Phone', 'List', 'Text']);
  });

  it('never prints the raw key or type', () => {
    const wrapper = mountFields();
    const cells = fields
      .flatMap((_, index) => [
        rowFor(wrapper, index)[2],
        rowFor(wrapper, index)[3],
      ])
      .map(cell => cell.text());

    ['emailAddress', 'fullName', 'phoneNumber', 'company_name', 'tel'].forEach(
      raw => expect(cells).not.toContain(raw)
    );
  });
});
