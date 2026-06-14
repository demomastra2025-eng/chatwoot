import labels from '../labels';
import ApiClient from '../ApiClient';

describe('#LabelsAPI', () => {
  it('creates correct instance', () => {
    expect(labels).toBeInstanceOf(ApiClient);
    expect(labels).toHaveProperty('get');
    expect(labels).toHaveProperty('show');
    expect(labels).toHaveProperty('create');
    expect(labels).toHaveProperty('update');
    expect(labels).toHaveProperty('delete');
    expect(labels.url).toBe('/api/v1/labels');
  });

  describe('label payload contract', () => {
    const originalAxios = window.axios;
    const originalPathname = window.location.pathname;
    const axiosMock = {
      post: vi.fn(() => Promise.resolve()),
      patch: vi.fn(() => Promise.resolve()),
    };

    beforeEach(() => {
      window.axios = axiosMock;
      window.history.pushState({}, '', '/app/accounts/1/settings/labels');
      axiosMock.post.mockClear();
      axiosMock.patch.mockClear();
    });

    afterEach(() => {
      window.axios = originalAxios;
      window.history.pushState({}, '', originalPathname);
    });

    it('wraps plain create payloads under label', () => {
      labels.create({
        title: 'label_ff0011',
        display_title: 'VIP',
        marker_type: 'emoji',
        emoji: '⭐',
      });

      expect(axiosMock.post).toHaveBeenCalledWith('/api/v1/accounts/1/labels', {
        label: {
          title: 'label_ff0011',
          display_title: 'VIP',
          marker_type: 'emoji',
          emoji: '⭐',
        },
      });
    });

    it('wraps plain update payloads under label', () => {
      labels.update(42, {
        display_title: 'Important',
        show_on_sidebar: true,
      });

      expect(axiosMock.patch).toHaveBeenCalledWith(
        '/api/v1/accounts/1/labels/42',
        {
          label: {
            display_title: 'Important',
            show_on_sidebar: true,
          },
        }
      );
    });

    it('preserves already wrapped label payloads', () => {
      labels.update(42, {
        label: {
          display_title: 'Important',
        },
      });

      expect(axiosMock.patch).toHaveBeenCalledWith(
        '/api/v1/accounts/1/labels/42',
        {
          label: {
            display_title: 'Important',
          },
        }
      );
    });
  });
});
