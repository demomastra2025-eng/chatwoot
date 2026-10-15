// @vitest-environment node
import { readFileSync } from 'node:fs';
import { resolve as resolvePath } from 'node:path';

// The plan block of the clinic card (app/views/super_admin/accounts/_plan.html.erb) carries a small inline script:
// changing a module asks the server for the preview of what the plan would change and enables «Применить» only
// when something differs. This spec runs that very script against a minimal fake of the page (it needs no DOM
// library, so it runs on any Node).
const partial = readFileSync(
  resolvePath(process.cwd(), 'app/views/super_admin/accounts/_plan.html.erb'),
  'utf8'
);
const script = partial.match(/<script>([\s\S]*?)<\/script>/)[1];

const PREVIEW_URL = '/super_admin/accounts/7/plan_preview';

const mountForm = ({ assigned, initial = [], checked = [], fetchMock }) => {
  const listeners = {};
  const inputs = ['ai_agents', 'broadcasts'].map(value => ({
    name: 'modules[]',
    value,
    checked: checked.includes(value),
  }));
  const attributes = {
    'data-assigned': String(assigned),
    'data-initial-modules': JSON.stringify(initial),
    'data-preview-url': PREVIEW_URL,
  };
  const preview = { hidden: true, innerHTML: '' };
  const hint = { hidden: false };
  const submit = { disabled: false };
  const parts = {
    '[data-plan-preview]': preview,
    '[data-plan-hint]': hint,
    '[data-plan-submit]': submit,
  };
  const form = {
    getAttribute: name => attributes[name] ?? null,
    querySelector: selector => parts[selector] ?? null,
    querySelectorAll: selector =>
      selector === 'input[name="modules[]"]:checked'
        ? inputs.filter(input => input.checked)
        : [],
    addEventListener: (type, handler) => {
      listeners[type] = handler;
    },
  };
  const document = {
    querySelector: selector => (selector === '[data-plan-form]' ? form : null),
  };

  // eslint-disable-next-line no-new-func
  new Function('document', 'fetch', script)(document, fetchMock);

  return {
    preview,
    hint,
    submit,
    toggle: value => {
      const input = inputs.find(candidate => candidate.value === value);
      input.checked = !input.checked;
      listeners.change({ target: input });
    },
    change: target => listeners.change({ target }),
  };
};

const answer = html =>
  Promise.resolve({ ok: true, text: () => Promise.resolve(html) });

describe('the plan block of the clinic card', () => {
  let fetchMock;

  beforeEach(() => {
    fetchMock = vi.fn(() => answer('<div>preview</div>'));
  });

  it('extracts the script of the partial', () => {
    expect(script).toContain('data-plan-form');
    expect(script).toContain('fragment');
  });

  describe('a clinic without a plan', () => {
    it('shows the preview of the base at once and keeps «Назначить базу» enabled', async () => {
      const { preview, hint, submit } = mountForm({
        assigned: false,
        fetchMock,
      });

      expect(fetchMock).toHaveBeenCalledTimes(1);
      expect(fetchMock.mock.calls[0][0]).toBe(`${PREVIEW_URL}?fragment=1`);
      expect(submit.disabled).toBe(false);

      await vi.waitFor(() => expect(preview.hidden).toBe(false));
      expect(preview.innerHTML).toBe('<div>preview</div>');
      expect(hint.hidden).toBe(true);
    });

    it('asks again with the chosen modules', async () => {
      const { toggle, preview } = mountForm({ assigned: false, fetchMock });
      await vi.waitFor(() => expect(preview.hidden).toBe(false));

      toggle('ai_agents');

      expect(fetchMock).toHaveBeenCalledTimes(2);
      expect(decodeURIComponent(fetchMock.mock.calls[1][0])).toBe(
        `${PREVIEW_URL}?fragment=1&modules[]=ai_agents`
      );
    });
  });

  describe('a clinic with a plan', () => {
    const assignedForm = () =>
      mountForm({
        assigned: true,
        initial: ['ai_agents'],
        checked: ['ai_agents'],
        fetchMock,
      });

    it('has nothing to apply until a module changes', () => {
      const { preview, submit, hint } = assignedForm();

      expect(fetchMock).not.toHaveBeenCalled();
      expect(submit.disabled).toBe(true);
      expect(preview.hidden).toBe(true);
      expect(hint.hidden).toBe(false);
    });

    it('asks for the preview of the new selection and enables «Применить»', async () => {
      const { toggle, preview, submit, hint } = assignedForm();

      toggle('broadcasts');

      expect(fetchMock).toHaveBeenCalledTimes(1);
      expect(decodeURIComponent(fetchMock.mock.calls[0][0])).toBe(
        `${PREVIEW_URL}?fragment=1&modules[]=ai_agents&modules[]=broadcasts`
      );
      expect(fetchMock.mock.calls[0][1]).toMatchObject({
        credentials: 'same-origin',
      });
      expect(submit.disabled).toBe(false);
      await vi.waitFor(() => expect(preview.hidden).toBe(false));
      expect(hint.hidden).toBe(true);
    });

    it('goes back to nothing to apply when the change is undone', async () => {
      const { toggle, preview, submit, hint } = assignedForm();
      toggle('broadcasts');
      await vi.waitFor(() => expect(preview.hidden).toBe(false));

      toggle('broadcasts');

      expect(submit.disabled).toBe(true);
      expect(preview.hidden).toBe(true);
      expect(preview.innerHTML).toBe('');
      expect(hint.hidden).toBe(false);
    });

    it('ignores an old answer that arrives after a newer one', async () => {
      const resolvers = [];
      fetchMock.mockImplementation(
        () =>
          new Promise(done => {
            resolvers.push(html =>
              done({ ok: true, text: () => Promise.resolve(html) })
            );
          })
      );
      const { toggle, preview } = assignedForm();

      toggle('broadcasts');
      toggle('broadcasts');
      toggle('broadcasts');
      expect(resolvers).toHaveLength(2);

      resolvers[1]('<div>new</div>');
      await vi.waitFor(() => expect(preview.innerHTML).toBe('<div>new</div>'));
      resolvers[0]('<div>old</div>');
      await new Promise(done => {
        setTimeout(done, 0);
      });

      expect(preview.innerHTML).toBe('<div>new</div>');
    });

    it('still lets the operator apply when the preview cannot be loaded', async () => {
      fetchMock.mockImplementation(() =>
        Promise.resolve({ ok: false, status: 500 })
      );
      const { toggle, preview, submit, hint } = assignedForm();

      toggle('broadcasts');

      await vi.waitFor(() => expect(hint.hidden).toBe(false));
      expect(preview.hidden).toBe(true);
      expect(submit.disabled).toBe(false);
    });

    it('does not react to other fields of the form', () => {
      const { change } = assignedForm();

      change({ name: 'something_else' });

      expect(fetchMock).not.toHaveBeenCalled();
    });
  });
});
