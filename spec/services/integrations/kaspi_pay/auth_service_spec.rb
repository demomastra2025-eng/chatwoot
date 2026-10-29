# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::KaspiPay::AuthService do
  let(:account) { create(:account) }
  let(:service) { described_class.new(account: account) }

  def stub_cashier_phone_steps
    stub_request(:post, 'https://entrance-pay.kaspi.kz/api/v1/entrance/step')
      .with { |req| JSON.parse(req.body)['Data'].present? }
      .to_return(
        status: 200,
        headers: { 'Content-Type' => 'application/json', 'Set-Cookie' => 'user_token=tok_init_1; Path=/' },
        body: { meta: { pId: 'proc_cashier_1' }, view: { code: 'KPUniversalEnterPhoneNumber' } }.to_json
      )
    stub_request(:post, 'https://entrance-pay.kaspi.kz/api/v1/entrance/step')
      .with { |req| JSON.parse(req.body).dig('meta', 'sn') == 'EnterPhoneNumber' }
      .to_return(
        status: 200,
        headers: { 'Content-Type' => 'application/json', 'Set-Cookie' => 'user_token=tok_otp_2; Path=/' },
        body: { meta: { pId: 'proc_cashier_1' }, view: { code: 'EnterOtp' }, data: { desc: 'Код отправлен' } }.to_json
      )
  end

  def stub_cashier_finish_steps(server_x509)
    stub_request(:post, 'https://entrance-pay.kaspi.kz/api/v1/entrance/step')
      .with { |req| JSON.parse(req.body).dig('meta', 'sn') == 'ViewEnterOtp' }
      .to_return(
        status: 200,
        headers: { 'Content-Type' => 'application/json' },
        body: { meta: { pId: 'proc_cashier_1' }, view: { code: 'KPMobileCall' }, data: { type: 'kpDeviceRegistration' } }.to_json
      )
    stub_request(:post, 'https://entrance-pay.kaspi.kz/api/v1/kpentrance/finish')
      .to_return(
        status: 200,
        headers: { 'Content-Type' => 'application/json' },
        body: { success: true, data: { tokenSN: 'TOKENSN_CLINIC_1', x509: server_x509 } }.to_json
      )
  end

  def stub_org_context_response(status_code: 0, profile_id: 77_001)
    stub_request(:post, 'https://mtoken.kaspi.kz/v08/organizations/org-context-otp')
      .to_return(
        status: 200,
        headers: { 'Content-Type' => 'application/json' },
        body: {
          StatusCode: status_code,
          Data: {
            UserId: 'u_1',
            Current: { ProfileId: profile_id, OrganizationName: 'ТОО Клиника Дентал', OrganizationId: 501, OrganizationIdn: '210540012345' },
            Organizations: [
              { ProfileId: 77_001, OrganizationName: 'ТОО Клиника Дентал', OrganizationId: 501, OrganizationIdn: '210540012345' },
              { ProfileId: 77_002, OrganizationName: 'Филиал Астана', OrganizationId: 502, OrganizationIdn: '210540099999' }
            ]
          }
        }.to_json
      )
  end

  describe '#send_otp! and #verify_otp!' do
    it 'completes SMS-only cashier registration, ECDH key exchange, and encrypts credentials in Integrations::Hook' do
      server_ecdh = Integrations::KaspiPay::Crypto.generate_ecdh_keypair
      stub_cashier_phone_steps
      stub_cashier_finish_steps(server_ecdh[:public_x509_b64])
      stub_org_context_response

      otp_res = service.send_otp!(raw_phone: '+7 (701) 555-44-33')
      expect(otp_res[:phone_masked]).to eq('+7 701 *** ** 33')

      status = service.verify_otp!(process_id: otp_res[:process_id], otp: '4829')
      expect(status).to include(connected: true, session_status: 'active', organization_name: 'ТОО Клиника Дентал', profile_id: '77001')

      hook = account.hooks.find_by(app_id: 'kaspi_pay')
      expect(hook.secret_settings).to include('token_sn' => 'TOKENSN_CLINIC_1')
      expect(hook.secret_settings['vtoken_secret_b64']).to be_present

      updated = service.update_settings!(profile_id: '77002', auto_send_link_to_chat: false)
      expect(updated).to include(profile_id: '77002', organization_name: 'Филиал Астана', auto_send_link_to_chat: false)

      expect { service.update_settings!(profile_id: '99999') }
        .to raise_error(Integrations::KaspiPay::ApiClient::ApiError) { |err| expect(err.code).to eq('InvalidProfileId') }
    end

    it 'does not persist a broken hook when org-context-otp returns a missing profile_id' do
      server_ecdh = Integrations::KaspiPay::Crypto.generate_ecdh_keypair
      stub_cashier_phone_steps
      stub_cashier_finish_steps(server_ecdh[:public_x509_b64])
      stub_org_context_response(profile_id: nil)

      otp_res = service.send_otp!(raw_phone: '+7 701 555 44 33')
      expect { service.verify_otp!(process_id: otp_res[:process_id], otp: '4829') }
        .to raise_error(Integrations::KaspiPay::ApiClient::ApiError) { |err| expect(err.code).to eq('MissingProfileId') }
      expect(account.hooks.find_by(app_id: 'kaspi_pay')).to be_nil
    end

    it 'rejects business owner phone numbers requiring password/video verification with a clear Cashier instruction' do
      stub_request(:post, 'https://entrance-pay.kaspi.kz/api/v1/entrance/step')
        .with { |req| JSON.parse(req.body)['Data'].present? }
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: { meta: { pId: 'proc_owner_1' }, view: { code: 'KPUniversalEnterPhoneNumber' } }.to_json
        )

      stub_request(:post, 'https://entrance-pay.kaspi.kz/api/v1/entrance/step')
        .with { |req| JSON.parse(req.body).dig('meta', 'sn') == 'EnterPhoneNumber' }
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: { meta: { pId: 'proc_owner_1' }, view: { code: 'KPEnterLoginPassword' } }.to_json
        )

      expect { service.send_otp!(raw_phone: '+7 701 999 88 77') }
        .to raise_error(Integrations::KaspiPay::ApiClient::ApiError) { |err|
          expect(err.code).to eq('OwnerAccountPasswordRequired')
          expect(err.message).to include('Кассир')
        }
    end

    it 'surfaces OldVersionToUpdate clearly when Kaspi bumps minimum mobile version' do
      stub_request(:post, 'https://entrance-pay.kaspi.kz/api/v1/entrance/step')
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: {
            view: {
              code: 'AlarmView',
              onOpenAlarm: { error: { code: 'OldVersionToUpdate', label: 'Обновите приложение' } }
            }
          }.to_json
        )

      expect { service.send_otp!(raw_phone: '+7 701 999 88 77') }
        .to raise_error(Integrations::KaspiPay::ApiClient::ApiError) { |err|
          expect(err.code).to eq('OldVersionToUpdate')
        }
    end
  end

  describe '#check_session!' do
    it 'marks session_status as reauth_required when Kaspi returns StatusCode -101001' do
      device = Integrations::KaspiPay::Crypto.generate_device_identity
      account.hooks.create!(
        app_id: 'kaspi_pay',
        hook_type: :account,
        status: :enabled,
        access_token: {
          'device' => device,
          'token_sn' => 'TSN_1',
          'vtoken_secret_b64' => Base64.strict_encode64('a' * 32)
        }.to_json,
        settings: { 'session_status' => 'active', 'profile_id' => '100' }
      )

      stub_request(:post, 'https://qrpay.kaspi.kz/v02/history/operations')
        .to_return(
          status: 401,
          headers: { 'Content-Type' => 'application/json' },
          body: { StatusCode: -101_001, Message: 'Сессия устарела' }.to_json
        )

      res = service.check_session!
      expect(res).to include(active: false, evicted: true)
      expect(service.hook.reload.settings['session_status']).to eq('reauth_required')
    end
  end
end
