import * as webRTCAdapterModule from 'webrtc-adapter';

const screenSharingExtension = {
  init: () => {},
  isInstalled: () => true,
  getScreen: callback =>
    callback(new Error('Screen sharing is not supported for Janus SIP calls')),
};

const resolveWebRTCAdapter = () => {
  const candidates = [
    webRTCAdapterModule?.default?.default,
    webRTCAdapterModule?.default,
    webRTCAdapterModule,
    typeof window !== 'undefined' ? window.adapter : null,
  ];

  return (
    candidates.find(candidate => candidate?.browserDetails) ||
    candidates.find(candidate => candidate?.default?.browserDetails)?.default ||
    null
  );
};

const createJanusHttpError = (message, extra = {}) =>
  Object.assign(new Error(message), extra);

const janusHttpAPICall = (url, options = {}) => {
  const fetchOptions = {
    method: options.verb,
    headers: {
      Accept: 'application/json, text/plain, */*',
    },
    cache: 'no-cache',
  };

  if (options.verb === 'POST') {
    fetchOptions.headers['Content-Type'] = 'application/json';
  }

  if (options.withCredentials !== undefined) {
    fetchOptions.credentials =
      options.withCredentials === true
        ? 'include'
        : options.withCredentials || 'omit';
  }

  if (options.body) {
    fetchOptions.body = JSON.stringify(options.body);
  }

  let request = fetch(url, fetchOptions).catch(error =>
    Promise.reject(
      createJanusHttpError('Probably a network error, is the server down?', {
        error,
      })
    )
  );

  if (options.timeout) {
    const timeout = new Promise((_resolve, reject) => {
      const timerId = window.setTimeout(() => {
        window.clearTimeout(timerId);
        reject(
          createJanusHttpError('Request timed out', {
            timeout: options.timeout,
          })
        );
      }, options.timeout);
    });
    request = Promise.race([request, timeout]);
  }

  request
    .then(response => {
      if (!response.ok) {
        return Promise.reject(
          createJanusHttpError('API call failed', { response })
        );
      }

      if (typeof options.success !== 'function') return null;

      return response
        .json()
        .then(parsed => options.success(parsed))
        .catch(error =>
          Promise.reject(
            createJanusHttpError('Failed to parse response body', {
              error,
              response,
            })
          )
        );
    })
    .catch(error => {
      if (typeof options.error === 'function') {
        options.error(error.message || '<< internal error >>', error);
      }
    });

  return request;
};

export const createJanusDependencies = () => {
  const webRTCAdapter = resolveWebRTCAdapter();
  if (!webRTCAdapter) {
    throw new Error('WebRTC adapter is not available for Janus');
  }

  return {
    newWebSocket: (server, proto) => new WebSocket(server, proto),
    extension: screenSharingExtension,
    isArray: Array.isArray,
    webRTCAdapter,
    httpAPICall: janusHttpAPICall,
  };
};
