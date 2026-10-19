// The «Модели ИИ» page of the super admin: the searchable lists of models, the short list with the model by default, the
// builder of the rules of the platform, the tabs, the sticky bar of unsaved changes. The page works without any of it
// (plain selects and one form); every part looks for its markup and does nothing when it is not there.

import { enhanceAll } from './modelPicker';
import { initAllowlist } from './allowlist';
import { initPromptsBuilder } from './promptsBuilder';
import { initTabs } from './tabs';
import { initSettingsForm, RESET_EVENT } from './settingsForm';

export const initAiModelsPage = (root = document) => {
  const page = root.querySelector('[data-ai-models]');
  if (!page) return null;
  let texts = {};
  try {
    texts = JSON.parse(page.dataset.texts || '{}');
  } catch (error) {
    texts = {};
  }
  const form = page.querySelector('#ai-models-form');
  if (!form) return null;

  const pickers = enhanceAll(page, texts).filter(Boolean);
  initAllowlist(page.querySelector('[data-allowlist]'), texts);
  initPromptsBuilder(page.querySelector('[data-prompts-builder]'), texts);
  initTabs(page);
  const settings = initSettingsForm(page, form, texts);
  page.addEventListener(RESET_EVENT, () =>
    pickers.forEach(picker => picker.refresh())
  );
  page.classList.add('is-enhanced');
  return { page, form, settings };
};

if (typeof document !== 'undefined') {
  const start = () => initAiModelsPage(document);
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
}
