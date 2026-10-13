import automations from '../automation';
import ApiClient from '../ApiClient';

describe('#AutomationsAPI', () => {
  it('creates correct instance', () => {
    expect(automations).toBeInstanceOf(ApiClient);
    expect(automations).toHaveProperty('get');
    expect(automations).toHaveProperty('show');
    expect(automations).toHaveProperty('create');
    expect(automations).toHaveProperty('update');
    expect(automations).toHaveProperty('delete');
    expect(automations).toHaveProperty('clone');
    expect(automations).toHaveProperty('contactOptions');
    expect(automations.url).toBe('/api/v1/automation_rules');
  });

  describe('#contactOptions', () => {
    const originalAxios = window.axios;

    beforeEach(() => {
      window.axios = { get: vi.fn().mockResolvedValue({ data: {} }) };
    });

    afterEach(() => {
      window.axios = originalAxios;
    });

    it('searches the contacts by text and page', () => {
      automations.contactOptions({ q: 'айгер', page: 2 });

      expect(window.axios.get).toHaveBeenCalledWith(
        `${automations.url}/contact_options`,
        { params: { q: 'айгер', page: 2 } }
      );
    });

    it('looks up the contacts behind saved ids', () => {
      automations.contactOptions({ ids: [7, 9] });

      expect(window.axios.get).toHaveBeenCalledWith(
        `${automations.url}/contact_options`,
        { params: { ids: [7, 9] } }
      );
    });
  });
});
