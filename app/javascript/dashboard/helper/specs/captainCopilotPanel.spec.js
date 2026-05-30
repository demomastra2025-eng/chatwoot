import { describe, expect, it, beforeEach } from 'vitest';

import {
  CAPTAIN_COPILOT_PANEL_CLOSED_SESSION_KEY,
  isCaptainRoute,
  markCaptainCopilotPanelClosed,
  wasCaptainCopilotPanelClosed,
} from '../captainCopilotPanel';

describe('captainCopilotPanel helper', () => {
  beforeEach(() => {
    window.sessionStorage.clear();
  });

  it('identifies Captain route names and paths', () => {
    expect(isCaptainRoute({ name: 'captain_assistants_index' })).toBe(true);
    expect(isCaptainRoute({ path: '/app/accounts/1/captain/assistants' })).toBe(
      true
    );
    expect(
      isCaptainRoute({ name: 'contacts_dashboard', path: '/contacts' })
    ).toBe(false);
  });

  it('stores the close marker only for Captain routes', () => {
    markCaptainCopilotPanelClosed({ name: 'contacts_dashboard' });

    expect(wasCaptainCopilotPanelClosed()).toBe(false);

    markCaptainCopilotPanelClosed({ name: 'captain_assistants_index' });

    expect(
      window.sessionStorage.getItem(CAPTAIN_COPILOT_PANEL_CLOSED_SESSION_KEY)
    ).toBe('true');
    expect(wasCaptainCopilotPanelClosed()).toBe(true);
  });
});
