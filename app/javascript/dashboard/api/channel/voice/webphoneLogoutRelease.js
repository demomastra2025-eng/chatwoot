// The sign-out code lives apart from the phone, so the phone registers here how
// it releases itself. The release is best effort: signing out never fails or
// hangs because of the phone.
const LOGOUT_RELEASE_TIMEOUT_MS = 2_500;

let releaseHandler = null;

export const registerWebphoneLogoutRelease = handler => {
  releaseHandler = handler;
};

// Resolves true when the phone confirmed the release, false when there was
// nothing to release, it failed or it took longer than the timeout.
export const releaseWebphoneBeforeLogout = ({
  timeoutMs = LOGOUT_RELEASE_TIMEOUT_MS,
} = {}) => {
  if (!releaseHandler) return Promise.resolve(false);

  return new Promise(resolve => {
    const timer = setTimeout(() => resolve(false), timeoutMs);
    const finish = released => {
      clearTimeout(timer);
      resolve(released);
    };
    try {
      Promise.resolve(releaseHandler()).then(
        () => finish(true),
        () => finish(false)
      );
    } catch {
      finish(false);
    }
  });
};

// For sign-outs that redirect at once (session replaced, e-mail changed): the
// release request is sent before the cookies go, nobody waits for the answer.
export const releaseWebphoneWithoutWaiting = () => {
  if (!releaseHandler) return;

  try {
    Promise.resolve(releaseHandler()).catch(() => null);
  } catch {
    // Signing out goes on without the phone.
  }
};
