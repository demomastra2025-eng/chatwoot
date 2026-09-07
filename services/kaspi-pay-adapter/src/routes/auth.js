import { Router } from 'express';
import { DEVICE, APP, UA_NATIVE, ENTRANCE_HEADERS_BASE, KASPI_ENTRANCE_URL, KASPI_MTOKEN_URL } from '../config.js';
import { createEmptySession, applyOrgContext } from '../session.js';
import {
  generateECDH,
  completeECDH,
  completeECDHWithSaved,
  computeTokenSnMac,
  signDataPayload,
  computeXSU,
  computeXSign,
  encryptSecret,
  decryptSecret,
} from '../crypto.js';
import { loggedFetch, extractUserToken, entranceCookie, generateUUID, nowISO } from '../helpers.js';
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
  providerView,
  supportsPasswordAuth,
} from '../auth-flow.js';

const router = Router();

const authFlows = new AuthFlowStore();

const providerDescription = body =>
  typeof body?.data?.desc === 'string' ? body.data.desc : undefined;

const providerError = body => {
  const error = body?.error?.code || body?.error?.type || body?.error?.name || body?.error;
  if (typeof error === 'string' || typeof error === 'number') return String(error).slice(0, 80);
  const statusCode = body?.StatusCode ?? body?.statusCode;
  return statusCode == null ? undefined : String(statusCode);
};

const authStepResponse = ({ body, processId, nextStep, success }) => ({
  success,
  processId,
  nextStep,
  view: providerView(body),
  description: providerDescription(body),
  error: success ? undefined : providerError(body) || 'AUTH_STEP_REJECTED',
});

const respondAuthError = (res, error) => {
  if (error instanceof AuthFlowError) {
    return res.status(error.status).json({ success: false, error: error.message, code: error.code });
  }

  console.error('[kaspi-adapter] authentication request failed', error?.name || 'Error');
  return res.status(500).json({
    success: false,
    error: 'Kaspi Pay authentication request failed',
    code: 'AUTH_REQUEST_FAILED',
  });
};

// ═══════════════════════════════════════════════════
//  Step 1 — Init entrance (get processId)
// ═══════════════════════════════════════════════════

router.post('/init', async (req, res) => {
  const session = createEmptySession();

  try {
    const { accountId, authFlowVersion } = req.body || {};
    if (accountId == null || String(accountId).trim() === '') {
      return res.status(400).json({ success: false, error: 'accountId required', code: 'ACCOUNT_ID_REQUIRED' });
    }
    const resp = await loggedFetch(`${KASPI_ENTRANCE_URL}/api/v1/entrance/step`, {
      method: 'POST',
      headers: {
        ...ENTRANCE_HEADERS_BASE,
        Referer: `${KASPI_ENTRANCE_URL}/process/entrance/?auth=2&appBuild=${APP.build}&appVersion=${APP.version}&platformVersion=${APP.platformVer}&platformType=IOS&deviceBrand=${APP.brand}&deviceModel=${APP.model}&deviceId=${DEVICE.deviceId}&installId=${DEVICE.installId}&frontCameraAvailable=true&sf=registration&pc=KPEntrance&noPass=0`,
        Cookie: entranceCookie(),
      },
      body: JSON.stringify({
        data: {},
        Data: {
          auth: '2',
          appBuild: APP.build,
          appVersion: APP.version,
          platformVersion: APP.platformVer,
          platformType: 'IOS',
          deviceBrand: APP.brand,
          deviceModel: APP.model,
          deviceId: DEVICE.deviceId,
          installId: DEVICE.installId,
          frontCameraAvailable: 'true',
          sf: 'registration',
          pc: 'KPEntrance',
          noPass: '0',
        },
        actType: 'Success',
      }),
    });

    const userToken = extractUserToken(resp);
    if (userToken) session.userToken = userToken;

    const body = await resp.json();
    const providerProcessId = body.meta?.pId;
    if (!resp.ok || body.isClosed || !providerProcessId) {
      return res.status(resp.ok ? 422 : resp.status).json({
        success: false,
        error: providerError(body) || 'AUTH_INIT_FAILED',
        view: providerView(body),
        description: providerDescription(body),
      });
    }

    session.processId = providerProcessId;
    const flowId = generateUUID();
    authFlows.create({ flowId, accountId, authFlowVersion, session });

    return res.json({
      success: true,
      processId: flowId,
      nextStep: AUTH_STEPS.PHONE,
      view: providerView(body),
    });
  } catch (error) {
    return respondAuthError(res, error);
  }
});

