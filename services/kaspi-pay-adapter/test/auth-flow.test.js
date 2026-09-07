import assert from 'node:assert/strict';
import test from 'node:test';
import {
  AUTH_STEPS,
  AuthFlowError,
  AuthFlowStore,
  buildOtpStepPayload,
  buildPasswordStepPayload,
  buildPhoneStepPayload,
  isOtpVerified,
  nextStepAfterPassword,
  nextStepAfterPhone,
  supportsPasswordAuth,
} from '../src/auth-flow.js';

test('phone step supports direct OTP and password-first provider flows', () => {
  assert.equal(nextStepAfterPhone({ isClosed: false, view: { code: 'EnterOtp' } }), AUTH_STEPS.OTP);
  assert.equal(
    nextStepAfterPhone({ isClosed: false, view: { code: 'KPEnterLoginPassword' } }),
    AUTH_STEPS.PASSWORD
  );
  assert.equal(nextStepAfterPhone({ isClosed: true, view: { code: 'EnterOtp' } }), null);
});

test('password step detects the OTP modal without accepting another password prompt', () => {
  assert.equal(
    nextStepAfterPassword({
      isClosed: false,
      view: { main: 'KPEnterLoginPassword' },
      data: { desc: 'Код отправлен на указанный номер' },
    }),
    AUTH_STEPS.OTP
  );
  assert.equal(
    nextStepAfterPassword({
      isClosed: false,
      view: { code: 'KPEnterLoginPassword' },
      data: { desc: 'Введите SMS-код' },
    }),
    AUTH_STEPS.OTP
  );
  assert.equal(
    nextStepAfterPassword({
      isClosed: false,
      view: { code: 'KPEnterLoginPassword', main: 'KPMobileCall' },
    }),
    AUTH_STEPS.OTP
  );
  assert.equal(
    nextStepAfterPassword({
      isClosed: false,
      view: { code: 'KPEnterLoginPassword' },
      data: { desc: 'Неверный пароль' },
    }),
    AUTH_STEPS.PASSWORD
  );
});

test('provider payloads preserve the password and OTP protocol metadata', () => {
  assert.deepEqual(buildPhoneStepPayload('provider-process', '77001234567'), {
    meta: { pId: 'provider-process', sn: 'EnterPhoneNumber' },
    data: { phoneNumber: '77001234567' },
    actType: 'Success',
  });
  assert.deepEqual(buildPasswordStepPayload('provider-process', 'password-value'), {
    meta: { pId: 'provider-process', sn: 'ViewEnterLoginPassword' },
    data: { password: 'password-value' },
    actType: 'Success',
  });
  assert.deepEqual(
    buildOtpStepPayload(
      { processId: 'provider-process', lastMeta: { pId: 'stale-process', sn: 'ProviderOtpStep', lv: 2 } },
      '1234'
    ),
    {
      meta: { pId: 'provider-process', sn: 'ProviderOtpStep', lv: 2 },
      data: { userOtp: '1234', inputType: 'auto' },
      actType: 'Success',
    }
  );
  assert.deepEqual(buildOtpStepPayload({ processId: 'provider-process', lastMeta: {}, otpInputType: 'Manual' }, '5678'), {
    meta: { pId: 'provider-process', sn: 'ViewEnterOtp' },
    data: { userOtp: '5678', inputType: 'Manual' },
    actType: 'Success',
  });
});

test('OTP completion accepts both documented provider finish signals', () => {
  assert.equal(isOtpVerified({ data: { type: 'kpDeviceRegistration' } }), true);
  assert.equal(isOtpVerified({ view: { main: 'KPMobileCall' } }), true);
  assert.equal(isOtpVerified({ view: { main: 'KPEnterLoginPassword', code: 'KPMobileCall' } }), true);
  assert.equal(isOtpVerified({ view: { code: 'EnterOtp' } }), false);
});

