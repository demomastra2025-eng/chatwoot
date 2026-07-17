export const normalizeQrResponse = kaspiResponse => {
  const data = kaspiResponse?.Data;
  if (data?.QrToken) {
    data.QrOriginalToken = data.QrOriginalToken || data.QrToken;
    data.QrToken = data.QrToken.replace('https://qr.kaspi.kz/', 'https://pay.kaspi.kz/pay/');
  }
  return kaspiResponse;
};