// ═══════════════════════════════════════════════════
//  Step 2 — Send phone number (triggers SMS)
// ═══════════════════════════════════════════════════

router.post('/send-phone', async (req, res) => {
  let session;
  try {
    const { phoneNumber, processId, accountId } = req.body || {};
    if (!phoneNumber) {
      return res.status(400).json({ success: false, error: 'phoneNumber required (e.g. 7XXXXXXXXX)', code: 'PHONE_REQUIRED' });
    }
    if (!processId) {
      return res.status(400).json({ success: false, error: 'processId required', code: 'PROCESS_ID_REQUIRED' });
    }

    session = authFlows.beginStep(processId, { accountId, expectedStep: AUTH_STEPS.PHONE });
    session.phoneNumber = phoneNumber;

    const resp = await loggedFetch(`${KASPI_ENTRANCE_URL}/api/v1/entrance/step`, {
      method: 'POST',
      headers: {
        ...ENTRANCE_HEADERS_BASE,
        Referer: `${KASPI_ENTRANCE_URL}/process/universal-enter-phone-number?pId=${session.processId}&firstPage=KPUniversalEnterPhoneNumber`,
        Cookie: entranceCookie(session.userToken),
      },
      body: JSON.stringify(buildPhoneStepPayload(session.processId, phoneNumber)),
    });

    const userToken = extractUserToken(resp);
    if (userToken) session.userToken = userToken;

    const body = await resp.json();
    const nextStep = resp.ok ? nextStepAfterPhone(body) : null;
    if (nextStep === AUTH_STEPS.PASSWORD && !supportsPasswordAuth(session)) {
      authFlows.delete(processId);
      return res.status(409).json({
        success: false,
        error: 'Refresh OneLink before starting Kaspi Pay password authentication.',
        code: 'AUTH_CLIENT_REFRESH_REQUIRED',
      });
    }
    if (nextStep) {
      session.otpInputType = nextStep === AUTH_STEPS.OTP ? 'auto' : null;
      authFlows.transition(session, nextStep, body.meta);
    }

    return res.status(resp.ok ? 200 : resp.status).json(
      authStepResponse({ body, processId, nextStep, success: Boolean(nextStep) })
    );
  } catch (error) {
    return respondAuthError(res, error);
  } finally {
    authFlows.endStep(session);
  }
});

// Step 2b — Submit the login password only when Kaspi requests it.
router.post('/send-password', async (req, res) => {
  let session;
  try {
    const { password, processId, accountId } = req.body || {};
    if (typeof password !== 'string' || password.length === 0 || password.length > 256) {
      return res.status(400).json({ success: false, error: 'password required', code: 'PASSWORD_REQUIRED' });
    }
    if (!processId) {
      return res.status(400).json({ success: false, error: 'processId required', code: 'PROCESS_ID_REQUIRED' });
    }

    session = authFlows.beginStep(processId, {
      accountId,
      expectedStep: AUTH_STEPS.PASSWORD,
      attemptKind: AUTH_STEPS.PASSWORD,
    });

    const resp = await loggedFetch(`${KASPI_ENTRANCE_URL}/api/v1/entrance/step`, {
      method: 'POST',
      headers: {
        ...ENTRANCE_HEADERS_BASE,
        Referer: `${KASPI_ENTRANCE_URL}/process/enter-login-password?pId=${session.processId}&firstPage=KPEnterLoginPassword`,
        Cookie: entranceCookie(session.userToken),
      },
      body: JSON.stringify(buildPasswordStepPayload(session.processId, password)),
    });

    const userToken = extractUserToken(resp);
    if (userToken) session.userToken = userToken;

    const body = await resp.json();
    const nextStep = resp.ok ? nextStepAfterPassword(body) : null;
    const success = nextStep === AUTH_STEPS.OTP;
    if (success) {
      session.otpInputType = 'Manual';
      authFlows.transition(session, AUTH_STEPS.OTP, body.meta);
    }

    return res.status(resp.ok ? 200 : resp.status).json(
      authStepResponse({ body, processId, nextStep, success })
    );
  } catch (error) {
    return respondAuthError(res, error);
  } finally {
    authFlows.endStep(session);
  }
});

