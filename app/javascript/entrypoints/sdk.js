import { installOneLinkGlobals } from '../shared/helpers/brandGlobals';
import Cookies from 'js-cookie';
import { IFrameHelper } from '../sdk/IFrameHelper';
import {
  getBubbleView,
  getDarkMode,
  getWidgetStyle,
} from '../sdk/settingsHelper';
import {
  computeHashForUserData,
  getUserCookieName,
  hasUserKeys,
} from '../sdk/cookieHelpers';
import {
  addClasses,
  removeClasses,
  restoreWidgetInDOM,
} from '../sdk/DOMHelpers';
import { setCookieWithDomain } from '../sdk/cookieHelpers';
import { SDK_SET_BUBBLE_VISIBILITY } from 'shared/constants/sharedFrameEvents';

installOneLinkGlobals();

const runSDK = ({ baseUrl, websiteToken }) => {
  if (window.$onelink) {
    return;
  }

  // if this is a Rails Turbo app
  document.addEventListener('turbo:before-render', event => {
    // when morphing the page, this typically happens on reload like events
    // say you update a "Customer" on a form and it reloads the page
    // We have already added data-turbo-permananent to true. This
    // will ensure that the widget it preserved
    // Read more about morphing here: https://turbo.hotwired.dev/handbook/page_refreshes#morphing
    // and peristing elements here: https://turbo.hotwired.dev/handbook/building#persisting-elements-across-page-loads
    if (event.detail.renderMethod === 'morph') return;

    restoreWidgetInDOM(event.detail.newBody);
  });

  if (window.Turbolinks) {
    document.addEventListener('turbolinks:before-render', event => {
      restoreWidgetInDOM(event.data.newBody);
    });
  }

  // if this is an astro app
  document.addEventListener('astro:before-swap', event =>
    restoreWidgetInDOM(event.newDocument.body)
  );

  const settings = window.onelinkSettings || {};
  let locale = settings.locale;
  let baseDomain = settings.baseDomain;

  if (settings.useBrowserLanguage) {
    locale = window.navigator.language.replace('-', '_');
  }

  window.$onelink = {
    baseUrl,
    baseDomain,
    hasLoaded: false,
    hideMessageBubble: settings.hideMessageBubble || false,
    isOpen: false,
    position: settings.position === 'left' ? 'left' : 'right',
    websiteToken,
    locale,
    useBrowserLanguage: settings.useBrowserLanguage || false,
    type: getBubbleView(settings.type),
    launcherTitle: settings.launcherTitle || '',
    showPopoutButton: settings.showPopoutButton || false,
    showUnreadMessagesDialog: settings.showUnreadMessagesDialog ?? true,
    widgetStyle: getWidgetStyle(settings.widgetStyle) || 'standard',
    resetTriggered: false,
    darkMode: getDarkMode(settings.darkMode),
    welcomeTitle: settings.welcomeTitle || '',
    welcomeDescription: settings.welcomeDescription || '',
    availableMessage: settings.availableMessage || '',
    unavailableMessage: settings.unavailableMessage || '',
    enableFileUpload: settings.enableFileUpload,
    enableEmojiPicker: settings.enableEmojiPicker ?? true,
    enableEndConversation: settings.enableEndConversation ?? true,

    toggle(state) {
      IFrameHelper.events.toggleBubble(state);
    },

    toggleBubbleVisibility(visibility) {
      let widgetElm = document.querySelector('.woot--bubble-holder');
      let widgetHolder = document.querySelector('.woot-widget-holder');
      if (visibility === 'hide') {
        addClasses(widgetHolder, 'woot-widget--without-bubble');
        addClasses(widgetElm, 'woot-hidden');
        window.$onelink.hideMessageBubble = true;
      } else if (visibility === 'show') {
        removeClasses(widgetElm, 'woot-hidden');
        removeClasses(widgetHolder, 'woot-widget--without-bubble');
        window.$onelink.hideMessageBubble = false;
      }
      IFrameHelper.sendMessage(SDK_SET_BUBBLE_VISIBILITY, {
        hideMessageBubble: window.$onelink.hideMessageBubble,
      });
    },

    popoutChatWindow() {
      IFrameHelper.events.popoutChatWindow({
        baseUrl: window.$onelink.baseUrl,
        websiteToken: window.$onelink.websiteToken,
        locale,
      });
    },

    setUser(identifier, user) {
      if (typeof identifier !== 'string' && typeof identifier !== 'number') {
        throw new Error('Identifier should be a string or a number');
      }

      if (!hasUserKeys(user)) {
        throw new Error(
          'User object should have one of the keys [avatar_url, email, name]'
        );
      }

      const userCookieName = getUserCookieName();
      const existingCookieValue = Cookies.get(userCookieName);
      const hashToBeStored = computeHashForUserData({ identifier, user });
      if (hashToBeStored === existingCookieValue) {
        return;
      }

      window.$onelink.identifier = identifier;
      window.$onelink.user = user;
      IFrameHelper.sendMessage('set-user', { identifier, user });

      setCookieWithDomain(userCookieName, hashToBeStored, {
        baseDomain,
      });
    },

    setCustomAttributes(customAttributes = {}) {
      if (!customAttributes || !Object.keys(customAttributes).length) {
        throw new Error('Custom attributes should have atleast one key');
      } else {
        IFrameHelper.sendMessage('set-custom-attributes', { customAttributes });
      }
    },

    deleteCustomAttribute(customAttribute = '') {
      if (!customAttribute) {
        throw new Error('Custom attribute is required');
      } else {
        IFrameHelper.sendMessage('delete-custom-attribute', {
          customAttribute,
        });
      }
    },

    setConversationCustomAttributes(customAttributes = {}) {
      if (!customAttributes || !Object.keys(customAttributes).length) {
        throw new Error('Custom attributes should have atleast one key');
      } else {
        IFrameHelper.sendMessage('set-conversation-custom-attributes', {
          customAttributes,
        });
      }
    },

    deleteConversationCustomAttribute(customAttribute = '') {
      if (!customAttribute) {
        throw new Error('Custom attribute is required');
      } else {
        IFrameHelper.sendMessage('delete-conversation-custom-attribute', {
          customAttribute,
        });
      }
    },

    setLabel(label = '') {
      IFrameHelper.sendMessage('set-label', { label });
    },

    removeLabel(label = '') {
      IFrameHelper.sendMessage('remove-label', { label });
    },

    setLocale(localeToBeUsed = 'ru') {
      IFrameHelper.sendMessage('set-locale', { locale: localeToBeUsed });
    },

    setColorScheme(darkMode = 'light') {
      IFrameHelper.sendMessage('set-color-scheme', {
        darkMode: getDarkMode(darkMode),
      });
    },

    reset() {
      if (window.$onelink.isOpen) {
        IFrameHelper.events.toggleBubble();
      }

      Cookies.remove('cw_conversation');
      Cookies.remove(getUserCookieName());

      const iframe = IFrameHelper.getAppFrame();
      iframe.src = IFrameHelper.getUrl({
        baseUrl: window.$onelink.baseUrl,
        websiteToken: window.$onelink.websiteToken,
      });

      window.$onelink.resetTriggered = true;
    },
  };

  IFrameHelper.createFrame({
    baseUrl,
    websiteToken,
  });
};

window.onelinkSDK = {
  run: runSDK,
};
