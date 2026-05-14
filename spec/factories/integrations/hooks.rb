FactoryBot.define do
  factory :integrations_hook, class: 'Integrations::Hook' do
    app_id { 'slack' }
    account
    settings { { test: 'test' } }
    status { Integrations::Hook.statuses['enabled'] }
    access_token { SecureRandom.hex }
    reference_id { SecureRandom.hex }

    trait :dialogflow do
      app_id { 'dialogflow' }
      settings { { project_id: 'test', credentials: {}, region: 'global', language_code: 'en-US' } }
    end

    trait :dyte do
      app_id { 'dyte' }
      settings { { api_key: 'api_key', organization_id: 'org_id' } }
    end

    trait :google_translate do
      app_id { 'google_translate' }
      settings { { project_id: 'test', credentials: {} } }
    end

    trait :openai do
      app_id { 'openai' }
      settings { { api_key: 'api_key' } }
    end

    trait :linear do
      app_id { 'linear' }
      access_token { SecureRandom.hex }
    end

    trait :shopify do
      app_id { 'shopify' }
      access_token { SecureRandom.hex }
      reference_id { 'test-store.myshopify.com' }
    end

    trait :leadsquared do
      app_id { 'leadsquared' }
      settings do
        {
          'access_key' => SecureRandom.hex,
          'secret_key' => SecureRandom.hex,
          'endpoint_url' => 'https://api.leadsquared.com/'
        }
      end
    end

    trait :kaspi_pay do
      app_id { 'kaspi_pay' }
      settings do
        {
          'default_payment_type' => 'qr',
          'latitude' => 43.238949,
          'longitude' => 76.889709
        }
      end
      access_token do
        {
          token_sn: 'token-sn',
          vtoken_secret: 'encrypted-secret',
          profile_id: 'profile-1',
          organization_id: 'org-1',
          org_name: 'Test Merchant',
          phone_number: '77001234567'
        }.to_json
      end
    end

    trait :medelement do
      app_id { 'medelement' }
      access_token do
        {
          integrator_key: 'integration-key',
          company_login: 'company-login',
          password: 'super-secret'
        }.to_json
      end
      settings do
        {
          'organization_id' => '412849431501753534',
          'timezone' => 'Asia/Almaty',
          'sync_specialists' => true,
          'sync_receptions' => true,
          'sync_patients' => true,
          'sync_interval_hours' => 24,
          'sync_time_of_day' => '06:15',
          'receptions_days_back' => 3,
          'receptions_days_forward' => 70,
          'throttle_ms' => 0
        }
      end
    end
  end
end