// ═══════════════════════════════════════════════════
//  Step 3 — Submit SMS OTP code
// ═══════════════════════════════════════════════════

router.post('/verify-otp', async (req, res) => {
  let session;
  try {
    const { otp, processId, accountId } = req.body || {};
    if (!otp) return res.status(400).json({ success: false, error: 'otp required', code: 'OTP_REQUIRED' });
    if (!processId) {
      return res.status(400).json({ success: false, error: 'processId required', code: 'PROCESS_ID_REQUIRED' });
    }

    session = authFlows.beginStep(processId, {
      accountId,
      expectedStep: AUTH_STEPS.OTP,
      attemptKind: AUTH_STEPS.OTP,
    });

    const resp = await loggedFetch(`${KASPI_ENTRANCE_URL}/api/v1/entrance/step`, {
      method: 'POST',
      headers: {
        ...ENTRANCE_HEADERS_BASE,
        Referer: `${KASPI_ENTRANCE_URL}/process/universal-enter-phone-number?pId=${session.processId}&firstPage=KPUniversalEnterPhoneNumber`,
        Cookie: entranceCookie(session.userToken),
      },
      body: JSON.stringify(buildOtpStepPayload(session, otp)),
    });

    const userToken = extractUserToken(resp);
    if (userToken) session.userToken = userToken;

    const body = await resp.json();
    if (!resp.ok || !isOtpVerified(body)) {
      return res.status(resp.ok ? 422 : resp.status).json({
        success: false,
        processId,
        nextStep: AUTH_STEPS.OTP,
        view: providerView(body),
        description: providerDescription(body),
        error: providerError(body) || 'OTP_VERIFICATION_FAILED',
      });
    }

    const finishResult = await doFinish(session);
    authFlows.delete(processId);
    return res.json({
      success: true,
      processId,
      step: 'finished',
      message: 'OTP verified and finish completed',
      ...finishResult,
    });
  } catch (error) {
    return respondAuthError(res, error);
  } finally {
    authFlows.endStep(session);
  }
});

// ═══════════════════════════════════════════════════
//  Finish logic (shared by verify-otp and /finish)
// ═══════════════════════════════════════════════════

