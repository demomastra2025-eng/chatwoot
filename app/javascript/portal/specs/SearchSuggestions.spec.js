import { flushPromises, mount } from '@vue/test-utils';
import { describe, it, expect, vi } from 'vitest';
import SearchSuggestions from '../components/SearchSuggestions.vue';

vi.mock('dashboard/composables/useDetectKeyboardLayout', () => ({
  useDetectKeyboardLayout: vi.fn(async () => 'qwerty'),
}));

vi.mock('shared/composables/useMessageFormatter', () => ({
  useMessageFormatter: () => ({
    highlightContent: content => content,
  }),
}));

describe('SearchSuggestions', () => {
  let wrapper;

  afterEach(() => {
    wrapper?.unmount();
    document.body.innerHTML = '';
  });

  it('renders suggestion links from the backend-provided link field', () => {
    wrapper = mount(SearchSuggestions, {
      props: {
        items: [
          {
            id: 1,
            title: 'Chatwoot Glossary',
            content: 'Access Token',
            link: '/hc/user-guide/articles/1677141565-chatwoot-glossary',
          },
        ],
        isLoading: false,
        searchTerm: 'chatwoot',
      },
      global: {
        directives: {
          dompurifyHtml: (element, binding) => {
            element.innerHTML = binding.value;
          },
        },
      },
    });

    expect(wrapper.find('a').attributes('href')).toBe(
      '/hc/user-guide/articles/1677141565-chatwoot-glossary'
    );
  });

  const articles = [
    { id: 1, title: 'First', content: 'Example', link: '/hc/demo/articles/1' },
    { id: 2, title: 'Second', content: 'Example', link: '/hc/demo/articles/2' },
  ];

  const renderSuggestions = async props => {
    document.body.innerHTML = '<input id="portal-search-test" />';
    wrapper = mount(SearchSuggestions, {
      props: { items: articles, ...props },
      attachTo: document.body,
      global: { directives: { dompurifyHtml: () => {} } },
    });
    await flushPromises();
    document.getElementById('portal-search-test').focus();
    return wrapper.findAll('a').map(link => {
      const activate = vi.fn(event => event.preventDefault());
      link.element.addEventListener('click', activate);
      return activate;
    });
  };

  const pressKey = async key => {
    document.activeElement.dispatchEvent(
      new KeyboardEvent('keydown', {
        key,
        code: key,
        bubbles: true,
        cancelable: true,
      })
    );
    await flushPromises();
  };

  it('opens the backend link selected with arrow keys when Enter is pressed in the search input', async () => {
    const [first, second] = await renderSuggestions();
    await pressKey('ArrowDown');
    await pressKey('ArrowDown');
    await pressKey('Enter');

    expect(first).not.toHaveBeenCalled();
    expect(second).toHaveBeenCalledOnce();
    expect(second.mock.calls[0][0].target.getAttribute('href')).toBe(
      articles[1].link
    );
  });

  it('does not activate a result before one has been selected', async () => {
    const [first, second] = await renderSuggestions();
    await pressKey('Enter');
    expect(first).not.toHaveBeenCalled();
    expect(second).not.toHaveBeenCalled();
  });

  it('resets selection when the search results change', async () => {
    const [first, second] = await renderSuggestions();
    await pressKey('ArrowDown');
    await wrapper.setProps({ items: [...articles] });
    await pressKey('Enter');
    expect(first).not.toHaveBeenCalled();
    expect(second).not.toHaveBeenCalled();
  });

  it('does not navigate while results are loading or empty', async () => {
    await renderSuggestions({ isLoading: true });
    await pressKey('ArrowDown');
    await pressKey('Enter');
    expect(wrapper.find('a').exists()).toBe(false);
    await wrapper.setProps({ isLoading: false, items: [] });
    await pressKey('Enter');
    expect(wrapper.find('a').exists()).toBe(false);
  });
});
