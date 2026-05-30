export const CAPTAIN_COPILOT_PANEL_CLOSED_SESSION_KEY =
  'captain_copilot_panel_closed';

const storage = () => {
  try {
    return window?.sessionStorage;
  } catch {
    return null;
  }
};

export const isCaptainRoute = route => {
  const routeName = String(route?.name || '');
  const routePath = String(route?.path || '');

  return routeName.startsWith('captain_') || routePath.includes('/captain');
};

export const markCaptainCopilotPanelClosed = route => {
  if (!isCaptainRoute(route)) return;

  storage()?.setItem(CAPTAIN_COPILOT_PANEL_CLOSED_SESSION_KEY, 'true');
};

export const wasCaptainCopilotPanelClosed = () =>
  storage()?.getItem(CAPTAIN_COPILOT_PANEL_CLOSED_SESSION_KEY) === 'true';