async function doFinish(session) {
  const ecdhX509 = generateECDH();

  const signedDataObj = {
    installId: DEVICE.installId,
    time: nowISO(),
    auth: [{ value: '', type: 'pincode' }],
    userIdHash: '',
  };
  const signedDataB64 = Buffer.from(JSON.stringify(signedDataObj)).toString('base64');

  const finishUrl = `${KASPI_ENTRANCE_URL}/api/v1/kpentrance/finish`;
  const finishHeaders = {
    'Content-Type': 'application/json',
    Accept: '*/*',
    'Accept-Language': 'ru',
    'Accept-Encoding': 'gzip, deflate, br',
    'User-Agent': UA_NATIVE,
    'X-Time': nowISO(),
    'X-Call': 'notConnected',
    'X-Platform-Type': APP.platform,
    'X-PkTag': DEVICE.pkTag,
    'X-SU': computeXSU(finishUrl),
    'X-Net-Type': 'WIFI/ETHERNET',
    'X-Emulator': '0',
    'X-Locale': APP.locale,
    'X-SV': '2',
    'X-Request-ID': generateUUID(),
    'X-Time-Zone': 'GMT+05:00',
    'X-SH': 'url,X-Time-Zone,X-Request-ID,X-Net-Type,X-Emulator,X-Call,X-Platform-Type,X-Locale,X-Time,X-SV',
  };
  const finishBody = JSON.stringify({
    signed: { sign: signDataPayload(signedDataB64), data: signedDataB64 },
    guard: { pinHash: DEVICE.pinHash, x509: ecdhX509 },
    processId: session.processId,
  });
  finishHeaders['X-Sign'] = computeXSign(finishUrl, finishHeaders, finishHeaders['X-SH'], finishBody);

  const resp = await loggedFetch(finishUrl, {
    method: 'POST',
    headers: finishHeaders,
    body: finishBody,
  });

  const body = await resp.json();

  if (body.success && body.data?.tokenSN) {
    session.tokenSN = body.data.tokenSN;

    let vtokenSecret = null;
    let rawSecret = null;
    if (body.data.x509) {
      try {
        rawSecret = completeECDH(body.data.x509);
        vtokenSecret = encryptSecret(rawSecret);
        console.log('Kaspi vtoken activated successfully');
      } catch (e) {
        console.error('ECDH key agreement failed:', e.message);
      }
    }

    // Fetch org context
    const orgUrl = `${KASPI_MTOKEN_URL}/v08/organizations/org-context-otp`;
    const piValue = session.profileId != null ? String(session.profileId) : '';
    const orgHeaders = {
      'Content-Type': 'application/json',
      Accept: '*/*',
      'Accept-Language': 'ru',
      'Accept-Encoding': 'gzip, deflate, br',
      'User-Agent': UA_NATIVE,
      'X-Kb-TokenSn': session.tokenSN,
      'X-Kb-TokenSnMac': computeTokenSnMac(session.tokenSN, rawSecret),
      'X-Install-ID': DEVICE.installId,
      'X-App-Ver': APP.version,
      'X-App-Bld': APP.build,
      'X-Locale': APP.locale,
      'X-Call': 'notConnected',
      'X-Time': nowISO(),
      'X-S': 'R:0|E:0|RH:0|N:0',
      'X-SV': '2',
      'X-Kb-Client-Ip': '192.168.1.96',
      'X-PkTag': DEVICE.pkTag,
      'X-SU': computeXSU(orgUrl),
      'X-SH': piValue
        ? 'url,X-Kb-Client-Ip,X-App-Bld,X-S,X-Kb-TokenSn,X-Time,X-App-Ver,X-Kb-TokenSnMac,X-Call,X-PI,X-Install-ID,X-Locale,X-SV'
        : 'url,X-Kb-Client-Ip,X-Time,X-App-Ver,X-SV,X-Locale,X-App-Bld,X-Install-ID,X-Kb-TokenSn,X-S,X-Kb-TokenSnMac,X-Call',
      'X-Request-ID': generateUUID(),
    };
    if (piValue) orgHeaders['X-PI'] = piValue;
    const orgBody = JSON.stringify({
      DeviceInformation: {
        SdkVersion: 'AOTP service',
        DeviceId: DEVICE.deviceId,
        ApplicationId: 'kz.kaspi.business',
        ScreenWidth: APP.screenW,
        Model: APP.model,
        ScreenHeight: APP.screenH,
        DeviceName: APP.deviceName,
        VersionName: APP.version,
        BuildRelease: `${APP.platform} ${APP.platformVer}`,
        Brand: APP.brand,
        Board: APP.platformVer,
        Platform: APP.platform,
        Product: 'Kaspi Pay',
        frontCameraAvailable: true,
        VersionCode: APP.build,
        InstallId: DEVICE.installId,
      },
      OrganizationId: 0,
    });
    orgHeaders['X-Sign'] = computeXSign(orgUrl, orgHeaders, orgHeaders['X-SH'], orgBody);

    const orgResp = await loggedFetch(orgUrl, {
      method: 'POST',
      headers: orgHeaders,
      body: orgBody,
    });

    const orgResponseBody = await orgResp.json();

    if (orgResponseBody.Data?.Current?.ProfileId) {
      applyOrgContext(session, orgResponseBody.Data);
    }

    return {
      tokenSN: session.tokenSN,
      vtokenSecret,
      profileId: session.profileId,
      organizationId: session.organizationId,
      orgName: session.orgName,
      phone: session.phoneNumber,
      organizations: orgResponseBody.Data?.Organizations,
    };
  } else {
    throw new Error(`Finish failed with provider response status ${body.StatusCode || body.statusCode || 'unknown'}`);
  }
}