test('auth flow store expires sessions and binds explicit account IDs', () => {
  let now = 1_000;
  const store = new AuthFlowStore({ ttlMs: 100, now: () => now });
  const session = store.create({ flowId: 'flow', accountId: 530, session: { processId: 'provider-process' } });

  assert.equal(store.get('flow', { accountId: 530, expectedStep: AUTH_STEPS.PHONE }), session);
  assert.throws(
    () => store.create({ flowId: 'unbound', session: { processId: 'provider-unbound' } }),
    error => error instanceof AuthFlowError && error.code === 'ACCOUNT_ID_REQUIRED' && error.status === 400
  );
  assert.throws(
    () => store.get('flow'),
    error => error instanceof AuthFlowError && error.code === 'AUTH_FLOW_NOT_FOUND' && error.status === 404
  );
  assert.throws(
    () => store.get('flow', { accountId: 531 }),
    error => error instanceof AuthFlowError && error.code === 'AUTH_FLOW_NOT_FOUND' && error.status === 404
  );

  now = 1_101;
  assert.throws(
    () => store.get('flow', { accountId: 530 }),
    error => error instanceof AuthFlowError && error.code === 'AUTH_FLOW_EXPIRED' && error.status === 410
  );
});

test('auth flow store prunes abandoned expired sessions when a new flow starts', () => {
  let now = 1_000;
  const store = new AuthFlowStore({ ttlMs: 100, now: () => now });
  store.create({ flowId: 'expired', accountId: 530, session: { processId: 'provider-old' } });

  now = 1_101;
  store.create({ flowId: 'current', accountId: 530, session: { processId: 'provider-current' } });

  assert.equal(store.sessions.has('expired'), false);
  assert.equal(store.sessions.has('current'), true);
});

test('password auth requires a capability-aware browser flow', () => {
  const store = new AuthFlowStore();
  const legacy = store.create({ flowId: 'legacy', accountId: 530, session: { processId: 'provider-legacy' } });
  const current = store.create({
    flowId: 'current',
    accountId: 530,
    authFlowVersion: 2,
    session: { processId: 'provider-current' },
  });

  assert.equal(supportsPasswordAuth(legacy), false);
  assert.equal(supportsPasswordAuth(current), true);
});

test('auth flow store enforces step ordering and attempt limits', () => {
  const store = new AuthFlowStore({ maxAttempts: 2 });
  const session = store.create({ flowId: 'flow', accountId: 530, session: { processId: 'provider-process' } });
  store.transition(session, AUTH_STEPS.PASSWORD);

  assert.throws(
    () => store.get('flow', { accountId: 530, expectedStep: AUTH_STEPS.OTP }),
    error => error instanceof AuthFlowError && error.code === 'AUTH_FLOW_STEP_MISMATCH' && error.status === 409
  );

  store.recordAttempt(session, AUTH_STEPS.PASSWORD);
  store.recordAttempt(session, AUTH_STEPS.PASSWORD);
  assert.throws(
    () => store.recordAttempt(session, AUTH_STEPS.PASSWORD),
    error => error instanceof AuthFlowError && error.code === 'AUTH_FLOW_ATTEMPTS_EXCEEDED' && error.status === 429
  );
});

test('auth flow store serializes provider requests for each flow', () => {
  const store = new AuthFlowStore();
  const session = store.create({ flowId: 'flow', accountId: 530, session: { processId: 'provider-process' } });

  assert.equal(store.beginStep('flow', { accountId: 530, expectedStep: AUTH_STEPS.PHONE }), session);
  assert.throws(
    () => store.beginStep('flow', { accountId: 530, expectedStep: AUTH_STEPS.PHONE }),
    error => error instanceof AuthFlowError && error.code === 'AUTH_FLOW_IN_PROGRESS' && error.status === 409
  );

  store.endStep(session);
  assert.equal(store.beginStep('flow', { accountId: 530, expectedStep: AUTH_STEPS.PHONE }), session);
  store.endStep(session);
});
