export const AUTH_STEPS = Object.freeze({
  PHONE: 'phone',
  PASSWORD: 'password',
  OTP: 'otp',
});

export const AUTH_FLOW_TTL_MS = 10 * 60 * 1000;
export const MAX_AUTH_ATTEMPTS = 5;
export const PASSWORD_AUTH_FLOW_VERSION = 2;

const PASSWORD_VIEWS = new Set(['KPEnterLoginPassword', 'EnterLoginPassword', 'ViewEnterLoginPassword']);
const OTP_VIEWS = new Set(['EnterOtp', 'ViewEnterOtp', 'KPEnterOtp', 'KPMobileCall']);
const OTP_DESCRIPTION = /sms|смс|otp|код|code/iu;

export class AuthFlowError extends Error {
  constructor(message, { code, status }) {
    super(message);
    this.code = code;
    this.status = status;
  }
}

export class AuthFlowStore {
  constructor({ ttlMs = AUTH_FLOW_TTL_MS, maxAttempts = MAX_AUTH_ATTEMPTS, now = () => Date.now() } = {}) {
    this.sessions = new Map();
    this.ttlMs = ttlMs;
    this.maxAttempts = maxAttempts;
    this.now = now;
  }

  create({ flowId, accountId, authFlowVersion, session }) {
    this.pruneExpired();
    if (accountId == null || String(accountId).trim() === '') {
      throw new AuthFlowError('accountId is required for a Kaspi Pay authentication flow.', {
        code: 'ACCOUNT_ID_REQUIRED',
        status: 400,
      });
    }
    session.flowId = flowId;
    session.accountId = String(accountId);
    session.authFlowVersion = Number(authFlowVersion) || 1;
    session.authStep = AUTH_STEPS.PHONE;
    session.authExpiresAt = this.now() + this.ttlMs;
    session.authAttempts = { password: 0, otp: 0 };
    this.sessions.set(flowId, session);
    return session;
  }

  get(flowId, { accountId, expectedStep } = {}) {
    const session = this.sessions.get(flowId);
    if (!session) {
      throw new AuthFlowError('Unknown auth flow. Start the Kaspi Pay connection again.', {
        code: 'AUTH_FLOW_NOT_FOUND',
        status: 400,
      });
    }

    if (session.authExpiresAt <= this.now()) {
      this.sessions.delete(flowId);
      throw new AuthFlowError('Kaspi Pay authentication expired. Start the connection again.', {
        code: 'AUTH_FLOW_EXPIRED',
        status: 410,
      });
    }

    if (accountId == null || session.accountId !== String(accountId)) {
      throw new AuthFlowError('Unknown auth flow. Start the Kaspi Pay connection again.', {
        code: 'AUTH_FLOW_NOT_FOUND',
        status: 404,
      });
    }

    if (expectedStep && session.authStep !== expectedStep) {
      throw new AuthFlowError(`Kaspi Pay authentication is waiting for the ${session.authStep} step.`, {
        code: 'AUTH_FLOW_STEP_MISMATCH',
        status: 409,
      });
    }

    return session;
  }

  transition(session, nextStep, providerMeta) {
    session.authStep = nextStep;
    if (providerMeta && typeof providerMeta === 'object') session.lastMeta = providerMeta;
    return session;
  }

  recordAttempt(session, kind) {
    const attempts = session.authAttempts || (session.authAttempts = { password: 0, otp: 0 });
    if ((attempts[kind] || 0) >= this.maxAttempts) {
      throw new AuthFlowError(`Too many Kaspi Pay ${kind} attempts. Start the connection again.`, {
        code: 'AUTH_FLOW_ATTEMPTS_EXCEEDED',
        status: 429,
      });
    }
    attempts[kind] = (attempts[kind] || 0) + 1;
  }

  beginStep(flowId, { accountId, expectedStep, attemptKind } = {}) {
    const session = this.get(flowId, { accountId, expectedStep });
    if (session.authInFlight) {
      throw new AuthFlowError('This Kaspi Pay authentication step is already in progress.', {
        code: 'AUTH_FLOW_IN_PROGRESS',
        status: 409,
      });
    }
    if (attemptKind) this.recordAttempt(session, attemptKind);
    session.authInFlight = expectedStep;
    return session;
  }

  endStep(session) {
    if (session) delete session.authInFlight;
  }

  delete(flowId) {
    this.sessions.delete(flowId);
  }

  pruneExpired() {
    const now = this.now();
    for (const [flowId, session] of this.sessions) {
      if (session.authExpiresAt <= now) this.sessions.delete(flowId);
    }
  }
}

export const providerView = body => body?.view?.main || body?.view?.code || null;

export const supportsPasswordAuth = session => session?.authFlowVersion >= PASSWORD_AUTH_FLOW_VERSION;

const providerViews = body => [body?.view?.main, body?.view?.code].filter(Boolean);

export const nextStepAfterPhone = body => {
  if (!body || body.isClosed === true) return null;

  const views = providerViews(body);
  if (views.some(view => OTP_VIEWS.has(view))) return AUTH_STEPS.OTP;
  if (views.some(view => PASSWORD_VIEWS.has(view))) return AUTH_STEPS.PASSWORD;
  return null;
};

export const nextStepAfterPassword = body => {
  if (!body || body.isClosed === true) return null;

  const views = providerViews(body);
  const description = body.data?.desc;
  if (views.some(view => OTP_VIEWS.has(view)) || (typeof description === 'string' && OTP_DESCRIPTION.test(description))) {
    return AUTH_STEPS.OTP;
  }
  if (views.some(view => PASSWORD_VIEWS.has(view))) return AUTH_STEPS.PASSWORD;
  return null;
};

export const buildPhoneStepPayload = (providerProcessId, phoneNumber) => ({
  meta: { pId: providerProcessId, sn: 'EnterPhoneNumber' },
  data: { phoneNumber },
  actType: 'Success',
});

export const buildPasswordStepPayload = (providerProcessId, password) => ({
  meta: { pId: providerProcessId, sn: 'ViewEnterLoginPassword' },
  data: { password },
  actType: 'Success',
});

export const buildOtpStepPayload = (session, otp) => ({
  meta: {
    ...(session.lastMeta && typeof session.lastMeta === 'object' ? session.lastMeta : {}),
    pId: session.processId,
    sn: session.lastMeta?.sn || 'ViewEnterOtp',
  },
  data: { userOtp: otp, inputType: session.otpInputType || 'auto' },
  actType: 'Success',
});

export const isOtpVerified = body =>
  body?.data?.type === 'kpDeviceRegistration' || providerViews(body).includes('KPMobileCall');