// ═══════════════════════════════════════════════════
//  Refresh — SignInLite (new tokenSN + vtokenSecret)
//  POST /v03/auth/sign-in-lite
// ═══════════════════════════════════════════════════

router.post('/refresh', async (req, res) => {
  const { tokenSN, vtokenSecret, organizationId } = req.body;
  if (!tokenSN) return res.status(400).json({ error: 'tokenSN required' });
  if (!vtokenSecret) return res.status(400).json({ error: 'vtokenSecret required' });

  try {
    const rawSecret = decryptSecret(vtokenSecret);

    const liteUrl = `${KASPI_MTOKEN_URL}/v03/auth/sign-in-lite`;
    const liteHeaders = {
      'Content-Type': 'application/json',
      Accept: '*/*',
      'Accept-Language': 'ru',
      'Accept-Encoding': 'gzip, deflate, br',
      'User-Agent': UA_NATIVE,
      'X-Kb-TokenSn': tokenSN,
      'X-Kb-TokenSnMac': computeTokenSnMac(tokenSN, rawSecret),
      'X-Install-ID': DEVICE.installId,
      'X-App-Ver': APP.version,
      'X-App-Bld': APP.build,
      'X-Locale': APP.locale,
      'X-Call': 'notConnected',
      'X-Time': nowISO(),
      'X-S': 'R:0|E:0|RH:0|N:0',
      'X-SV': '2',
      'X-Kb-Client-Ip': '192.168.1.96',
      'X-PkTag': DEVICE.pkTag,
      'X-SU': computeXSU(liteUrl),
      'X-SH':
        'url,X-Kb-Client-Ip,X-Time,X-App-Ver,X-SV,X-Locale,X-App-Bld,X-Install-ID,X-Kb-TokenSn,X-S,X-Kb-TokenSnMac,X-Call',
      'X-Request-ID': generateUUID(),
    };
    const liteBody = JSON.stringify({
      OrganizationId: organizationId || 0,
      DeviceInformation: {
        SdkVersion: 'AOTP service',
        DeviceId: DEVICE.deviceId,
        ApplicationId: 'kz.kaspi.business',
        ScreenWidth: APP.screenW,
        Model: APP.model,
        ScreenHeight: APP.screenH,
        DeviceName: DEVICE.deviceName,
        VersionName: APP.version,
        BuildRelease: `${APP.platform} ${APP.platformVer}`,
        Brand: APP.brand,
        Board: APP.platformVer,
        Platform: APP.platform,
        Product: 'Kaspi Pay',
        frontCameraAvailable: true,
        VersionCode: APP.build,
        InstallId: DEVICE.installId,
      },
    });
    liteHeaders['X-Sign'] = computeXSign(liteUrl, liteHeaders, liteHeaders['X-SH'], liteBody);

    const resp = await loggedFetch(liteUrl, {
      method: 'POST',
      headers: liteHeaders,
      body: liteBody,
    });

    const body = await resp.json();

    if (body.StatusCode === 0 && body.Data) {
      const newTokenSN = body.Data.TokenSn || body.Data.tokenSN || tokenSN;
      let newVtokenSecret = vtokenSecret;
      let newRawSecret = null;
      const serverX509 = body.Data.X509 || body.Data.x509;

      if (serverX509) {
        try {
          newRawSecret = completeECDHWithSaved(serverX509);
          newVtokenSecret = encryptSecret(newRawSecret);
          console.log('Kaspi SignInLite vtoken activated successfully');
        } catch (e) {
          console.error('SignInLite ECDH failed:', e.message);
        }
      }

      const activeRawSecret = newRawSecret || decryptSecret(newVtokenSecret);

      // ── Step 2: org-context-otp to load organization context ──
      const session = createEmptySession();
      session.tokenSN = newTokenSN;
      let orgContextOk = false;

      // Pre-fill from SignInLite response if available
      if (body.Data.OrganizationContext || body.Data.OrganizationContextLite) {
        applyOrgContext(session, body.Data.OrganizationContext || body.Data.OrganizationContextLite);
      }

      try {
        const orgUrl = `${KASPI_MTOKEN_URL}/v08/organizations/org-context-otp`;
        const orgHeaders = {
          'Content-Type': 'application/json',
          Accept: '*/*',
          'Accept-Language': 'ru',
          'Accept-Encoding': 'gzip, deflate, br',
          'User-Agent': UA_NATIVE,
          'X-Kb-TokenSn': newTokenSN,
          'X-Kb-TokenSnMac': computeTokenSnMac(newTokenSN, activeRawSecret),
          'X-Install-ID': DEVICE.installId,
          'X-App-Ver': APP.version,
          'X-App-Bld': APP.build,
          'X-Locale': APP.locale,
          'X-Call': 'notConnected',
          'X-Time': nowISO(),
          'X-S': 'R:0|E:0|RH:0|N:0',
          'X-SV': '2',
          'X-Kb-Client-Ip': '192.168.1.96',
          'X-PkTag': DEVICE.pkTag,
          'X-PI': session.profileId || '',
          'X-SU': computeXSU(orgUrl),
          'X-SH':
            'url,X-Kb-Client-Ip,X-Time,X-App-Ver,X-SV,X-Locale,X-App-Bld,X-Install-ID,X-Kb-TokenSn,X-S,X-Kb-TokenSnMac,X-Call',
          'X-Request-ID': generateUUID(),
        };
        const orgBody = JSON.stringify({
          OrganizationId: organizationId || session.organizationId || 0,
          DeviceInformation: {
            SdkVersion: 'AOTP service',
            DeviceId: DEVICE.deviceId,
            ApplicationId: 'kz.kaspi.business',
            ScreenWidth: APP.screenW,
            Model: APP.model,
            ScreenHeight: APP.screenH,
            DeviceName: DEVICE.deviceName,
            VersionName: APP.version,
            BuildRelease: `${APP.platform} ${APP.platformVer}`,
            Brand: APP.brand,
            Board: APP.platformVer,
            Platform: APP.platform,
            Product: 'Kaspi Pay',
            frontCameraAvailable: true,
            VersionCode: APP.build,
            InstallId: DEVICE.installId,
          },
        });
        orgHeaders['X-Sign'] = computeXSign(orgUrl, orgHeaders, orgHeaders['X-SH'], orgBody);

        const orgResp = await loggedFetch(orgUrl, {
          method: 'POST',
          headers: orgHeaders,
          body: orgBody,
        });

        const orgResponseBody = await orgResp.json();
        if (orgResponseBody.StatusCode === 0 && orgResponseBody.Data) {
          applyOrgContext(session, orgResponseBody.Data);
          orgContextOk = true;
          console.log('Kaspi refresh org-context-otp succeeded');
        } else {
          console.log('Kaspi refresh org-context-otp failed with provider status', orgResponseBody.StatusCode);
        }
      } catch (e) {
        console.error('Refresh org-context-otp error:', e.message);
      }

      res.json({
        success: true,
        tokenSN: newTokenSN,
        vtokenSecret: newVtokenSecret,
        profileId: session.profileId,
        organizationId: session.organizationId,
        orgName: session.orgName,
        sessionId: body.Data.SessionId,
        organizations: body.Data.OrganizationContext?.Organizations || body.Data.OrganizationContextLite?.Organizations,
        orgContext: orgContextOk,
        message: 'Session refreshed via SignInLite + org-context',
      });
    } else {
      res.status(resp.ok ? 200 : resp.status).json({
        success: false,
        statusCode: body.StatusCode,
        message:
          body.Message || body.Description || 'SignInLite failed — token may be expired, re-auth via SMS required',
      });
    }
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ─── Session status (client sends tokenSN) ───

router.post('/session', (req, res) => {
  const { tokenSN } = req.body || {};
  res.json({ authenticated: !!tokenSN, tokenSN });
});

// ─── Logout ───

router.post('/logout', (req, res) => {
  res.json({ success: true });
});

export default router;
